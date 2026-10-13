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

/// @title DeployFase2Sepolia (Phase 2 Sepolia deploy)
/// @notice Part 1/2 of the real Phase 2 deploy (+ the self-service `OfertaOrquestrador` channel) on
/// Sepolia. Single signer: the account resolved by `--account` on the command line (e.g.
/// `niara-admin`), with NO private key in an environment variable, not even as a fallback,
/// anywhere in this file. `vm.startBroadcast()` without arguments lets Foundry resolve the
/// signer on its own; `msg.sender`, read right after, already reflects that address (checked
/// empirically in this session: `--account`/`--sender` pin `msg.sender` for the whole script
/// execution, even before the first `startBroadcast`).
/// @dev Deploys the Phase 2 infrastructure (8 contracts) + `OfertaOrquestrador`, and PROPOSES (never
/// executes) `AGENTE_ROLE` in 5 relationships: the `OfertaOrquestrador` on the three contracts it
/// calls (`ParticipacaoTokenFactory`, `EmissaoGateway`, `OfertaCaptacaoFactory`), the signer itself
/// on `OfertaOrquestrador` (so it can operate `autorizarEmissor` later), and the signer itself on
/// `RegistroInvestidorQualificado` (so it can operate `definirQualificado` later).
/// `RegistroInvestidorQualificado.ehQualificado` is read, with no role restriction, inside
/// `OfertaCaptacao.aportar`: an investment within `tetoPorInvestidor` works even without any
/// qualified investor, but qualifying the first investor (the only way to invest ABOVE the cap,
/// the very point of the qualified-investor exception in CVM Resolution 88) depends on someone
/// holding `AGENTE_ROLE` there. It is grouped in this same batch of proposals because the grant
/// goes through the same 1h timelock as the other four; paying that wait separately later would
/// cost an idle hour in the middle of the cycle.
///
/// `forge script` simulates the WHOLE `run()` before broadcasting any transaction: if any call
/// reverted during the simulation, NOTHING would be broadcast, not even the deploys. Since the
/// real 1h timelock never passes within a single run against a real network (`vm.warp` does not
/// affect the clock of a real chain receiving transactions; see CLAUDE.md), this script only
/// PROPOSES; `script/DeployFase2SepoliaExecute.s.sol`, run after >= 1 real hour, executes the 5
/// pending grants and authorizes the first issuer. The 9 deployed addresses are persisted in
/// `./script/output/fase2-sepolia.json` so the execution script can rebuild the same state
/// without depending on hand-typed addresses.
///
/// Usage:
///   PROTOCOLO_WALLET_ADDRESS=0x... TAXA_BPS_ORQUESTRADOR=100 \
///   TETO_POR_INVESTIDOR_ORQUESTRADOR=20000000000000000000000 \
///   forge script script/DeployFase2Sepolia.s.sol --rpc-url sepolia --account niara-admin \
///     --broadcast --verify
contract DeployFase2Sepolia is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 internal constant TIMELOCK_DELAY = 1 hours;
    string internal constant OUTPUT_PATH = "./script/output/fase2-sepolia.json";

    /// @notice Same hard cap as `OfertaCaptacao.TAXA_BPS_MAXIMA`/
    /// `OfertaOrquestrador.TAXA_BPS_MAXIMA`, checked here before accepting the env value, and
    /// strictly required to be > 0: with a dormant fee, `OfertaCaptacao.liberarParaEmissor` skips
    /// the protocol transfer leg (`if (taxa > 0)`) and the revenue split never shows up on
    /// Etherscan, which would defeat this phase's goal of proving the revenue model on-chain.
    uint256 internal constant TAXA_BPS_MAXIMA = 100;

    error InvalidNetwork(uint256 currentChainId, uint256 expectedChainId);
    error FeeBpsOutOfRange(uint256 taxaBps);

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

    function run() external returns (Infra memory infra) {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert InvalidNetwork(block.chainid, SEPOLIA_CHAIN_ID);

        address protocoloWallet = vm.envAddress("PROTOCOLO_WALLET_ADDRESS");
        uint256 orchestratorFeeBps = vm.envUint("TAXA_BPS_ORQUESTRADOR");
        uint256 orchestratorPerInvestorCap = vm.envUint("TETO_POR_INVESTIDOR_ORQUESTRADOR");
        if (orchestratorFeeBps == 0 || orchestratorFeeBps > TAXA_BPS_MAXIMA) {
            revert FeeBpsOutOfRange(orchestratorFeeBps);
        }

        vm.startBroadcast();
        address admin = msg.sender;

        infra = _deployInfra(admin, protocoloWallet, orchestratorFeeBps, orchestratorPerInvestorCap);
        _proposeAgent(infra, admin);
        vm.stopBroadcast();

        _persistAddresses(infra);
        _logResults(infra, admin);
    }

    function _deployInfra(
        address admin,
        address protocoloWallet,
        uint256 orchestratorFeeBps,
        uint256 orchestratorPerInvestorCap
    ) internal returns (Infra memory infra) {
        infra.currency = new MockBRL();
        infra.policy = new DenyAllTransferPolicy();
        infra.tokenImplementation = new ParticipacaoToken();
        infra.gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        infra.tokenFactory = new ParticipacaoTokenFactory(
            admin, address(infra.tokenImplementation), address(infra.gateway), address(infra.policy), TIMELOCK_DELAY
        );
        infra.registry = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        infra.fundraisingImplementation = new OfertaCaptacao();
        infra.fundraisingFactory = new OfertaCaptacaoFactory(
            admin,
            address(infra.fundraisingImplementation),
            address(infra.gateway),
            address(infra.registry),
            address(infra.currency),
            TIMELOCK_DELAY
        );
        infra.orchestrator = new OfertaOrquestrador(
            admin,
            address(infra.tokenFactory),
            address(infra.gateway),
            address(infra.fundraisingFactory),
            protocoloWallet,
            orchestratorFeeBps,
            orchestratorPerInvestorCap,
            TIMELOCK_DELAY
        );
    }

    /// @dev Proposes (does not execute) `AGENTE_ROLE` in the 5 relationships; see the contract NatSpec.
    /// Contracts deployed in this same call never have a pending proposal, so proposing
    /// directly (without checking `pendingActions` first) is safe.
    function _proposeAgent(Infra memory infra, address admin) internal {
        bytes32 agentRole = infra.orchestrator.AGENTE_ROLE();
        infra.tokenFactory.proposeGrantRole(agentRole, address(infra.orchestrator));
        infra.gateway.proposeGrantRole(agentRole, address(infra.orchestrator));
        infra.fundraisingFactory.proposeGrantRole(agentRole, address(infra.orchestrator));
        infra.orchestrator.proposeGrantRole(agentRole, admin);
        infra.registry.proposeGrantRole(agentRole, admin);
    }

    function _persistAddresses(Infra memory infra) internal {
        string memory objKey = "infra";
        vm.serializeAddress(objKey, "moeda", address(infra.currency));
        vm.serializeAddress(objKey, "policy", address(infra.policy));
        vm.serializeAddress(objKey, "tokenImplementacao", address(infra.tokenImplementation));
        vm.serializeAddress(objKey, "gateway", address(infra.gateway));
        vm.serializeAddress(objKey, "tokenFactory", address(infra.tokenFactory));
        vm.serializeAddress(objKey, "registro", address(infra.registry));
        vm.serializeAddress(objKey, "captacaoImplementacao", address(infra.fundraisingImplementation));
        vm.serializeAddress(objKey, "captacaoFactory", address(infra.fundraisingFactory));
        string memory finalJson = vm.serializeAddress(objKey, "orquestrador", address(infra.orchestrator));
        vm.writeJson(finalJson, OUTPUT_PATH);
    }

    function _logResults(Infra memory infra, address admin) internal view {
        console2.log("== DeployFase2Sepolia ==");
        console2.log("Admin/agente (--account):", admin);
        console2.log("");
        console2.log("== Deployed addresses ==");
        console2.log("MockBRL:", address(infra.currency));
        console2.log("DenyAllTransferPolicy:", address(infra.policy));
        console2.log("ParticipacaoToken (implementacao):", address(infra.tokenImplementation));
        console2.log("EmissaoGateway:", address(infra.gateway));
        console2.log("ParticipacaoTokenFactory:", address(infra.tokenFactory));
        console2.log("RegistroInvestidorQualificado:", address(infra.registry));
        console2.log("OfertaCaptacao (implementacao):", address(infra.fundraisingImplementation));
        console2.log("OfertaCaptacaoFactory:", address(infra.fundraisingFactory));
        console2.log("OfertaOrquestrador:", address(infra.orchestrator));
        console2.log("");
        console2.log("AGENTE_ROLE PROPOSED (not executed):");
        console2.log("  - orquestrador em tokenFactory, gateway e captacaoFactory");
        console2.log("  - admin no proprio orquestrador");
        console2.log("  - admin em registro (RegistroInvestidorQualificado)");
        console2.log("Addresses saved to:", OUTPUT_PATH);
        console2.log("");
        console2.log(">> Wait >= 1 hour of REAL time, then run DeployFase2SepoliaExecute.s.sol <<");
    }
}
