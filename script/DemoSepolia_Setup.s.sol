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
/// @notice Parte 1/2 da demo pública da Fase 2 em Sepolia (ver CLAUDE.md — "Regras
/// inegociáveis" e instrução de demo). Implanta toda a infraestrutura e PROPÕE (mas não
/// executa) a concessão de `AGENTE_ROLE` à própria deployer nos quatro contratos que o
/// exigem.
/// @dev `AGENTE_ROLE` é concedido via timelock (`MIN_TIMELOCK_DELAY = 1 hours`, ver
/// `TimelockedAccessControl.sol`) — em rede real isso exige que 1h de tempo REAL decorra
/// entre propose e execute (`vm.warp` só "engana" o relógio em simulação local, nunca contra
/// uma chain de verdade recebendo transações reais — mesma ressalva já documentada para
/// `DeployFase1.s.sol`/`DeployFase2.s.sol`). Por isso a demo em Sepolia é dividida em dois
/// scripts: este propõe, `DemoSepolia.s.sol` executa (depois de esperar a 1h) e roda o resto
/// do ciclo. Os endereços implantados são persistidos em `./script/output/demo-sepolia.json`
/// para o segundo script reconstituir o mesmo estado.
contract DemoSepolia_Setup is Script {
    uint256 internal constant TIMELOCK_DELAY = 1 hours;
    string internal constant OUTPUT_PATH = "./script/output/demo-sepolia.json";

    struct Infra {
        MockBRL moeda;
        DenyAllTransferPolicy policy;
        ParticipacaoToken tokenImplementacao;
        EmissaoGateway gateway;
        ParticipacaoTokenFactory tokenFactory;
        RegistroInvestidorQualificado registro;
        OfertaCaptacao captacaoImplementacao;
        OfertaCaptacaoFactory captacaoFactory;
    }

    function run() external returns (Infra memory infra) {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        console2.log("== DemoSepolia_Setup ==");
        console2.log("Deployer/admin/agente:", deployer);
        console2.log("Timelock delay (segundos):", TIMELOCK_DELAY);

        vm.startBroadcast(deployerPk);
        infra = _deployInfra(deployer);
        _proporAgente(infra, deployer);
        vm.stopBroadcast();

        _persistirEnderecos(infra);
        _logResultados(infra, deployer);
    }

    function _deployInfra(address admin) internal returns (Infra memory infra) {
        infra.moeda = new MockBRL();
        infra.policy = new DenyAllTransferPolicy();
        infra.tokenImplementacao = new ParticipacaoToken();
        infra.gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        infra.tokenFactory = new ParticipacaoTokenFactory(
            admin, address(infra.tokenImplementacao), address(infra.gateway), address(infra.policy), TIMELOCK_DELAY
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
    }

    /// @dev Propõe (não executa) AGENTE_ROLE para `agente` nos quatro contratos que o exigem.
    function _proporAgente(Infra memory infra, address agente) internal {
        bytes32 role = keccak256("AGENTE_ROLE");
        address[4] memory alvos = [
            address(infra.gateway),
            address(infra.tokenFactory),
            address(infra.registro),
            address(infra.captacaoFactory)
        ];
        for (uint256 i = 0; i < alvos.length; i++) {
            (bool ok,) = alvos[i].call(abi.encodeWithSignature("proposeGrantRole(bytes32,address)", role, agente));
            require(ok, "proposeGrantRole falhou");
        }
    }

    function _persistirEnderecos(Infra memory infra) internal {
        string memory objKey = "infra";
        vm.serializeAddress(objKey, "moeda", address(infra.moeda));
        vm.serializeAddress(objKey, "policy", address(infra.policy));
        vm.serializeAddress(objKey, "tokenImplementacao", address(infra.tokenImplementacao));
        vm.serializeAddress(objKey, "gateway", address(infra.gateway));
        vm.serializeAddress(objKey, "tokenFactory", address(infra.tokenFactory));
        vm.serializeAddress(objKey, "registro", address(infra.registro));
        vm.serializeAddress(objKey, "captacaoImplementacao", address(infra.captacaoImplementacao));
        string memory finalJson = vm.serializeAddress(objKey, "captacaoFactory", address(infra.captacaoFactory));
        vm.writeJson(finalJson, OUTPUT_PATH);
    }

    function _logResultados(Infra memory infra, address deployer) internal view {
        console2.log("");
        console2.log("== Enderecos implantados ==");
        console2.log("MockBRL:", address(infra.moeda));
        console2.log("DenyAllTransferPolicy:", address(infra.policy));
        console2.log("ParticipacaoToken (implementacao):", address(infra.tokenImplementacao));
        console2.log("EmissaoGateway:", address(infra.gateway));
        console2.log("ParticipacaoTokenFactory:", address(infra.tokenFactory));
        console2.log("RegistroInvestidorQualificado:", address(infra.registro));
        console2.log("OfertaCaptacao (implementacao):", address(infra.captacaoImplementacao));
        console2.log("OfertaCaptacaoFactory:", address(infra.captacaoFactory));
        console2.log("");
        console2.log("AGENTE_ROLE PROPOSTO (nao executado) para:", deployer);
        console2.log("Enderecos salvos em:", OUTPUT_PATH);
        console2.log("");
        console2.log(">> Espere >= 1 hora de tempo REAL, entao rode DemoSepolia.s.sol <<");
    }
}
