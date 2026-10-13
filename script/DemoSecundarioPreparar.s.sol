// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RegistroInvestidorQualificado} from "../src/registro/RegistroInvestidorQualificado.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";
import {LiquidacaoSecundaria} from "../src/secundario/LiquidacaoSecundaria.sol";

/// @title DemoSecundarioPreparar (prepare the secondary market demo)
/// @notice Part 2/3 of the public secondary-market demo on Sepolia. Run only after
/// `DemoSecundarioSetup.s.sol` and after >= 1h of REAL time has passed. Executes the proposed
/// `AGENTE_ROLE`, puts shares in the seller's hands by the most direct path
/// (`EmissaoGateway.emitir`, no escrow), configures the `RestrictedTransferPolicy` for that
/// token (eligibility + lock-up, operational, no timelock) and PROPOSES (does not execute) the
/// token's policy migration + secondary-market opening.
/// @dev The lock-up is real and short (10 minutes); it expires within the next 1h wait, so
/// `DemoSecundario.s.sol` already finds the assignment releasable when it runs. `vm.warp` does
/// not affect Sepolia (same caveat as `DemoSecundarioSetup.s.sol`).
contract DemoSecundarioPreparar is Script {
    string internal constant OUTPUT_PATH = "./script/output/demo-secundario.json";
    uint256 internal constant TIMELOCK_DELAY = 1 hours;
    uint256 internal constant LOCKUP_DURATION = 10 minutes;

    uint256 internal constant AUTHORIZED_SHARES = 1_000_000 ether;
    uint256 internal constant SELLER_SHARES = 50 ether; // 50 shares, precoPorCota = 100 MockBRL

    struct Config {
        uint256 deployerPk;
        address deployer;
        address seller;
        address buyer;
    }

    struct Infra {
        MockBRL currency;
        RestrictedTransferPolicy restricted;
        EmissaoGateway gateway;
        ParticipacaoTokenFactory tokenFactory;
        RegistroInvestidorQualificado registry;
        OfertaCaptacaoFactory fundraisingFactory;
        LiquidacaoSecundaria settlement;
    }

    function run() external returns (address token) {
        Config memory cfg = _readConfig();
        Infra memory infra = _readAddresses();

        console2.log("== DemoSecundarioPreparar ==");
        console2.log("Seller:", cfg.seller);
        console2.log("Buyer:", cfg.buyer);

        vm.startBroadcast(cfg.deployerPk);
        _executeAgent(infra, cfg.deployer);
        token = _createOfferingAndIssue(infra, cfg);
        _configurePolicy(infra, token, cfg);
        uint256 policyExecuteAfter = _proposeMigrationAndOpening(infra, token);
        vm.stopBroadcast();

        vm.writeJson(vm.toString(token), OUTPUT_PATH, ".token");

        _logResults(token, policyExecuteAfter);
    }

    // ── Configuration ───────────────────────────────────────────────────────────────────

    function _readConfig() internal view returns (Config memory cfg) {
        cfg.deployerPk = vm.envUint("PRIVATE_KEY");
        cfg.deployer = vm.addr(cfg.deployerPk);
        cfg.seller = vm.addr(vm.envUint("INVESTIDOR1_PRIVATE_KEY"));
        cfg.buyer = vm.addr(vm.envUint("INVESTIDOR2_PRIVATE_KEY"));
    }

    function _readAddresses() internal returns (Infra memory infra) {
        string memory json = vm.readFile(OUTPUT_PATH);
        infra.currency = MockBRL(vm.parseJsonAddress(json, ".currency"));
        infra.restricted = RestrictedTransferPolicy(vm.parseJsonAddress(json, ".restricted"));
        infra.gateway = EmissaoGateway(vm.parseJsonAddress(json, ".gateway"));
        infra.tokenFactory = ParticipacaoTokenFactory(vm.parseJsonAddress(json, ".tokenFactory"));
        infra.registry = RegistroInvestidorQualificado(vm.parseJsonAddress(json, ".registry"));
        infra.fundraisingFactory = OfertaCaptacaoFactory(vm.parseJsonAddress(json, ".fundraisingFactory"));
        infra.settlement = LiquidacaoSecundaria(vm.parseJsonAddress(json, ".liquidacao"));
    }

    // ── Execution of the AGENTE_ROLE proposed in DemoSecundarioSetup ────────────────────

    function _executeAgent(Infra memory infra, address agent) internal {
        bytes32 role = keccak256("AGENTE_ROLE");
        address[6] memory targets = [
            address(infra.gateway),
            address(infra.tokenFactory),
            address(infra.registry),
            address(infra.fundraisingFactory),
            address(infra.restricted),
            address(infra.settlement)
        ];
        for (uint256 i = 0; i < targets.length; i++) {
            (bool ok,) = targets[i].call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, agent));
            require(ok, "executeGrantRole failed (timelock not elapsed yet?)");
        }
    }

    // ── Offering + direct issuance to the seller (most direct path, no escrow) ─────────

    function _createOfferingAndIssue(Infra memory infra, Config memory cfg) internal returns (address token) {
        token = infra.tokenFactory.criarOferta(
            "Oferta Demo Secundario",
            "nSEC",
            "Empresa Secundario Demo Ltda",
            keccak256(abi.encode("cnpj-demo-secundario", block.timestamp)),
            "2026-DEMO-SECUNDARIO"
        );
        infra.gateway.atestarCotas(token, AUTHORIZED_SHARES);
        infra.gateway.emitir(token, cfg.seller, SELLER_SHARES);
    }

    // ── RestrictedTransferPolicy: elegibilidade + lock-up (operacional) ────────────────

    function _configurePolicy(Infra memory infra, address token, Config memory cfg) internal {
        infra.restricted.definirElegivel(token, cfg.seller, true);
        infra.restricted.definirElegivel(token, cfg.buyer, true);
        infra.restricted.definirLockup(token, uint64(block.timestamp + LOCKUP_DURATION));
    }

    // ── Proposes (does not execute) the policy migration + secondary-market opening ─────

    function _proposeMigrationAndOpening(Infra memory infra, address token) internal returns (uint256 executeAfter) {
        infra.gateway.proposeSetTransferPolicy(token, address(infra.restricted));
        executeAfter = infra.restricted.proposeSetSecundarioLiberado(token, true);
    }

    // ── Logs ────────────────────────────────────────────────────────────────────────────

    function _logResults(address token, uint256 policyExecuteAfter) internal view {
        console2.log("");
        console2.log("Token (demo offering):", token);
        console2.log("Seller received (should be 50 ether = 50 shares)");
        console2.log("Lock-up expira em (timestamp):", block.timestamp + LOCKUP_DURATION);
        console2.log("Policy migration + opening PROPOSED, executeAfter:", policyExecuteAfter);
        console2.log("Token atualizado em:", OUTPUT_PATH);
        console2.log("");
        console2.log(">> Wait >= 1 hour of REAL time (the 10-min lock-up will have expired), then run DemoSecundario.s.sol <<");
    }
}
