// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RegistroInvestidorQualificado} from "../src/registro/RegistroInvestidorQualificado.sol";
import {OfertaCaptacao} from "../src/captacao/OfertaCaptacao.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";
import {OfertaOrquestrador} from "../src/orquestracao/OfertaOrquestrador.sol";

/// @title CicloCompletoLocal (full local cycle)
/// @notice LOCAL rehearsal of the whole cycle that `DeployFase2Sepolia.s.sol` +
/// `DeployFase2SepoliaExecute.s.sol` run for real on Sepolia, including the step those two
/// scripts deliberately DO NOT run (issuer/investors never sign from a script on Sepolia;
/// each uses their own wallet via `cast send`, see those files' NatSpec). Here, since it is
/// only a local rehearsal, the five roles (admin/agent, issuer, two investors) are Anvil's
/// default development accounts (mnemonic "test test test ... junk"): PUBLIC, well-known
/// addresses, with no private key anywhere in this file. They work as signers because Anvil
/// unlocks these accounts by default (native impersonation), never because this script knows
/// the keys.
/// @dev Only works against local Anvil: the `chainid` guard below makes an accidental broadcast
/// to a real network impossible (Anvil's dev accounts have no ETH or meaning on any other
/// chain). `vm.warp` is used to skip the real 1h timelock, which is valid ONLY in local
/// simulation/ephemeral Anvil, never against a real network receiving real transactions (see
/// CLAUDE.md, "Test results (Phase 1)").
///
/// The offering parameters (`metaMinima`/`metaMaxima`/`precoPorCota`) reuse exactly the
/// same values already validated in `test/OfertaOrquestrador.t.sol`
/// (`DEFAULT_MIN_TARGET`/`DEFAULT_MAX_TARGET`/`DEFAULT_PRICE_PER_SHARE`): `metaMaxima*100 ==
/// metaMinima*125`, exactly at the 25% additional-lot limit of CVM Res. 88 that
/// `OfertaOrquestrador.criarOfertaCompleta` enforces; any larger value would revert with
/// `LoteAdicionalExcedeLimite`. `taxaBps = 100` (1%, the hard cap) on purpose, not `0`: the
/// goal of this rehearsal is to confirm the fee split to `PROTOCOL` shows up correctly
/// before running the same thing for real on Sepolia.
///
/// Usage (dry run, no --broadcast): `forge script script/CicloCompletoLocal.s.sol --chain 31337`
/// Usage (against a running local anvil): `forge script script/CicloCompletoLocal.s.sol \
///   --rpc-url http://127.0.0.1:8545 --broadcast`
contract CicloCompletoLocal is Script {
    uint256 internal constant ANVIL_CHAIN_ID = 31337;
    uint256 internal constant TIMELOCK_DELAY = 1 hours;

    // Anvil's default development accounts (indices 0-4 of the mnemonic
    // "test test test test test test test test test test test junk"), checked in this session
    // via `cast rpc eth_accounts` against a real `anvil`. Public and known to any Foundry
    // developer; no private key appears in this file.
    address internal constant ADMIN = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // conta #0
    address internal constant INVESTOR1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // conta #1
    address internal constant INVESTOR2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // conta #2
    address internal constant ISSUER = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // conta #3
    address internal constant PROTOCOL = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65; // conta #4

    uint256 internal constant MIN_TARGET = 800 ether;
    uint256 internal constant MAX_TARGET = 1_000 ether;
    uint256 internal constant PRICE_PER_SHARE = 100 ether;
    uint256 internal constant PER_INVESTOR_CAP = 1_000 ether;
    uint256 internal constant FEE_BPS = 100; // 1%; see the contract NatSpec.
    uint256 internal constant DEADLINE_SECONDS = 180 days;

    uint256 internal constant INVESTOR1_INVESTMENT = 600 ether;
    uint256 internal constant INVESTOR2_INVESTMENT = 400 ether;

    error InvalidNetwork(uint256 currentChainId, uint256 expectedChainId);

    struct Infra {
        MockBRL currency;
        DenyAllTransferPolicy policy;
        ParticipacaoToken tokenImplementation;
        EmissaoGateway gateway;
        ParticipacaoTokenFactory tokenFactory;
        RegistroInvestidorQualificado registry;
        OfertaCaptacao fundraisingImplementation;
        OfertaCaptacaoFactory fundraisingFactory;
        OfertaOrquestrador orchestrator;
    }

    function run() external {
        if (block.chainid != ANVIL_CHAIN_ID) revert InvalidNetwork(block.chainid, ANVIL_CHAIN_ID);

        Infra memory infra = _deployAndGrantRoles();

        vm.startBroadcast(ADMIN);
        infra.orchestrator.autorizarEmissor(ISSUER);
        infra.currency.mint(INVESTOR1, INVESTOR1_INVESTMENT);
        infra.currency.mint(INVESTOR2, INVESTOR2_INVESTMENT);
        vm.stopBroadcast();

        vm.startBroadcast(ISSUER);
        (address token, address oferta) = infra.orchestrator
            .criarOfertaCompleta(
                "Oferta Ensaio Local",
                "nENS",
                "Empresa Ensaio Local Ltda",
                keccak256(abi.encode("cnpj-ensaio-local", block.timestamp)),
                "2026-ENSAIO-LOCAL",
                MIN_TARGET,
                MAX_TARGET,
                PRICE_PER_SHARE,
                block.timestamp + DEADLINE_SECONDS
            );
        vm.stopBroadcast();

        vm.startBroadcast(INVESTOR1);
        infra.currency.approve(oferta, INVESTOR1_INVESTMENT);
        OfertaCaptacao(oferta).aportar(INVESTOR1_INVESTMENT);
        vm.stopBroadcast();

        vm.startBroadcast(INVESTOR2);
        infra.currency.approve(oferta, INVESTOR2_INVESTMENT);
        OfertaCaptacao(oferta).aportar(INVESTOR2_INVESTMENT);
        vm.stopBroadcast();

        vm.startBroadcast(ADMIN);
        OfertaCaptacao(oferta).encerrar();
        vm.stopBroadcast();

        vm.startBroadcast(INVESTOR1);
        OfertaCaptacao(oferta).resgatarCotas();
        vm.stopBroadcast();

        vm.startBroadcast(INVESTOR2);
        OfertaCaptacao(oferta).resgatarCotas();
        vm.stopBroadcast();

        vm.startBroadcast(ADMIN);
        OfertaCaptacao(oferta).liberarParaEmissor();
        vm.stopBroadcast();

        _logResults(infra, token, oferta);
    }

    function _deployAndGrantRoles() internal returns (Infra memory infra) {
        vm.startBroadcast(ADMIN);
        infra.currency = new MockBRL();
        infra.policy = new DenyAllTransferPolicy();
        infra.tokenImplementation = new ParticipacaoToken();
        infra.gateway = new EmissaoGateway(ADMIN, TIMELOCK_DELAY);
        infra.tokenFactory = new ParticipacaoTokenFactory(
            ADMIN, address(infra.tokenImplementation), address(infra.gateway), address(infra.policy), TIMELOCK_DELAY
        );
        infra.registry = new RegistroInvestidorQualificado(ADMIN, TIMELOCK_DELAY);
        infra.fundraisingImplementation = new OfertaCaptacao();
        infra.fundraisingFactory = new OfertaCaptacaoFactory(
            ADMIN,
            address(infra.fundraisingImplementation),
            address(infra.gateway),
            address(infra.registry),
            address(infra.currency),
            TIMELOCK_DELAY
        );
        infra.orchestrator = new OfertaOrquestrador(
            ADMIN,
            address(infra.tokenFactory),
            address(infra.gateway),
            address(infra.fundraisingFactory),
            PROTOCOL,
            FEE_BPS,
            PER_INVESTOR_CAP,
            TIMELOCK_DELAY
        );

        bytes32 agentRole = infra.orchestrator.AGENTE_ROLE(); // same hash in all 4 contracts
        infra.tokenFactory.proposeGrantRole(agentRole, address(infra.orchestrator));
        infra.gateway.proposeGrantRole(agentRole, address(infra.orchestrator));
        infra.fundraisingFactory.proposeGrantRole(agentRole, address(infra.orchestrator));
        infra.orchestrator.proposeGrantRole(agentRole, ADMIN);

        // Only valid in local simulation/ephemeral Anvil; see the contract NatSpec.
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        infra.tokenFactory.executeGrantRole(agentRole, address(infra.orchestrator));
        infra.gateway.executeGrantRole(agentRole, address(infra.orchestrator));
        infra.fundraisingFactory.executeGrantRole(agentRole, address(infra.orchestrator));
        infra.orchestrator.executeGrantRole(agentRole, ADMIN);
        vm.stopBroadcast();
    }

    function _logResults(Infra memory infra, address token, address oferta) internal view {
        console2.log("== CicloCompletoLocal: ciclo completo via OfertaOrquestrador ==");
        console2.log("Token (ParticipacaoToken):", token);
        console2.log("Offering (OfertaCaptacao escrow):", oferta);
        console2.log(
            "Final state (1 = EncerradaSucesso, closed with success):", uint256(OfertaCaptacao(oferta).estado())
        );
        console2.log("Total raised:", OfertaCaptacao(oferta).totalArrecadado());
        console2.log("");
        console2.log("Investor 1 shares:", ParticipacaoToken(token).balanceOf(INVESTOR1));
        console2.log("Investor 2 shares:", ParticipacaoToken(token).balanceOf(INVESTOR2));
        console2.log("Token totalSupply:", ParticipacaoToken(token).totalSupply());
        console2.log("");
        console2.log("Issuer MockBRL after release:", infra.currency.balanceOf(ISSUER));
        console2.log("Protocol MockBRL after release (1% fee):", infra.currency.balanceOf(PROTOCOL));
        console2.log("MockBRL left in escrow (should be 0):", infra.currency.balanceOf(oferta));
    }
}
