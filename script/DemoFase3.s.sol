// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";

/// @title DemoFase3 (Phase 3 demo)
/// @notice LOCAL/DRY-RUN demo script for Phase 3: shows the "open trading after the
/// deadline" cycle. An offering starts with `DenyAllTransferPolicy` (secondary market fully
/// off, the default behavior since Phase 1), the AGENT prepares the `RestrictedTransferPolicy`
/// (lock-up + allowlist) and governance points the token at it (still locked, because
/// `secundarioLiberado` starts as `false`); only after the lock-up has passed AND governance
/// turns on the master flag (timelock) does a transfer between two eligible investors go
/// through. It also proves the two counterexamples: transferring before the release/lock-up
/// still reverts even when already pointing at the Restricted policy, and transferring to
/// someone outside the allowlist reverts even with the secondary market open.
/// @dev NEVER run with `--broadcast` against Sepolia without an explicit instruction from the
/// user (see CLAUDE.md). Same caveat as `DeployFase1.s.sol`/`DeployFase2.s.sol` about `vm.warp`:
/// it only "skips" the timelock delay and the lock-up in local simulation (no `--broadcast`) or
/// against an ephemeral `anvil`; against a real network, the time must really pass.
contract DemoFase3 is Script {
    uint256 internal constant TIMELOCK_DELAY = 1 hours;
    uint256 internal constant DEMO_AUTHORIZED_SHARES = 100_000 ether;
    uint256 internal constant DEMO_INVESTOR1_SHARES = 1_000 ether;
    uint256 internal constant DEMO_INVESTOR2_SHARES = 1_000 ether;
    uint256 internal constant DEMO_TRANSFER_AMOUNT = 100 ether;
    uint256 internal constant DEMO_LOCKUP_SECONDS = 7 days;

    struct Config {
        uint256 deployerPrivateKey;
        uint256 investor1PrivateKey;
        uint256 investor2PrivateKey;
        address admin;
        address agent;
        address investor1;
        address investor2;
        address notEligible;
    }

    struct Infra {
        DenyAllTransferPolicy denyAll;
        RestrictedTransferPolicy restricted;
        ParticipacaoToken tokenImplementation;
        EmissaoGateway gateway;
        ParticipacaoTokenFactory factory;
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

        console2.log("");
        console2.log("== Step 1: secondary market off (DenyAllTransferPolicy) ==");
        _tryTransfer(infra, cfg.investor1PrivateKey, cfg.investor2, "investidor1 -> investidor2");

        vm.startBroadcast(cfg.deployerPrivateKey);
        _prepareRestricted(infra, cfg);
        _pointToRestricted(infra);
        vm.stopBroadcast();

        console2.log("");
        console2.log("== Step 2: already points at Restricted, but still locked (open=false, within the lock-up) ==");
        _tryTransfer(infra, cfg.investor1PrivateKey, cfg.investor2, "investidor1 -> investidor2 (cedo demais)");

        vm.warp(block.timestamp + DEMO_LOCKUP_SECONDS + 1);

        vm.startBroadcast(cfg.deployerPrivateKey);
        _openSecondary(infra);
        vm.stopBroadcast();

        console2.log("");
        console2.log("== Step 3: open and after the lock-up, but recipient outside the allowlist ==");
        _tryTransfer(infra, cfg.investor1PrivateKey, cfg.notEligible, "investidor1 -> naoElegivel");

        console2.log("");
        console2.log("== Step 4: open, after the lock-up, eligible recipient ==");
        _transferSuccessfully(infra, cfg);

        _logFinalState(infra, cfg);
    }

    // ── Configuration ───────────────────────────────────────────────────────────────────

    function _readConfig() internal view returns (Config memory cfg) {
        cfg.deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(1));
        cfg.investor1PrivateKey = vm.envOr("INVESTIDOR1_PRIVATE_KEY", uint256(2));
        cfg.investor2PrivateKey = vm.envOr("INVESTIDOR2_PRIVATE_KEY", uint256(3));

        address deployer = vm.addr(cfg.deployerPrivateKey);
        cfg.admin = vm.envOr("ADMIN_ADDRESS", deployer);
        cfg.agent = vm.envOr("AGENTE_ADDRESS", deployer);
        cfg.investor1 = vm.addr(cfg.investor1PrivateKey);
        cfg.investor2 = vm.addr(cfg.investor2PrivateKey);
        cfg.notEligible = vm.envOr("NAO_ELEGIVEL_ADDRESS", vm.addr(6));
    }

    // ── Infrastructure deploy (Phase 1, plus the Phase 3 Restricted policy) ─────────────────

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
    }

    /// @dev Grants AGENTE_ROLE on gateway, factory and restricted, via propose→warp→execute
    /// (same caveat as `DeployFase1`/`DeployFase2` about the validity of `vm.warp`).
    function _grantAgent(Infra memory infra, address agent) internal {
        address[3] memory targets = [address(infra.gateway), address(infra.factory), address(infra.restricted)];
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

    // ── Step 0: issuance mini-cycle (mint via gateway, passes under any policy) ─────────────

    function _createOfferingAndIssue(Infra memory infra, Config memory cfg) internal {
        infra.token = infra.factory
            .criarOferta(
                "Oferta Demo Fase 3", "nDEMO3", "Empresa Demo Fase 3 Ltda", keccak256("cnpj-demo-fase3"), "2026-A"
            );

        infra.gateway.atestarCotas(infra.token, DEMO_AUTHORIZED_SHARES);
        infra.gateway.emitir(infra.token, cfg.investor1, DEMO_INVESTOR1_SHARES);
        infra.gateway.emitir(infra.token, cfg.investor2, DEMO_INVESTOR2_SHARES);
    }

    // ── Step 2: the AGENT prepares the Restricted policy (set-once lock-up + allowlist), governance points
    // the token at it ────────────────────────────────────────────────────────────────────

    function _prepareRestricted(Infra memory infra, Config memory cfg) internal {
        uint64 lockupAte = uint64(block.timestamp + DEMO_LOCKUP_SECONDS);
        infra.restricted.definirLockup(infra.token, lockupAte);
        infra.restricted.definirElegivel(infra.token, cfg.investor1, true);
        infra.restricted.definirElegivel(infra.token, cfg.investor2, true);
        // cfg.naoElegivel is deliberately NOT added to the allowlist: it is Step 3's counterexample.
    }

    function _pointToRestricted(Infra memory infra) internal {
        infra.gateway.proposeSetTransferPolicy(infra.token, address(infra.restricted));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        infra.gateway.executeSetTransferPolicy(infra.token, address(infra.restricted));
    }

    // ── Step 4: governance turns on the master flag (timelock) ────────────────────────────

    function _openSecondary(Infra memory infra) internal {
        infra.restricted.proposeSetSecundarioLiberado(infra.token, true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        infra.restricted.executeSetSecundarioLiberado(infra.token, true);
    }

    // ── Demo transfers ──────────────────────────────────────────────────────────────────

    function _tryTransfer(Infra memory infra, uint256 fromPrivateKey, address to, string memory label) internal {
        vm.startBroadcast(fromPrivateKey);
        try ParticipacaoToken(infra.token).transfer(to, DEMO_TRANSFER_AMOUNT) {
            console2.log(string.concat("[INESPERADO] transferencia passou: ", label));
            revert("Phase 3: transfer should have reverted");
        } catch {
            console2.log(string.concat("[OK] transfer reverted as expected: ", label));
        }
        vm.stopBroadcast();
    }

    function _transferSuccessfully(Infra memory infra, Config memory cfg) internal {
        vm.startBroadcast(cfg.investor1PrivateKey);
        ParticipacaoToken(infra.token).transfer(cfg.investor2, DEMO_TRANSFER_AMOUNT);
        vm.stopBroadcast();
        console2.log("[OK] transferencia investidor1 -> investidor2 passou");
    }

    // ── Logs ────────────────────────────────────────────────────────────────────────────

    function _logConfig(Config memory cfg) internal pure {
        console2.log("== Configuracao ==");
        console2.log("Admin:", cfg.admin);
        console2.log("Agente:", cfg.agent);
        console2.log("Investor 1 (eligible):", cfg.investor1);
        console2.log("Investor 2 (eligible):", cfg.investor2);
        console2.log("Not eligible (counterexample):", cfg.notEligible);
        console2.log("Timelock delay (segundos):", TIMELOCK_DELAY);
        console2.log("Lock-up (segundos):", DEMO_LOCKUP_SECONDS);
    }

    function _logFinalState(Infra memory infra, Config memory cfg) internal view {
        console2.log("");
        console2.log("== Deployed addresses ==");
        console2.log("DenyAllTransferPolicy:", address(infra.denyAll));
        console2.log("RestrictedTransferPolicy:", address(infra.restricted));
        console2.log("EmissaoGateway:", address(infra.gateway));
        console2.log("ParticipacaoTokenFactory:", address(infra.factory));
        console2.log("Token (demo offering):", infra.token);

        console2.log("");
        console2.log("== Final policy state (RestrictedTransferPolicy) ==");
        console2.log("secundarioLiberado:", infra.restricted.secundarioLiberado(infra.token));
        console2.log("lockupAte:", infra.restricted.lockupAte(infra.token));
        console2.log("eligible[investor1]:", infra.restricted.elegivel(infra.token, cfg.investor1));
        console2.log("eligible[investor2]:", infra.restricted.elegivel(infra.token, cfg.investor2));
        console2.log("eligible[notEligible]:", infra.restricted.elegivel(infra.token, cfg.notEligible));

        console2.log("");
        console2.log("== Saldos finais ==");
        console2.log("Investor 1:", ParticipacaoToken(infra.token).balanceOf(cfg.investor1));
        console2.log("Investor 2:", ParticipacaoToken(infra.token).balanceOf(cfg.investor2));
    }
}
