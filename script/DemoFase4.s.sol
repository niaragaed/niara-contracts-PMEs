// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {LiquidacaoSecundaria} from "../src/secundario/LiquidacaoSecundaria.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";

/// @title DemoFase4 (Phase 4 demo)
/// @notice LOCAL/DRY-RUN demo script for Phase 4: a bilateral assignment on the secondary
/// market, end to end. A seller holds shares (issuance mini-cycle via gateway); the token
/// migrates from `DenyAllTransferPolicy` to `RestrictedTransferPolicy` (same sequence as
/// Phase 3); the AGENT sets lock-up + allowlist and governance opens the secondary market
/// (timelock); the two counterexamples are proven (an assignment before the lock-up and to a
/// non-eligible buyer both revert); only then does `LiquidacaoSecundaria.liquidarCessao` swap
/// shares for `MockBRL` atomically, with both parties having pre-approved their allowances.
/// This contract never holds anything.
/// @dev NEVER run with `--broadcast` against Sepolia without an explicit instruction from the
/// user (see CLAUDE.md). Same caveat as `DeployFase1.s.sol`/`DeployFase2.s.sol`/`DemoFase3.s.sol`
/// about `vm.warp`: it only "skips" the timelock delay and the lock-up in local simulation (no
/// `--broadcast`) or against an ephemeral `anvil`; against a real network, the time must
/// really pass.
contract DemoFase4 is Script {
    uint256 internal constant TIMELOCK_DELAY = 1 hours;
    uint256 internal constant DEMO_AUTHORIZED_SHARES = 100_000 ether;
    uint256 internal constant DEMO_SELLER_SHARES = 1_000 ether;
    uint256 internal constant DEMO_LOCKUP_SECONDS = 7 days;
    uint256 internal constant DEMO_PRICE_PER_SHARE = 100 ether;
    uint256 internal constant DEMO_ASSIGNMENT_QUANTITY = 50 ether; // 50 shares

    struct Config {
        uint256 deployerPrivateKey;
        uint256 sellerPrivateKey;
        uint256 buyerPrivateKey;
        address admin;
        address agent;
        address protocolWallet;
        address seller;
        address buyer;
        address notEligible;
    }

    struct Infra {
        DenyAllTransferPolicy denyAll;
        RestrictedTransferPolicy restricted;
        ParticipacaoToken tokenImplementation;
        EmissaoGateway gateway;
        ParticipacaoTokenFactory factory;
        MockBRL currency;
        LiquidacaoSecundaria settlement;
        address token;
    }

    function run() external returns (Infra memory infra) {
        Config memory cfg = _readConfig();
        _logConfig(cfg);

        vm.startBroadcast(cfg.deployerPrivateKey);
        infra = _deployInfra(cfg);
        _grantAgent(infra, cfg.agent);
        _createOfferingAndIssue(infra, cfg);
        vm.stopBroadcast();

        vm.startBroadcast(cfg.deployerPrivateKey);
        _migrateToRestricted(infra);
        _prepareRestricted(infra, cfg);
        _openSecondary(infra);
        vm.stopBroadcast();

        console2.log("");
        console2.log("== Counterexample 1: assignment before the lock-up (secondary already open) ==");
        _trySettle(infra, cfg, cfg.buyer, "seller -> buyer (too early)");

        vm.warp(block.timestamp + DEMO_LOCKUP_SECONDS + 1);

        console2.log("");
        console2.log("== Counterexample 2: assignment to a buyer outside the allowlist ==");
        _trySettle(infra, cfg, cfg.notEligible, "seller -> notEligible");

        console2.log("");
        console2.log("== Valid assignment: after the lock-up, eligible buyer ==");
        _prepareAllowancesAndCurrency(infra, cfg);
        _settleSuccessfully(infra, cfg);

        _logFinalState(infra, cfg);
    }

    // ── Configuration ───────────────────────────────────────────────────────────────────

    function _readConfig() internal view returns (Config memory cfg) {
        cfg.deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(1));
        cfg.sellerPrivateKey = vm.envOr("VENDEDOR_PRIVATE_KEY", uint256(2));
        cfg.buyerPrivateKey = vm.envOr("COMPRADOR_PRIVATE_KEY", uint256(3));

        address deployer = vm.addr(cfg.deployerPrivateKey);
        cfg.admin = vm.envOr("ADMIN_ADDRESS", deployer);
        cfg.agent = vm.envOr("AGENTE_ADDRESS", deployer);
        cfg.protocolWallet = vm.envOr("PROTOCOLO_WALLET_ADDRESS", vm.addr(5));
        cfg.seller = vm.addr(cfg.sellerPrivateKey);
        cfg.buyer = vm.addr(cfg.buyerPrivateKey);
        cfg.notEligible = vm.envOr("NAO_ELEGIVEL_ADDRESS", vm.addr(6));
    }

    // ── Infrastructure deploy ───────────────────────────────────────────────────────────

    function _deployInfra(Config memory cfg) internal returns (Infra memory infra) {
        infra.denyAll = new DenyAllTransferPolicy();
        infra.restricted = new RestrictedTransferPolicy(cfg.admin, TIMELOCK_DELAY);
        infra.tokenImplementation = new ParticipacaoToken();
        infra.gateway = new EmissaoGateway(cfg.admin, TIMELOCK_DELAY);
        infra.factory = new ParticipacaoTokenFactory(
            cfg.admin,
            address(infra.tokenImplementation),
            address(infra.gateway),
            address(infra.denyAll),
            TIMELOCK_DELAY
        );
        infra.currency = new MockBRL();
        infra.settlement = new LiquidacaoSecundaria(
            cfg.admin, address(infra.currency), address(infra.factory), cfg.protocolWallet, TIMELOCK_DELAY
        );
    }

    /// @dev Grants AGENTE_ROLE on gateway, factory, restricted and liquidacao, via
    /// propose→warp→execute (same caveat as the previous demos about the validity of `vm.warp`).
    function _grantAgent(Infra memory infra, address agent) internal {
        address[4] memory targets =
            [address(infra.gateway), address(infra.factory), address(infra.restricted), address(infra.settlement)];
        bytes32 role = keccak256("AGENTE_ROLE");

        for (uint256 i = 0; i < targets.length; i++) {
            (bool ok,) = targets[i].call(abi.encodeWithSignature("proposeGrantRole(bytes32,address)", role, agent));
            require(ok, "propose AGENTE_ROLE failed");
        }

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        for (uint256 i = 0; i < targets.length; i++) {
            (bool ok,) = targets[i].call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, agent));
            require(ok, "execute AGENTE_ROLE failed");
        }
    }

    // ── Issuance mini-cycle (the seller comes to hold shares) ──────────────────────────

    function _createOfferingAndIssue(Infra memory infra, Config memory cfg) internal {
        infra.token = infra.factory
            .criarOferta(
                "Oferta Demo Fase 4", "nDEMO4", "Empresa Demo Fase 4 Ltda", keccak256("cnpj-demo-fase4"), "2026-A"
            );

        infra.gateway.atestarCotas(infra.token, DEMO_AUTHORIZED_SHARES);
        infra.gateway.emitir(infra.token, cfg.seller, DEMO_SELLER_SHARES);
    }

    // ── Policy migration + secondary market opening (same sequence as Phase 3) ──────────

    function _migrateToRestricted(Infra memory infra) internal {
        infra.gateway.proposeSetTransferPolicy(infra.token, address(infra.restricted));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        infra.gateway.executeSetTransferPolicy(infra.token, address(infra.restricted));
    }

    function _prepareRestricted(Infra memory infra, Config memory cfg) internal {
        uint64 lockupAte = uint64(block.timestamp + DEMO_LOCKUP_SECONDS);
        infra.restricted.definirLockup(infra.token, lockupAte);
        infra.restricted.definirElegivel(infra.token, cfg.buyer, true);
        // cfg.naoElegivel is deliberately NOT added to the allowlist: it is counterexample 2.
    }

    function _openSecondary(Infra memory infra) internal {
        infra.restricted.proposeSetSecundarioLiberado(infra.token, true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        infra.restricted.executeSetSecundarioLiberado(infra.token, true);
    }

    // ── Allowances + the buyer's MockBRL balance ────────────────────────────────────────

    function _prepareAllowancesAndCurrency(Infra memory infra, Config memory cfg) internal {
        infra.currency.mint(cfg.buyer, 1_000_000 ether);

        vm.startBroadcast(cfg.sellerPrivateKey);
        ParticipacaoToken(infra.token).approve(address(infra.settlement), type(uint256).max);
        vm.stopBroadcast();

        vm.startBroadcast(cfg.buyerPrivateKey);
        infra.currency.approve(address(infra.settlement), type(uint256).max);
        vm.stopBroadcast();
    }

    // ── Settlement attempts (counterexamples) ───────────────────────────────────────────

    function _trySettle(Infra memory infra, Config memory cfg, address comprador, string memory label) internal {
        vm.startBroadcast(cfg.deployerPrivateKey);
        try infra.settlement
            .liquidarCessao(infra.token, cfg.seller, comprador, DEMO_ASSIGNMENT_QUANTITY, DEMO_PRICE_PER_SHARE) {
            console2.log(string.concat("[INESPERADO] cessao passou: ", label));
            revert("Phase 4: assignment should have reverted");
        } catch {
            console2.log(string.concat("[OK] assignment reverted as expected: ", label));
        }
        vm.stopBroadcast();
    }

    function _settleSuccessfully(Infra memory infra, Config memory cfg) internal {
        vm.startBroadcast(cfg.deployerPrivateKey);
        infra.settlement
            .liquidarCessao(infra.token, cfg.seller, cfg.buyer, DEMO_ASSIGNMENT_QUANTITY, DEMO_PRICE_PER_SHARE);
        vm.stopBroadcast();
        console2.log("[OK] seller -> buyer assignment settled");
    }

    // ── Logs ────────────────────────────────────────────────────────────────────────────

    function _logConfig(Config memory cfg) internal pure {
        console2.log("== Configuracao ==");
        console2.log("Admin:", cfg.admin);
        console2.log("Agente:", cfg.agent);
        console2.log("Protocolo wallet:", cfg.protocolWallet);
        console2.log("Seller:", cfg.seller);
        console2.log("Buyer (eligible):", cfg.buyer);
        console2.log("Not eligible (counterexample):", cfg.notEligible);
        console2.log("Timelock delay (segundos):", TIMELOCK_DELAY);
        console2.log("Lock-up (segundos):", DEMO_LOCKUP_SECONDS);
    }

    function _logFinalState(Infra memory infra, Config memory cfg) internal view {
        console2.log("");
        console2.log("== Deployed addresses ==");
        console2.log("RestrictedTransferPolicy:", address(infra.restricted));
        console2.log("EmissaoGateway:", address(infra.gateway));
        console2.log("ParticipacaoTokenFactory:", address(infra.factory));
        console2.log("LiquidacaoSecundaria:", address(infra.settlement));
        console2.log("Token (demo offering):", infra.token);

        console2.log("");
        console2.log("== Final balances (after the assignment) ==");
        console2.log("Seller shares:", ParticipacaoToken(infra.token).balanceOf(cfg.seller));
        console2.log("Buyer shares:", ParticipacaoToken(infra.token).balanceOf(cfg.buyer));
        console2.log("Seller MockBRL (received the amount, fee=0):", infra.currency.balanceOf(cfg.seller));
        console2.log("Buyer MockBRL (paid the amount):", infra.currency.balanceOf(cfg.buyer));
        console2.log("Protocol MockBRL (fee=0 in this phase):", infra.currency.balanceOf(cfg.protocolWallet));
        console2.log("taxaSecundarioBps vigente:", infra.settlement.taxaSecundarioBps());
    }
}
