// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockedAccessControl} from "../src/governance/TimelockedAccessControl.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RegistroInvestidorQualificado} from "../src/registro/RegistroInvestidorQualificado.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";
import {OfertaOrquestrador} from "../src/orquestracao/OfertaOrquestrador.sol";

/// @title DeployFase2SepoliaExecute (Phase 2 Sepolia execution)
/// @notice Part 2/2. Run only after `DeployFase2Sepolia.s.sol` and after >= 1h of REAL time has
/// passed (see that script's NatSpec on why the timelock cannot be skipped on a real network).
/// Reads the 9 addresses deployed in `./script/output/fase2-sepolia.json`, never received
/// through hand-typed environment variables (nine addresses invite typos; a wrong one points the
/// execution at the wrong contract). Executes the 5 proposed `AGENTE_ROLE` grants (including
/// `RegistroInvestidorQualificado`, a prerequisite of `definirQualificado` for any investor who
/// needs to invest above an offering's `tetoPorInvestidor`; see `DeployFase2Sepolia.s.sol`'s
/// NatSpec) and authorizes the first issuer to operate the self-service channel.
/// @dev Single signer: the account resolved by `--account` (the same one used in the deploy; it
/// must hold `DEFAULT_ADMIN_ROLE` on the five contracts, granted to itself in the previous
/// script). Idempotent: each `executeGrantRole` checks `hasRole` first and skips if already
/// granted, so running this script more than once does not break (`autorizarEmissor` is also
/// naturally idempotent: writing `true` again has no side effect).
///
/// Usage:
///   EMISSOR_WALLET_ADDRESS=0x... \
///   forge script script/DeployFase2SepoliaExecute.s.sol --rpc-url sepolia --account niara-admin \
///     --broadcast
contract DeployFase2SepoliaExecute is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    string internal constant OUTPUT_PATH = "./script/output/fase2-sepolia.json";

    error InvalidNetwork(uint256 currentChainId, uint256 expectedChainId);
    error AddressFileNotFound(string path);

    struct Infra {
        ParticipacaoTokenFactory tokenFactory;
        EmissaoGateway gateway;
        RegistroInvestidorQualificado registry;
        OfertaCaptacaoFactory fundraisingFactory;
        OfertaOrquestrador orchestrator;
    }

    function run() external {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert InvalidNetwork(block.chainid, SEPOLIA_CHAIN_ID);
        if (!vm.isFile(OUTPUT_PATH)) revert AddressFileNotFound(OUTPUT_PATH);

        Infra memory infra = _readAddresses();
        address emissorWallet = vm.envAddress("EMISSOR_WALLET_ADDRESS");

        vm.startBroadcast();
        address admin = msg.sender;

        _executePendingAgent(infra, admin);
        infra.orchestrator.autorizarEmissor(emissorWallet);
        vm.stopBroadcast();

        _logResults(infra, admin, emissorWallet);
    }

    function _readAddresses() internal returns (Infra memory infra) {
        string memory json = vm.readFile(OUTPUT_PATH);
        infra.tokenFactory = ParticipacaoTokenFactory(vm.parseJsonAddress(json, ".tokenFactory"));
        infra.gateway = EmissaoGateway(vm.parseJsonAddress(json, ".gateway"));
        infra.registry = RegistroInvestidorQualificado(vm.parseJsonAddress(json, ".registry"));
        infra.fundraisingFactory = OfertaCaptacaoFactory(vm.parseJsonAddress(json, ".fundraisingFactory"));
        infra.orchestrator = OfertaOrquestrador(vm.parseJsonAddress(json, ".orquestrador"));
    }

    /// @dev Idempotent: checks `hasRole` before each `executeGrantRole` and skips if already
    /// granted, instead of letting `_consumeAction` revert with `ActionNotPending` on a second
    /// call. If the timelock has not passed yet, `executeGrantRole` reverts with
    /// `TimelockNotElapsed` (expected, not a bug; see CLAUDE.md).
    function _executePendingAgent(Infra memory infra, address admin) internal {
        bytes32 agentRole = infra.orchestrator.AGENTE_ROLE();

        _executeIfNeeded(infra.tokenFactory, agentRole, address(infra.orchestrator));
        _executeIfNeeded(infra.gateway, agentRole, address(infra.orchestrator));
        _executeIfNeeded(infra.fundraisingFactory, agentRole, address(infra.orchestrator));
        _executeIfNeeded(infra.orchestrator, agentRole, admin);
        _executeIfNeeded(infra.registry, agentRole, admin);
    }

    function _executeIfNeeded(TimelockedAccessControl target, bytes32 role, address account) internal {
        if (target.hasRole(role, account)) {
            console2.log("Already granted, skipping:", address(target));
            return;
        }
        target.executeGrantRole(role, account);
    }

    function _logResults(Infra memory infra, address admin, address emissorWallet) internal view {
        console2.log("== DeployFase2SepoliaExecute ==");
        console2.log("Admin/agente (--account):", admin);
        console2.log("");
        console2.log("AGENTE_ROLE confirmado:");
        console2.log(
            "  orquestrador em tokenFactory:",
            infra.tokenFactory.hasRole(infra.orchestrator.AGENTE_ROLE(), address(infra.orchestrator))
        );
        console2.log(
            "  orquestrador em gateway:",
            infra.gateway.hasRole(infra.orchestrator.AGENTE_ROLE(), address(infra.orchestrator))
        );
        console2.log(
            "  orquestrador em captacaoFactory:",
            infra.fundraisingFactory.hasRole(infra.orchestrator.AGENTE_ROLE(), address(infra.orchestrator))
        );
        console2.log("  admin no orquestrador:", infra.orchestrator.hasRole(infra.orchestrator.AGENTE_ROLE(), admin));
        console2.log(
            "  admin no registro (RegistroInvestidorQualificado):",
            infra.registry.hasRole(infra.orchestrator.AGENTE_ROLE(), admin)
        );
        console2.log("");
        console2.log("Issuer authorized (emissoresAutorizados == true expected):", emissorWallet);
        console2.log("");
        console2.log(">> The issuer now creates its own offering by calling criarOfertaCompleta on");
        console2.log(">> OfertaOrquestrador, from its OWN wallet (cast send --account <issuer name>).");
    }
}
