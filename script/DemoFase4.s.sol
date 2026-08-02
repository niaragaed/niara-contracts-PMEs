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

/// @title DemoFase4
/// @notice Script de demonstração LOCAL/DRY-RUN da Fase 4: cessão bilateral no mercado
/// secundário, fim-a-fim. Um vendedor detém cotas (mini-ciclo de emissão via gateway); o token
/// migra de `DenyAllTransferPolicy` para `RestrictedTransferPolicy` (mesma sequência da Fase 3);
/// o AGENTE define lock-up + allowlist e a governança abre o secundário (timelock); os dois
/// contra-exemplos são provados (cessão antes do lock-up e para comprador não elegível
/// revertem); só então `LiquidacaoSecundaria.liquidarCessao` troca cotas por `MockBRL`
/// atomicamente, com ambas as partes já tendo pré-aprovado as respectivas allowances — este
/// contrato nunca custodia nada.
/// @dev NUNCA rodar com `--broadcast` contra Sepolia sem instrução explícita do usuário (ver
/// CLAUDE.md). Mesma ressalva de `DeployFase1.s.sol`/`DeployFase2.s.sol`/`DemoFase3.s.sol`
/// sobre `vm.warp`: só "pula" o atraso do timelock e o lock-up em simulação local (sem
/// `--broadcast`) ou contra `anvil` efêmero — contra uma rede real, o tempo precisa decorrer de
/// verdade.
contract DemoFase4 is Script {
    uint256 internal constant TIMELOCK_DELAY = 1 hours;
    uint256 internal constant COTAS_AUTORIZADAS_DEMO = 100_000 ether;
    uint256 internal constant COTAS_VENDEDOR_DEMO = 1_000 ether;
    uint256 internal constant LOCKUP_DEMO_SEGUNDOS = 7 days;
    uint256 internal constant PRECO_POR_COTA_DEMO = 100 ether;
    uint256 internal constant QUANTIDADE_CESSAO_DEMO = 50 ether; // 50 cotas

    struct Config {
        uint256 deployerPrivateKey;
        uint256 vendedorPrivateKey;
        uint256 compradorPrivateKey;
        address admin;
        address agente;
        address protocoloWallet;
        address vendedor;
        address comprador;
        address naoElegivel;
    }

    struct Infra {
        DenyAllTransferPolicy denyAll;
        RestrictedTransferPolicy restricted;
        ParticipacaoToken tokenImplementacao;
        EmissaoGateway gateway;
        ParticipacaoTokenFactory factory;
        MockBRL moeda;
        LiquidacaoSecundaria liquidacao;
        address token;
    }

    function run() external returns (Infra memory infra) {
        Config memory cfg = _readConfig();
        _logConfig(cfg);

        vm.startBroadcast(cfg.deployerPrivateKey);
        infra = _deployInfra(cfg);
        _concederAgente(infra, cfg.agente);
        _criarOfertaEEmitir(infra, cfg);
        vm.stopBroadcast();

        vm.startBroadcast(cfg.deployerPrivateKey);
        _migrarParaRestricted(infra);
        _prepararRestricted(infra, cfg);
        _abrirSecundario(infra);
        vm.stopBroadcast();

        console2.log("");
        console2.log("== Contra-exemplo 1: cessao antes do lock-up (secundario ja liberado) ==");
        _tentarLiquidar(infra, cfg, cfg.comprador, "vendedor -> comprador (cedo demais)");

        vm.warp(block.timestamp + LOCKUP_DEMO_SEGUNDOS + 1);

        console2.log("");
        console2.log("== Contra-exemplo 2: cessao para comprador fora da allowlist ==");
        _tentarLiquidar(infra, cfg, cfg.naoElegivel, "vendedor -> naoElegivel");

        console2.log("");
        console2.log("== Cessao valida: apos o lock-up, comprador elegivel ==");
        _prepararAllowancesEMoeda(infra, cfg);
        _liquidarComSucesso(infra, cfg);

        _logEstadoFinal(infra, cfg);
    }

    // ── Configuração ────────────────────────────────────────────────────────────────────

    function _readConfig() internal view returns (Config memory cfg) {
        cfg.deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(1));
        cfg.vendedorPrivateKey = vm.envOr("VENDEDOR_PRIVATE_KEY", uint256(2));
        cfg.compradorPrivateKey = vm.envOr("COMPRADOR_PRIVATE_KEY", uint256(3));

        address deployer = vm.addr(cfg.deployerPrivateKey);
        cfg.admin = vm.envOr("ADMIN_ADDRESS", deployer);
        cfg.agente = vm.envOr("AGENTE_ADDRESS", deployer);
        cfg.protocoloWallet = vm.envOr("PROTOCOLO_WALLET_ADDRESS", vm.addr(5));
        cfg.vendedor = vm.addr(cfg.vendedorPrivateKey);
        cfg.comprador = vm.addr(cfg.compradorPrivateKey);
        cfg.naoElegivel = vm.envOr("NAO_ELEGIVEL_ADDRESS", vm.addr(6));
    }

    // ── Deploy da infraestrutura ────────────────────────────────────────────────────────

    function _deployInfra(Config memory cfg) internal returns (Infra memory infra) {
        infra.denyAll = new DenyAllTransferPolicy();
        infra.restricted = new RestrictedTransferPolicy(cfg.admin, TIMELOCK_DELAY);
        infra.tokenImplementacao = new ParticipacaoToken();
        infra.gateway = new EmissaoGateway(cfg.admin, TIMELOCK_DELAY);
        infra.factory = new ParticipacaoTokenFactory(
            cfg.admin, address(infra.tokenImplementacao), address(infra.gateway), address(infra.denyAll), TIMELOCK_DELAY
        );
        infra.moeda = new MockBRL();
        infra.liquidacao =
            new LiquidacaoSecundaria(cfg.admin, address(infra.moeda), address(infra.factory), cfg.protocoloWallet, TIMELOCK_DELAY);
    }

    /// @dev Concede AGENTE_ROLE em gateway, factory, restricted e liquidacao, via
    /// propose→warp→execute (mesma ressalva das demos anteriores sobre validade do `vm.warp`).
    function _concederAgente(Infra memory infra, address agente) internal {
        address[4] memory alvos =
            [address(infra.gateway), address(infra.factory), address(infra.restricted), address(infra.liquidacao)];
        bytes32 role = keccak256("AGENTE_ROLE");

        for (uint256 i = 0; i < alvos.length; i++) {
            (bool ok,) = alvos[i].call(abi.encodeWithSignature("proposeGrantRole(bytes32,address)", role, agente));
            require(ok, "propose AGENTE_ROLE falhou");
        }

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        for (uint256 i = 0; i < alvos.length; i++) {
            (bool ok,) = alvos[i].call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, agente));
            require(ok, "execute AGENTE_ROLE falhou");
        }
    }

    // ── Mini-ciclo de emissão (vendedor passa a deter cotas) ───────────────────────────

    function _criarOfertaEEmitir(Infra memory infra, Config memory cfg) internal {
        infra.token = infra.factory.criarOferta(
            "Oferta Demo Fase 4", "nDEMO4", "Empresa Demo Fase 4 Ltda", keccak256("cnpj-demo-fase4"), "2026-A"
        );

        infra.gateway.atestarCotas(infra.token, COTAS_AUTORIZADAS_DEMO);
        infra.gateway.emitir(infra.token, cfg.vendedor, COTAS_VENDEDOR_DEMO);
    }

    // ── Migração de política + abertura do secundário (mesma sequência da Fase 3) ──────

    function _migrarParaRestricted(Infra memory infra) internal {
        infra.gateway.proposeSetTransferPolicy(infra.token, address(infra.restricted));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        infra.gateway.executeSetTransferPolicy(infra.token, address(infra.restricted));
    }

    function _prepararRestricted(Infra memory infra, Config memory cfg) internal {
        uint64 lockupAte = uint64(block.timestamp + LOCKUP_DEMO_SEGUNDOS);
        infra.restricted.definirLockup(infra.token, lockupAte);
        infra.restricted.definirElegivel(infra.token, cfg.comprador, true);
        // cfg.naoElegivel de propósito NÃO entra na allowlist — é o contra-exemplo 2.
    }

    function _abrirSecundario(Infra memory infra) internal {
        infra.restricted.proposeSetSecundarioLiberado(infra.token, true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        infra.restricted.executeSetSecundarioLiberado(infra.token, true);
    }

    // ── Allowances + saldo de MockBRL do comprador ──────────────────────────────────────

    function _prepararAllowancesEMoeda(Infra memory infra, Config memory cfg) internal {
        infra.moeda.mint(cfg.comprador, 1_000_000 ether);

        vm.startBroadcast(cfg.vendedorPrivateKey);
        ParticipacaoToken(infra.token).approve(address(infra.liquidacao), type(uint256).max);
        vm.stopBroadcast();

        vm.startBroadcast(cfg.compradorPrivateKey);
        infra.moeda.approve(address(infra.liquidacao), type(uint256).max);
        vm.stopBroadcast();
    }

    // ── Tentativas de liquidação (contra-exemplos) ──────────────────────────────────────

    function _tentarLiquidar(Infra memory infra, Config memory cfg, address comprador, string memory rotulo) internal {
        vm.startBroadcast(cfg.deployerPrivateKey);
        try infra.liquidacao.liquidarCessao(infra.token, cfg.vendedor, comprador, QUANTIDADE_CESSAO_DEMO, PRECO_POR_COTA_DEMO)
        {
            console2.log(string.concat("[INESPERADO] cessao passou: ", rotulo));
            revert("Fase 4: cessao deveria ter revertido");
        } catch {
            console2.log(string.concat("[OK] cessao revertida como esperado: ", rotulo));
        }
        vm.stopBroadcast();
    }

    function _liquidarComSucesso(Infra memory infra, Config memory cfg) internal {
        vm.startBroadcast(cfg.deployerPrivateKey);
        infra.liquidacao.liquidarCessao(
            infra.token, cfg.vendedor, cfg.comprador, QUANTIDADE_CESSAO_DEMO, PRECO_POR_COTA_DEMO
        );
        vm.stopBroadcast();
        console2.log("[OK] cessao vendedor -> comprador liquidada");
    }

    // ── Logs ────────────────────────────────────────────────────────────────────────────

    function _logConfig(Config memory cfg) internal pure {
        console2.log("== Configuracao ==");
        console2.log("Admin:", cfg.admin);
        console2.log("Agente:", cfg.agente);
        console2.log("Protocolo wallet:", cfg.protocoloWallet);
        console2.log("Vendedor:", cfg.vendedor);
        console2.log("Comprador (elegivel):", cfg.comprador);
        console2.log("Nao elegivel (contra-exemplo):", cfg.naoElegivel);
        console2.log("Timelock delay (segundos):", TIMELOCK_DELAY);
        console2.log("Lock-up (segundos):", LOCKUP_DEMO_SEGUNDOS);
    }

    function _logEstadoFinal(Infra memory infra, Config memory cfg) internal view {
        console2.log("");
        console2.log("== Enderecos implantados ==");
        console2.log("RestrictedTransferPolicy:", address(infra.restricted));
        console2.log("EmissaoGateway:", address(infra.gateway));
        console2.log("ParticipacaoTokenFactory:", address(infra.factory));
        console2.log("LiquidacaoSecundaria:", address(infra.liquidacao));
        console2.log("Token (oferta demo):", infra.token);

        console2.log("");
        console2.log("== Saldos finais (apos a cessao) ==");
        console2.log("Cotas do vendedor:", ParticipacaoToken(infra.token).balanceOf(cfg.vendedor));
        console2.log("Cotas do comprador:", ParticipacaoToken(infra.token).balanceOf(cfg.comprador));
        console2.log("MockBRL do vendedor (recebeu o valor, taxa=0):", infra.moeda.balanceOf(cfg.vendedor));
        console2.log("MockBRL do comprador (pagou o valor):", infra.moeda.balanceOf(cfg.comprador));
        console2.log("MockBRL do protocolo (taxa=0 nesta fase):", infra.moeda.balanceOf(cfg.protocoloWallet));
        console2.log("taxaSecundarioBps vigente:", infra.liquidacao.taxaSecundarioBps());
    }
}
