// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RegistroInvestidorQualificado} from "../src/registro/RegistroInvestidorQualificado.sol";
import {OfertaCaptacao} from "../src/captacao/OfertaCaptacao.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";
import {LiquidacaoSecundaria} from "../src/secundario/LiquidacaoSecundaria.sol";

/// @title DemoSecundarioSetup (set up the secondary market demo)
/// @notice Part 1/3 of the public secondary-market (Phase 4) demo on Sepolia. Deploys the full
/// current set (Phases 1-4) and PROPOSES (does not execute) `AGENTE_ROLE` to the deployer
/// itself on the six contracts that require it: `EmissaoGateway`, `ParticipacaoTokenFactory`,
/// `RegistroInvestidorQualificado`, `OfertaCaptacaoFactory`, `RestrictedTransferPolicy` and
/// `LiquidacaoSecundaria`.
/// @dev Fresh deploy on purpose: the previous demo's token (`DEMO_SEPOLIA.md`) points at
/// `DenyAllTransferPolicy` and came from an implementation older than the Phase 3 policy
/// setter (`ParticipacaoToken.setTransferPolicy`), so it cannot be migrated. That is why we
/// deploy the current set from scratch.
///
/// `RestrictedTransferPolicy` also gets `AGENTE_ROLE` here, in addition to the four contracts
/// already listed in the Phase 2 demo; without it, `DemoSecundarioPreparar.s.sol` cannot call
/// `definirElegivel`/`definirLockup` (both `onlyRole(AGENTE_ROLE)`).
///
/// The timelock (1h) hits two points in this demo (granting `AGENTE_ROLE` here, and migrating
/// the token's policy + opening the secondary market in `DemoSecundarioPreparar.s.sol`), and
/// the token only exists after the first. That is why there are TWO real 1h waits across
/// THREE scripts: this one proposes, `DemoSecundarioPreparar.s.sol` executes and proposes
/// again, `DemoSecundario.s.sol` executes and closes the assignment. `vm.warp` does not affect
/// a real network receiving real transactions (same caveat as
/// `DeployFase1.s.sol`/`DemoSepolia_Setup.s.sol`): on Sepolia the time must really pass
/// between propose and execute.
contract DemoSecundarioSetup is Script {
    uint256 internal constant TIMELOCK_DELAY = 1 hours;
    string internal constant OUTPUT_PATH = "./script/output/demo-secundario.json";

    struct Infra {
        MockBRL currency;
        DenyAllTransferPolicy denyAll;
        RestrictedTransferPolicy restricted;
        ParticipacaoToken tokenImplementation;
        EmissaoGateway gateway;
        ParticipacaoTokenFactory tokenFactory;
        RegistroInvestidorQualificado registry;
        OfertaCaptacao fundraisingImplementation;
        OfertaCaptacaoFactory fundraisingFactory;
        LiquidacaoSecundaria settlement;
    }

    function run() external returns (Infra memory infra) {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address protocoloWallet = vm.envAddress("PROTOCOLO_WALLET_ADDRESS");

        console2.log("== DemoSecundarioSetup ==");
        console2.log("Deployer/admin/agente:", deployer);
        console2.log("Protocolo wallet:", protocoloWallet);
        console2.log("Timelock delay (segundos):", TIMELOCK_DELAY);

        vm.startBroadcast(deployerPk);
        infra = _deployInfra(deployer, protocoloWallet);
        _proposeAgent(infra, deployer);
        vm.stopBroadcast();

        _persistAddresses(infra);
        _logResults(infra, deployer);
    }

    function _deployInfra(address admin, address protocoloWallet) internal returns (Infra memory infra) {
        infra.currency = new MockBRL();
        infra.denyAll = new DenyAllTransferPolicy();
        infra.restricted = new RestrictedTransferPolicy(admin, TIMELOCK_DELAY);
        infra.tokenImplementation = new ParticipacaoToken();
        infra.gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        infra.tokenFactory = new ParticipacaoTokenFactory(
            admin, address(infra.tokenImplementation), address(infra.gateway), address(infra.denyAll), TIMELOCK_DELAY
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
        infra.settlement =
            new LiquidacaoSecundaria(admin, address(infra.currency), address(infra.tokenFactory), protocoloWallet, TIMELOCK_DELAY);
    }

    /// @dev Proposes (does not execute) AGENTE_ROLE for `agent` on the six contracts that require it.
    function _proposeAgent(Infra memory infra, address agent) internal {
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
            (bool ok,) = targets[i].call(abi.encodeWithSignature("proposeGrantRole(bytes32,address)", role, agent));
            require(ok, "proposeGrantRole failed");
        }
    }

    function _persistAddresses(Infra memory infra) internal {
        string memory objKey = "infra";
        vm.serializeAddress(objKey, "moeda", address(infra.currency));
        vm.serializeAddress(objKey, "denyAll", address(infra.denyAll));
        vm.serializeAddress(objKey, "restricted", address(infra.restricted));
        vm.serializeAddress(objKey, "tokenImplementacao", address(infra.tokenImplementation));
        vm.serializeAddress(objKey, "gateway", address(infra.gateway));
        vm.serializeAddress(objKey, "tokenFactory", address(infra.tokenFactory));
        vm.serializeAddress(objKey, "registro", address(infra.registry));
        vm.serializeAddress(objKey, "captacaoImplementacao", address(infra.fundraisingImplementation));
        vm.serializeAddress(objKey, "captacaoFactory", address(infra.fundraisingFactory));
        string memory finalJson = vm.serializeAddress(objKey, "liquidacao", address(infra.settlement));
        vm.writeJson(finalJson, OUTPUT_PATH);
    }

    function _logResults(Infra memory infra, address deployer) internal view {
        console2.log("");
        console2.log("== Deployed addresses ==");
        console2.log("MockBRL:", address(infra.currency));
        console2.log("DenyAllTransferPolicy:", address(infra.denyAll));
        console2.log("RestrictedTransferPolicy:", address(infra.restricted));
        console2.log("ParticipacaoToken (implementacao):", address(infra.tokenImplementation));
        console2.log("EmissaoGateway:", address(infra.gateway));
        console2.log("ParticipacaoTokenFactory:", address(infra.tokenFactory));
        console2.log("RegistroInvestidorQualificado:", address(infra.registry));
        console2.log("OfertaCaptacao (implementacao):", address(infra.fundraisingImplementation));
        console2.log("OfertaCaptacaoFactory:", address(infra.fundraisingFactory));
        console2.log("LiquidacaoSecundaria:", address(infra.settlement));
        console2.log("");
        console2.log("AGENTE_ROLE PROPOSED (not executed, 6 contracts) for:", deployer);
        console2.log("Addresses saved to:", OUTPUT_PATH);
        console2.log("");
        console2.log(">> Wait >= 1 hour of REAL time, then run DemoSecundarioPreparar.s.sol <<");
    }
}
