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

/// @title DemoSecundarioPreparar
/// @notice Parte 2/3 da demo pública do secundário em Sepolia — rodar só depois de
/// `DemoSecundarioSetup.s.sol` e de >= 1h de tempo REAL terem decorrido. Executa o
/// `AGENTE_ROLE` proposto, coloca cotas na mão do vendedor pelo caminho mais direto
/// (`EmissaoGateway.emitir`, sem escrow), configura a `RestrictedTransferPolicy` para esse
/// token (elegibilidade + lock-up, operacional, sem timelock) e PROPÕE (não executa) a
/// migração de política do token + abertura do secundário.
/// @dev O lock-up é real e curto (10 minutos) — expira dentro da próxima espera de 1h, então
/// `DemoSecundario.s.sol` já encontra a cessão liberável quando executar. `vm.warp` não afeta
/// Sepolia (mesma ressalva de `DemoSecundarioSetup.s.sol`).
contract DemoSecundarioPreparar is Script {
    string internal constant OUTPUT_PATH = "./script/output/demo-secundario.json";
    uint256 internal constant TIMELOCK_DELAY = 1 hours;
    uint256 internal constant LOCKUP_DURACAO = 10 minutes;

    uint256 internal constant COTAS_AUTORIZADAS = 1_000_000 ether;
    uint256 internal constant COTAS_VENDEDOR = 50 ether; // 50 cotas, precoPorCota = 100 MockBRL

    struct Config {
        uint256 deployerPk;
        address deployer;
        address vendedor;
        address comprador;
    }

    struct Infra {
        MockBRL moeda;
        RestrictedTransferPolicy restricted;
        EmissaoGateway gateway;
        ParticipacaoTokenFactory tokenFactory;
        RegistroInvestidorQualificado registro;
        OfertaCaptacaoFactory captacaoFactory;
        LiquidacaoSecundaria liquidacao;
    }

    function run() external returns (address token) {
        Config memory cfg = _readConfig();
        Infra memory infra = _lerEnderecos();

        console2.log("== DemoSecundarioPreparar ==");
        console2.log("Vendedor:", cfg.vendedor);
        console2.log("Comprador:", cfg.comprador);

        vm.startBroadcast(cfg.deployerPk);
        _executarAgente(infra, cfg.deployer);
        token = _criarOfertaEEmitir(infra, cfg);
        _configurarPolitica(infra, token, cfg);
        uint256 executeAfterPolitica = _proporMigracaoEAbertura(infra, token);
        vm.stopBroadcast();

        vm.writeJson(vm.toString(token), OUTPUT_PATH, ".token");

        _logResultados(token, executeAfterPolitica);
    }

    // ── Configuração ────────────────────────────────────────────────────────────────────

    function _readConfig() internal view returns (Config memory cfg) {
        cfg.deployerPk = vm.envUint("PRIVATE_KEY");
        cfg.deployer = vm.addr(cfg.deployerPk);
        cfg.vendedor = vm.addr(vm.envUint("INVESTIDOR1_PRIVATE_KEY"));
        cfg.comprador = vm.addr(vm.envUint("INVESTIDOR2_PRIVATE_KEY"));
    }

    function _lerEnderecos() internal returns (Infra memory infra) {
        string memory json = vm.readFile(OUTPUT_PATH);
        infra.moeda = MockBRL(vm.parseJsonAddress(json, ".moeda"));
        infra.restricted = RestrictedTransferPolicy(vm.parseJsonAddress(json, ".restricted"));
        infra.gateway = EmissaoGateway(vm.parseJsonAddress(json, ".gateway"));
        infra.tokenFactory = ParticipacaoTokenFactory(vm.parseJsonAddress(json, ".tokenFactory"));
        infra.registro = RegistroInvestidorQualificado(vm.parseJsonAddress(json, ".registro"));
        infra.captacaoFactory = OfertaCaptacaoFactory(vm.parseJsonAddress(json, ".captacaoFactory"));
        infra.liquidacao = LiquidacaoSecundaria(vm.parseJsonAddress(json, ".liquidacao"));
    }

    // ── Execução do AGENTE_ROLE proposto em DemoSecundarioSetup ────────────────────────

    function _executarAgente(Infra memory infra, address agente) internal {
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
            (bool ok,) = alvos[i].call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, agente));
            require(ok, "executeGrantRole falhou (timelock ainda nao decorrido?)");
        }
    }

    // ── Oferta + emissao direta ao vendedor (caminho mais direto, sem escrow) ──────────

    function _criarOfertaEEmitir(Infra memory infra, Config memory cfg) internal returns (address token) {
        token = infra.tokenFactory.criarOferta(
            "Oferta Demo Secundario",
            "nSEC",
            "Empresa Secundario Demo Ltda",
            keccak256(abi.encode("cnpj-demo-secundario", block.timestamp)),
            "2026-DEMO-SECUNDARIO"
        );
        infra.gateway.atestarCotas(token, COTAS_AUTORIZADAS);
        infra.gateway.emitir(token, cfg.vendedor, COTAS_VENDEDOR);
    }

    // ── RestrictedTransferPolicy: elegibilidade + lock-up (operacional) ────────────────

    function _configurarPolitica(Infra memory infra, address token, Config memory cfg) internal {
        infra.restricted.definirElegivel(token, cfg.vendedor, true);
        infra.restricted.definirElegivel(token, cfg.comprador, true);
        infra.restricted.definirLockup(token, uint64(block.timestamp + LOCKUP_DURACAO));
    }

    // ── Propõe (não executa) a migração de política + abertura do secundário ──────────

    function _proporMigracaoEAbertura(Infra memory infra, address token) internal returns (uint256 executeAfter) {
        infra.gateway.proposeSetTransferPolicy(token, address(infra.restricted));
        executeAfter = infra.restricted.proposeSetSecundarioLiberado(token, true);
    }

    // ── Logs ────────────────────────────────────────────────────────────────────────────

    function _logResultados(address token, uint256 executeAfterPolitica) internal view {
        console2.log("");
        console2.log("Token (oferta demo):", token);
        console2.log("Vendedor recebeu (deve ser 50 ether = 50 cotas)");
        console2.log("Lock-up expira em (timestamp):", block.timestamp + LOCKUP_DURACAO);
        console2.log("Migracao de politica + abertura PROPOSTAS, executeAfter:", executeAfterPolitica);
        console2.log("Token atualizado em:", OUTPUT_PATH);
        console2.log("");
        console2.log(">> Espere >= 1 hora de tempo REAL (o lock-up de 10 min ja tera expirado), entao rode DemoSecundario.s.sol <<");
    }
}
