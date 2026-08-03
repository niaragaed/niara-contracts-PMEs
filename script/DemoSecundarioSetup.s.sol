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

/// @title DemoSecundarioSetup
/// @notice Parte 1/3 da demo pública do secundário (Fase 4) em Sepolia. Implanta o conjunto
/// completo atual (Fases 1-4) e PROPÕE (não executa) `AGENTE_ROLE` à própria deployer nos seis
/// contratos que o exigem: `EmissaoGateway`, `ParticipacaoTokenFactory`,
/// `RegistroInvestidorQualificado`, `OfertaCaptacaoFactory`, `RestrictedTransferPolicy` e
/// `LiquidacaoSecundaria`.
/// @dev Fresh deploy de propósito: o token da demo anterior (`DEMO_SEPOLIA.md`) aponta para
/// `DenyAllTransferPolicy` e veio de uma implementação anterior ao setter de política da Fase
/// 3 (`ParticipacaoToken.setTransferPolicy`) — não dá para migrá-lo. Por isso implantamos o
/// conjunto atual do zero.
///
/// `RestrictedTransferPolicy` recebe `AGENTE_ROLE` aqui também, além dos quatro contratos já
/// listados na demo da Fase 2 — sem isso, `DemoSecundarioPreparar.s.sol` não consegue chamar
/// `definirElegivel`/`definirLockup` (ambos `onlyRole(AGENTE_ROLE)`).
///
/// Timelock (1h) atinge dois pontos nesta demo — conceder `AGENTE_ROLE` (aqui) e migrar a
/// política do token + abrir o secundário (`DemoSecundarioPreparar.s.sol`) — e o token só
/// existe depois do primeiro. Por isso são DUAS esperas reais de 1h, em TRÊS scripts: este
/// propõe, `DemoSecundarioPreparar.s.sol` executa e propõe de novo, `DemoSecundario.s.sol`
/// executa e fecha a cessão. `vm.warp` não afeta uma rede real recebendo transações reais
/// (mesma ressalva de `DeployFase1.s.sol`/`DemoSepolia_Setup.s.sol`) — em Sepolia o tempo
/// precisa decorrer de verdade entre propose e execute.
contract DemoSecundarioSetup is Script {
    uint256 internal constant TIMELOCK_DELAY = 1 hours;
    string internal constant OUTPUT_PATH = "./script/output/demo-secundario.json";

    struct Infra {
        MockBRL moeda;
        DenyAllTransferPolicy denyAll;
        RestrictedTransferPolicy restricted;
        ParticipacaoToken tokenImplementacao;
        EmissaoGateway gateway;
        ParticipacaoTokenFactory tokenFactory;
        RegistroInvestidorQualificado registro;
        OfertaCaptacao captacaoImplementacao;
        OfertaCaptacaoFactory captacaoFactory;
        LiquidacaoSecundaria liquidacao;
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
        _proporAgente(infra, deployer);
        vm.stopBroadcast();

        _persistirEnderecos(infra);
        _logResultados(infra, deployer);
    }

    function _deployInfra(address admin, address protocoloWallet) internal returns (Infra memory infra) {
        infra.moeda = new MockBRL();
        infra.denyAll = new DenyAllTransferPolicy();
        infra.restricted = new RestrictedTransferPolicy(admin, TIMELOCK_DELAY);
        infra.tokenImplementacao = new ParticipacaoToken();
        infra.gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        infra.tokenFactory = new ParticipacaoTokenFactory(
            admin, address(infra.tokenImplementacao), address(infra.gateway), address(infra.denyAll), TIMELOCK_DELAY
        );
        infra.registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        infra.captacaoImplementacao = new OfertaCaptacao();
        infra.captacaoFactory = new OfertaCaptacaoFactory(
            admin,
            address(infra.captacaoImplementacao),
            address(infra.gateway),
            address(infra.registro),
            address(infra.moeda),
            TIMELOCK_DELAY
        );
        infra.liquidacao =
            new LiquidacaoSecundaria(admin, address(infra.moeda), address(infra.tokenFactory), protocoloWallet, TIMELOCK_DELAY);
    }

    /// @dev Propõe (não executa) AGENTE_ROLE para `agente` nos seis contratos que o exigem.
    function _proporAgente(Infra memory infra, address agente) internal {
        bytes32 role = keccak256("AGENTE_ROLE");
        address[6] memory alvos = [
            address(infra.gateway),
            address(infra.tokenFactory),
            address(infra.registro),
            address(infra.captacaoFactory),
            address(infra.restricted),
            address(infra.liquidacao)
        ];
        for (uint256 i = 0; i < alvos.length; i++) {
            (bool ok,) = alvos[i].call(abi.encodeWithSignature("proposeGrantRole(bytes32,address)", role, agente));
            require(ok, "proposeGrantRole falhou");
        }
    }

    function _persistirEnderecos(Infra memory infra) internal {
        string memory objKey = "infra";
        vm.serializeAddress(objKey, "moeda", address(infra.moeda));
        vm.serializeAddress(objKey, "denyAll", address(infra.denyAll));
        vm.serializeAddress(objKey, "restricted", address(infra.restricted));
        vm.serializeAddress(objKey, "tokenImplementacao", address(infra.tokenImplementacao));
        vm.serializeAddress(objKey, "gateway", address(infra.gateway));
        vm.serializeAddress(objKey, "tokenFactory", address(infra.tokenFactory));
        vm.serializeAddress(objKey, "registro", address(infra.registro));
        vm.serializeAddress(objKey, "captacaoImplementacao", address(infra.captacaoImplementacao));
        vm.serializeAddress(objKey, "captacaoFactory", address(infra.captacaoFactory));
        string memory finalJson = vm.serializeAddress(objKey, "liquidacao", address(infra.liquidacao));
        vm.writeJson(finalJson, OUTPUT_PATH);
    }

    function _logResultados(Infra memory infra, address deployer) internal view {
        console2.log("");
        console2.log("== Enderecos implantados ==");
        console2.log("MockBRL:", address(infra.moeda));
        console2.log("DenyAllTransferPolicy:", address(infra.denyAll));
        console2.log("RestrictedTransferPolicy:", address(infra.restricted));
        console2.log("ParticipacaoToken (implementacao):", address(infra.tokenImplementacao));
        console2.log("EmissaoGateway:", address(infra.gateway));
        console2.log("ParticipacaoTokenFactory:", address(infra.tokenFactory));
        console2.log("RegistroInvestidorQualificado:", address(infra.registro));
        console2.log("OfertaCaptacao (implementacao):", address(infra.captacaoImplementacao));
        console2.log("OfertaCaptacaoFactory:", address(infra.captacaoFactory));
        console2.log("LiquidacaoSecundaria:", address(infra.liquidacao));
        console2.log("");
        console2.log("AGENTE_ROLE PROPOSTO (nao executado, 6 contratos) para:", deployer);
        console2.log("Enderecos salvos em:", OUTPUT_PATH);
        console2.log("");
        console2.log(">> Espere >= 1 hora de tempo REAL, entao rode DemoSecundarioPreparar.s.sol <<");
    }
}
