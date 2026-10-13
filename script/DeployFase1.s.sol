// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";

/// @title DeployFase1 (Phase 1 deploy)
/// @notice LOCAL/DRY-RUN demo script for Phase 1. Deploys the default policy
/// (`DenyAllTransferPolicy`), the token template implementation, the `EmissaoGateway` and the
/// `ParticipacaoTokenFactory`; grants `AGENTE_ROLE` to the demo agent; creates an offering,
/// attests shares and issues a batch to a test investor. Prints every deployed address at
/// the end.
/// @dev NEVER run with `--broadcast` against Sepolia without an explicit instruction from the
/// user (see CLAUDE.md, rule "No Sepolia deploy without an explicit instruction"). This script
/// uses `vm.warp` to "skip" the timelock delay between `propose` and `execute`, which only
/// reflects reality in local simulation (no `--broadcast`) or against an ephemeral `anvil`.
/// Against a real network, the time must really pass between the two calls (same caveat
/// documented in `niara-contracts/script/Deploy.s.sol`, which is why it splits deploy and
/// wiring into two separate broadcasts; here we chose a single `run()` designed for a local
/// demo, where `vm.warp` is valid).
contract DeployFase1 is Script {
    uint256 internal constant TIMELOCK_DELAY = 1 hours;
    uint256 internal constant DEMO_AUTHORIZED_SHARES = 100_000 ether;
    uint256 internal constant DEMO_ISSUED_SHARES = 10_000 ether;

    struct Config {
        uint256 deployerPrivateKey;
        address admin;
        address agent;
        address demoInvestor;
    }

    function run()
        external
        returns (
            DenyAllTransferPolicy policy,
            ParticipacaoToken implementacao,
            EmissaoGateway gateway,
            ParticipacaoTokenFactory factory,
            address demoOffering
        )
    {
        Config memory cfg = _readConfig();
        _logConfig(cfg);

        vm.startBroadcast(cfg.deployerPrivateKey);

        (policy, implementacao, gateway, factory) = _deployAll(cfg);
        _grantAgent(gateway, factory, cfg.agent);
        demoOffering = _createAttestIssue(gateway, factory, cfg.demoInvestor);

        vm.stopBroadcast();

        _logDeployedAddresses(policy, implementacao, gateway, factory, demoOffering);
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────────────

    function _readConfig() internal view returns (Config memory cfg) {
        cfg.deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(1));
        address deployer = vm.addr(cfg.deployerPrivateKey);
        cfg.admin = vm.envOr("ADMIN_ADDRESS", deployer);
        cfg.agent = vm.envOr("AGENTE_ADDRESS", deployer);
        cfg.demoInvestor = vm.envOr("INVESTIDOR_DEMO_ADDRESS", deployer);
    }

    function _deployAll(Config memory cfg)
        internal
        returns (
            DenyAllTransferPolicy policy,
            ParticipacaoToken implementacao,
            EmissaoGateway gateway,
            ParticipacaoTokenFactory factory
        )
    {
        policy = new DenyAllTransferPolicy();
        implementacao = new ParticipacaoToken();
        gateway = new EmissaoGateway(cfg.admin, TIMELOCK_DELAY);
        factory = new ParticipacaoTokenFactory(
            cfg.admin, address(implementacao), address(gateway), address(policy), TIMELOCK_DELAY
        );
    }

    /// @dev Grants AGENTE_ROLE on gateway and factory to the demo agent, via
    /// propose→warp→execute (see the caveat in the contract NatSpec about the validity of `vm.warp`).
    function _grantAgent(EmissaoGateway gateway, ParticipacaoTokenFactory factory, address agent) internal {
        bytes32 gatewayAgentRole = gateway.AGENTE_ROLE();
        bytes32 factoryAgentRole = factory.AGENTE_ROLE();

        gateway.proposeGrantRole(gatewayAgentRole, agent);
        factory.proposeGrantRole(factoryAgentRole, agent);

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        gateway.executeGrantRole(gatewayAgentRole, agent);
        factory.executeGrantRole(factoryAgentRole, agent);
    }

    function _createAttestIssue(EmissaoGateway gateway, ParticipacaoTokenFactory factory, address demoInvestor)
        internal
        returns (address token)
    {
        token = factory.criarOferta(
            "Oferta Demo Fase 1", "nDEMO", "Empresa Demo Ltda", keccak256("cnpj-demo"), "2026-A"
        );

        gateway.atestarCotas(token, DEMO_AUTHORIZED_SHARES);
        gateway.emitir(token, demoInvestor, DEMO_ISSUED_SHARES);
    }

    // ── Logs ────────────────────────────────────────────────────────────────────────────

    function _logConfig(Config memory cfg) internal pure {
        console2.log("== Configuracao ==");
        console2.log("Admin:", cfg.admin);
        console2.log("Agente:", cfg.agent);
        console2.log("Demo investor:", cfg.demoInvestor);
        console2.log("Timelock delay (segundos):", TIMELOCK_DELAY);
    }

    function _logDeployedAddresses(
        DenyAllTransferPolicy policy,
        ParticipacaoToken implementacao,
        EmissaoGateway gateway,
        ParticipacaoTokenFactory factory,
        address demoOffering
    ) internal pure {
        console2.log("");
        console2.log("== Deployed addresses ==");
        console2.log("DenyAllTransferPolicy:", address(policy));
        console2.log("ParticipacaoToken (implementacao/template):", address(implementacao));
        console2.log("EmissaoGateway:", address(gateway));
        console2.log("ParticipacaoTokenFactory:", address(factory));
        console2.log("Demo offering (clone):", demoOffering);
        console2.log("");
        console2.log("Authorized shares in the demo offering:", DEMO_AUTHORIZED_SHARES);
        console2.log("Shares issued to the demo investor:", DEMO_ISSUED_SHARES);
    }
}
