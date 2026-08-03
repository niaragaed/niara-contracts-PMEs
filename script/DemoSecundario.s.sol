// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {LiquidacaoSecundaria} from "../src/secundario/LiquidacaoSecundaria.sol";

/// @title DemoSecundario
/// @notice Parte 3/3 (o clímax) da demo pública do secundário em Sepolia — rodar só depois de
/// `DemoSecundarioPreparar.s.sol` e de >= 1h de tempo REAL terem decorrido (o lock-up de 10min
/// já terá expirado dentro dessa janela). Executa a migração de política do token +  abertura
/// do secundário propostas na parte 2, financia o comprador em `MockBRL`, colhe as duas
/// allowances (vendedor→cotas, comprador→MockBRL) e fecha a cessão via
/// `LiquidacaoSecundaria.liquidarCessao` — a troca atômica.
/// @dev Antes de rodar este script, opcionalmente rode via `cast send` uma tentativa de
/// `ParticipacaoToken.transfer` do vendedor para o comprador (deve reverter, prova pública de
/// que a restrição é real antes de abrir o secundário) — não está embutido aqui de propósito,
/// é um artefato point-in-time que faz mais sentido como comando avulso documentado no registro
/// da demo, não como parte do fluxo programático.
contract DemoSecundario is Script {
    string internal constant OUTPUT_PATH = "./script/output/demo-secundario.json";

    uint256 internal constant PRECO_POR_COTA = 100 ether;
    uint256 internal constant QUANTIDADE_CESSAO = 20 ether; // 20 cotas
    uint256 internal constant VALOR_CESSAO = 2_000 ether; // 20 * 100

    struct Config {
        uint256 deployerPk;
        uint256 vendedorPk;
        uint256 compradorPk;
        address deployer;
        address vendedor;
        address comprador;
        address protocoloWallet;
    }

    struct Infra {
        MockBRL moeda;
        RestrictedTransferPolicy restricted;
        EmissaoGateway gateway;
        LiquidacaoSecundaria liquidacao;
        ParticipacaoToken token;
    }

    function run() external {
        Config memory cfg = _readConfig();
        Infra memory infra = _lerEnderecos();

        console2.log("== DemoSecundario (climax) ==");
        console2.log("Token:", address(infra.token));
        console2.log("Vendedor:", cfg.vendedor);
        console2.log("Comprador:", cfg.comprador);

        vm.startBroadcast(cfg.deployerPk);
        _abrirSecundario(infra);
        infra.moeda.mint(cfg.comprador, VALOR_CESSAO);
        vm.stopBroadcast();

        vm.startBroadcast(cfg.compradorPk);
        infra.moeda.approve(address(infra.liquidacao), VALOR_CESSAO);
        vm.stopBroadcast();

        vm.startBroadcast(cfg.vendedorPk);
        infra.token.approve(address(infra.liquidacao), QUANTIDADE_CESSAO);
        vm.stopBroadcast();

        vm.startBroadcast(cfg.deployerPk);
        uint256 taxaCobrada =
            infra.liquidacao.liquidarCessao(address(infra.token), cfg.vendedor, cfg.comprador, QUANTIDADE_CESSAO, PRECO_POR_COTA);
        vm.stopBroadcast();

        _logResultados(infra, cfg, taxaCobrada);
    }

    // ── Configuração ────────────────────────────────────────────────────────────────────

    function _readConfig() internal view returns (Config memory cfg) {
        cfg.deployerPk = vm.envUint("PRIVATE_KEY");
        cfg.vendedorPk = vm.envUint("INVESTIDOR1_PRIVATE_KEY");
        cfg.compradorPk = vm.envUint("INVESTIDOR2_PRIVATE_KEY");
        cfg.deployer = vm.addr(cfg.deployerPk);
        cfg.vendedor = vm.addr(cfg.vendedorPk);
        cfg.comprador = vm.addr(cfg.compradorPk);
        cfg.protocoloWallet = vm.envAddress("PROTOCOLO_WALLET_ADDRESS");
    }

    function _lerEnderecos() internal returns (Infra memory infra) {
        string memory json = vm.readFile(OUTPUT_PATH);
        infra.moeda = MockBRL(vm.parseJsonAddress(json, ".moeda"));
        infra.restricted = RestrictedTransferPolicy(vm.parseJsonAddress(json, ".restricted"));
        infra.gateway = EmissaoGateway(vm.parseJsonAddress(json, ".gateway"));
        infra.liquidacao = LiquidacaoSecundaria(vm.parseJsonAddress(json, ".liquidacao"));
        infra.token = ParticipacaoToken(vm.parseJsonAddress(json, ".token"));
    }

    // ── Execução da migração de política + abertura propostas em DemoSecundarioPreparar ──

    function _abrirSecundario(Infra memory infra) internal {
        infra.gateway.executeSetTransferPolicy(address(infra.token), address(infra.restricted));
        infra.restricted.executeSetSecundarioLiberado(address(infra.token), true);
    }

    // ── Logs (ver também a leitura independente via `cast call` no registro da demo) ────

    function _logResultados(Infra memory infra, Config memory cfg, uint256 taxaCobrada) internal view {
        console2.log("");
        console2.log("== Cessao liquidada ==");
        console2.log("Taxa cobrada (deve ser 0, taxa dormente):", taxaCobrada);
        console2.log("");
        console2.log("Cotas do vendedor (deve ser 30 ether = 30 cotas):", infra.token.balanceOf(cfg.vendedor));
        console2.log("Cotas do comprador (deve ser 20 ether = 20 cotas):", infra.token.balanceOf(cfg.comprador));
        console2.log("MockBRL do vendedor (deve ser 2000 ether, taxa 0):", infra.moeda.balanceOf(cfg.vendedor));
        console2.log("MockBRL do comprador (deve ser 0, pagou tudo):", infra.moeda.balanceOf(cfg.comprador));
        console2.log("MockBRL do protocolo (deve ser 0, taxa dormente):", infra.moeda.balanceOf(cfg.protocoloWallet));
    }
}
