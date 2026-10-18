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

/// @title DemoSepolia_Setup
/// @notice Part 1/2 of the public Phase 2 demo on Sepolia (see CLAUDE.md, "Non-negotiable
/// rules", and the demo instruction). Deploys all the infrastructure and PROPOSES (but does not
/// execute) granting `AGENTE_ROLE` to the deployer itself on the four contracts that require it.
/// @dev `AGENTE_ROLE` is granted through the timelock (`MIN_TIMELOCK_DELAY = 1 hours`, see
/// `TimelockedAccessControl.sol`); on a real network that requires 1h of REAL time to pass
/// between propose and execute (`vm.warp` only "fools" the clock in local simulation, never
/// against a real chain receiving real transactions; same caveat already documented for
/// `DeployFase1.s.sol`/`DeployFase2.s.sol`). That is why the Sepolia demo is split into two
/// scripts: this one proposes, `DemoSepolia.s.sol` executes (after waiting the hour) and runs
/// the rest of the cycle. The deployed addresses are persisted in
/// `./script/output/demo-sepolia.json` so the second script can rebuild the same state.
contract DemoSepolia_Setup is Script {
    uint256 internal constant TIMELOCK_DELAY = 1 hours;
    string internal constant OUTPUT_PATH = "./script/output/demo-sepolia.json";

    struct Infra {
        MockBRL currency;
        DenyAllTransferPolicy policy;
        ParticipacaoToken tokenImplementation;
        EmissaoGateway gateway;
        ParticipacaoTokenFactory tokenFactory;
        RegistroInvestidorQualificado registry;
        OfertaCaptacao fundraisingImplementation;
        OfertaCaptacaoFactory fundraisingFactory;
    }

    function run() external returns (Infra memory infra) {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        console2.log("== DemoSepolia_Setup ==");
        console2.log("Deployer/admin/agente:", deployer);
        console2.log("Timelock delay (segundos):", TIMELOCK_DELAY);

        vm.startBroadcast(deployerPk);
        infra = _deployInfra(deployer);
        _proposeAgent(infra, deployer);
        vm.stopBroadcast();

        _persistAddresses(infra);
        _logResults(infra, deployer);
    }

    function _deployInfra(address admin) internal returns (Infra memory infra) {
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
    }

    /// @dev Proposes (does not execute) AGENTE_ROLE for `agent` on the four contracts that require it.
    function _proposeAgent(Infra memory infra, address agent) internal {
        bytes32 role = keccak256("AGENTE_ROLE");
        address[4] memory targets = [
            address(infra.gateway),
            address(infra.tokenFactory),
            address(infra.registry),
            address(infra.fundraisingFactory)
        ];
        for (uint256 i = 0; i < targets.length; i++) {
            (bool ok,) = targets[i].call(abi.encodeWithSignature("proposeGrantRole(bytes32,address)", role, agent));
            require(ok, "proposeGrantRole failed");
        }
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
        string memory finalJson = vm.serializeAddress(objKey, "captacaoFactory", address(infra.fundraisingFactory));
        vm.writeJson(finalJson, OUTPUT_PATH);
    }

    function _logResults(Infra memory infra, address deployer) internal view {
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
        console2.log("");
        console2.log("AGENTE_ROLE PROPOSED (not executed) for:", deployer);
        console2.log("Addresses saved to:", OUTPUT_PATH);
        console2.log("");
        console2.log(">> Wait >= 1 hour of REAL time, then run DemoSepolia.s.sol <<");
    }
}
