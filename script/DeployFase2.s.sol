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

/// @title DeployFase2
/// @notice Script de demonstração LOCAL/DRY-RUN da Fase 2. Implanta toda a infraestrutura
/// (Fase 1 + Fase 2), concede `AGENTE_ROLE` nos quatro contratos que o exigem, e roda os DOIS
/// cenários do escrow de captação: (A) sucesso parcial — dois investidores aportam entre a
/// meta mínima e a máxima, a captação encerra em sucesso, um investidor resgata cotas e os
/// recursos são liberados ao emissor; (B) fracasso — aporte fica abaixo da meta mínima, a
/// captação encerra em fracasso, e os investidores reembolsam.
/// @dev NUNCA rodar com `--broadcast` contra Sepolia sem instrução explícita do usuário (ver
/// CLAUDE.md). Mesma ressalva de `DeployFase1.s.sol` sobre `vm.warp`: só "pula" o atraso do
/// timelock e o prazo da captação em simulação local (sem `--broadcast`) ou contra `anvil`
/// efêmero — contra uma rede real, o tempo precisa decorrer de verdade.
contract DeployFase2 is Script {
    uint256 internal constant TIMELOCK_DELAY = 1 hours;

    uint256 internal constant META_MINIMA_DEMO = 10_000 ether;
    uint256 internal constant META_MAXIMA_DEMO = 50_000 ether;
    uint256 internal constant PRECO_POR_COTA_DEMO = 100 ether;
    uint256 internal constant TETO_POR_INVESTIDOR_DEMO = 30_000 ether;
    uint256 internal constant TAXA_BPS_DEMO = 50;
    uint256 internal constant PRAZO_DEMO_SEGUNDOS = 7 days;

    uint256 internal constant APORTE_SUCESSO_INVESTIDOR1 = 6_000 ether;
    uint256 internal constant APORTE_SUCESSO_INVESTIDOR2 = 5_000 ether;
    uint256 internal constant APORTE_FALHA_INVESTIDOR1 = 2_000 ether;
    uint256 internal constant APORTE_FALHA_INVESTIDOR2 = 1_000 ether;

    struct Config {
        uint256 deployerPrivateKey;
        uint256 investidor1PrivateKey;
        uint256 investidor2PrivateKey;
        address admin;
        address agente;
        address investidor1;
        address investidor2;
        address emissorWallet;
        address protocoloWallet;
    }

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

    struct Cenario {
        address token;
        address oferta;
    }

    function run() external returns (Infra memory infra, Cenario memory sucesso, Cenario memory falha) {
        Config memory cfg = _readConfig();
        _logConfig(cfg);

        vm.startBroadcast(cfg.deployerPrivateKey);
        infra = _deployInfra(cfg);
        _concederAgente(infra, cfg.agente);
        _mintParaInvestidores(infra, cfg);
        vm.stopBroadcast();

        sucesso = _cenarioSucessoParcial(infra, cfg);
        falha = _cenarioFracasso(infra, cfg);

        _logResultados(infra, sucesso, falha, cfg);
    }

    // ── Configuração ────────────────────────────────────────────────────────────────────

    function _readConfig() internal view returns (Config memory cfg) {
        cfg.deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(1));
        cfg.investidor1PrivateKey = vm.envOr("INVESTIDOR1_PRIVATE_KEY", uint256(2));
        cfg.investidor2PrivateKey = vm.envOr("INVESTIDOR2_PRIVATE_KEY", uint256(3));

        address deployer = vm.addr(cfg.deployerPrivateKey);
        cfg.admin = vm.envOr("ADMIN_ADDRESS", deployer);
        cfg.agente = vm.envOr("AGENTE_ADDRESS", deployer);
        cfg.investidor1 = vm.addr(cfg.investidor1PrivateKey);
        cfg.investidor2 = vm.addr(cfg.investidor2PrivateKey);
        cfg.emissorWallet = vm.envOr("EMISSOR_WALLET_ADDRESS", vm.addr(4));
        cfg.protocoloWallet = vm.envOr("PROTOCOLO_WALLET_ADDRESS", vm.addr(5));
    }

    // ── Deploy da infraestrutura (Fase 1 + Fase 2) ──────────────────────────────────────

    function _deployInfra(Config memory cfg) internal returns (Infra memory infra) {
        infra.moeda = new MockBRL();
        infra.policy = new DenyAllTransferPolicy();
        infra.tokenImplementacao = new ParticipacaoToken();
        infra.gateway = new EmissaoGateway(cfg.admin, TIMELOCK_DELAY);
        infra.tokenFactory = new ParticipacaoTokenFactory(
            cfg.admin, address(infra.tokenImplementacao), address(infra.gateway), address(infra.policy), TIMELOCK_DELAY
        );
        infra.registro = new RegistroInvestidorQualificado(cfg.admin, TIMELOCK_DELAY);
        infra.captacaoImplementacao = new OfertaCaptacao();
        infra.captacaoFactory = new OfertaCaptacaoFactory(
            cfg.admin,
            address(infra.captacaoImplementacao),
            address(infra.gateway),
            address(infra.registro),
            address(infra.moeda),
            TIMELOCK_DELAY
        );
    }

    /// @dev Concede AGENTE_ROLE nos quatro contratos que o exigem, via propose→warp→execute
    /// (ver ressalva no NatSpec do contrato sobre validade do `vm.warp`).
    function _concederAgente(Infra memory infra, address agente) internal {
        address[4] memory alvos = [
            address(infra.gateway),
            address(infra.tokenFactory),
            address(infra.registro),
            address(infra.captacaoFactory)
        ];

        for (uint256 i = 0; i < alvos.length; i++) {
            bytes32 role = keccak256("AGENTE_ROLE");
            (bool ok1,) = alvos[i].call(abi.encodeWithSignature("proposeGrantRole(bytes32,address)", role, agente));
            require(ok1, "propose falhou");
        }

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        for (uint256 i = 0; i < alvos.length; i++) {
            bytes32 role = keccak256("AGENTE_ROLE");
            (bool ok2,) = alvos[i].call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, agente));
            require(ok2, "execute falhou");
        }
    }

    function _mintParaInvestidores(Infra memory infra, Config memory cfg) internal {
        uint256 saldoInicial = 1_000_000 ether;
        infra.moeda.mint(cfg.investidor1, saldoInicial);
        infra.moeda.mint(cfg.investidor2, saldoInicial);
    }

    // ── Sequência operacional: criarOferta → atestarCotas → criarCaptacao → registrarCaptacao ──

    function _criarTokenECaptacao(Infra memory infra, Config memory cfg, string memory serie)
        internal
        returns (Cenario memory cenario)
    {
        vm.startBroadcast(cfg.deployerPrivateKey);
        cenario.token = infra.tokenFactory.criarOferta(
            string(abi.encodePacked("Oferta ", serie)),
            "nCAP",
            "Empresa Captacao Demo Ltda",
            keccak256(abi.encode("cnpj-demo", serie)),
            serie
        );
        infra.gateway.atestarCotas(cenario.token, (META_MAXIMA_DEMO / PRECO_POR_COTA_DEMO) * 1 ether);

        cenario.oferta = infra.captacaoFactory.criarCaptacao(
            cenario.token,
            META_MINIMA_DEMO,
            META_MAXIMA_DEMO,
            PRECO_POR_COTA_DEMO,
            block.timestamp + PRAZO_DEMO_SEGUNDOS,
            TETO_POR_INVESTIDOR_DEMO,
            TAXA_BPS_DEMO,
            cfg.emissorWallet,
            cfg.protocoloWallet
        );
        infra.gateway.registrarCaptacao(cenario.token, cenario.oferta);
        vm.stopBroadcast();
    }

    function _aportar(uint256 investidorPrivateKey, address oferta, uint256 valor) internal {
        vm.startBroadcast(investidorPrivateKey);
        MockBRL(address(OfertaCaptacao(oferta).moeda())).approve(oferta, valor);
        OfertaCaptacao(oferta).aportar(valor);
        vm.stopBroadcast();
    }

    // ── Cenário A: sucesso parcial ──────────────────────────────────────────────────────

    function _cenarioSucessoParcial(Infra memory infra, Config memory cfg) internal returns (Cenario memory cenario) {
        cenario = _criarTokenECaptacao(infra, cfg, "2026-A-SUCESSO");

        _aportar(cfg.investidor1PrivateKey, cenario.oferta, APORTE_SUCESSO_INVESTIDOR1);
        _aportar(cfg.investidor2PrivateKey, cenario.oferta, APORTE_SUCESSO_INVESTIDOR2);

        vm.warp(block.timestamp + PRAZO_DEMO_SEGUNDOS);

        vm.startBroadcast(cfg.deployerPrivateKey);
        OfertaCaptacao(cenario.oferta).encerrar();
        vm.stopBroadcast();

        vm.startBroadcast(cfg.investidor1PrivateKey);
        OfertaCaptacao(cenario.oferta).resgatarCotas();
        vm.stopBroadcast();

        vm.startBroadcast(cfg.deployerPrivateKey);
        OfertaCaptacao(cenario.oferta).liberarParaEmissor();
        vm.stopBroadcast();
    }

    // ── Cenário B: fracasso / reembolso ─────────────────────────────────────────────────

    function _cenarioFracasso(Infra memory infra, Config memory cfg) internal returns (Cenario memory cenario) {
        cenario = _criarTokenECaptacao(infra, cfg, "2026-B-FALHA");

        _aportar(cfg.investidor1PrivateKey, cenario.oferta, APORTE_FALHA_INVESTIDOR1);
        _aportar(cfg.investidor2PrivateKey, cenario.oferta, APORTE_FALHA_INVESTIDOR2);

        vm.warp(block.timestamp + PRAZO_DEMO_SEGUNDOS);

        vm.startBroadcast(cfg.deployerPrivateKey);
        OfertaCaptacao(cenario.oferta).encerrar();
        vm.stopBroadcast();

        vm.startBroadcast(cfg.investidor1PrivateKey);
        OfertaCaptacao(cenario.oferta).reembolsar();
        vm.stopBroadcast();

        vm.startBroadcast(cfg.investidor2PrivateKey);
        OfertaCaptacao(cenario.oferta).reembolsar();
        vm.stopBroadcast();
    }

    // ── Logs ────────────────────────────────────────────────────────────────────────────

    function _logConfig(Config memory cfg) internal pure {
        console2.log("== Configuracao ==");
        console2.log("Admin:", cfg.admin);
        console2.log("Agente:", cfg.agente);
        console2.log("Investidor 1:", cfg.investidor1);
        console2.log("Investidor 2:", cfg.investidor2);
        console2.log("Emissor wallet:", cfg.emissorWallet);
        console2.log("Protocolo wallet:", cfg.protocoloWallet);
        console2.log("Timelock delay (segundos):", TIMELOCK_DELAY);
    }

    function _logResultados(Infra memory infra, Cenario memory sucesso, Cenario memory falha, Config memory cfg)
        internal
        view
    {
        console2.log("");
        console2.log("== Enderecos implantados (infraestrutura) ==");
        console2.log("MockBRL:", address(infra.moeda));
        console2.log("EmissaoGateway:", address(infra.gateway));
        console2.log("ParticipacaoTokenFactory:", address(infra.tokenFactory));
        console2.log("RegistroInvestidorQualificado:", address(infra.registro));
        console2.log("OfertaCaptacaoFactory:", address(infra.captacaoFactory));

        console2.log("");
        console2.log("== Cenario A: sucesso parcial ==");
        console2.log("Token:", sucesso.token);
        console2.log("Oferta (escrow):", sucesso.oferta);
        console2.log("Estado final (1 = EncerradaSucesso):", uint256(OfertaCaptacao(sucesso.oferta).estado()));
        console2.log("Total arrecadado:", OfertaCaptacao(sucesso.oferta).totalArrecadado());
        console2.log("Cotas do investidor 1 (resgatou):", ParticipacaoToken(sucesso.token).balanceOf(cfg.investidor1));
        console2.log("MockBRL no emissor apos liberacao:", infra.moeda.balanceOf(cfg.emissorWallet));
        console2.log("MockBRL no protocolo apos liberacao (taxa):", infra.moeda.balanceOf(cfg.protocoloWallet));
        console2.log("MockBRL restante no escrow (deve ser 0):", infra.moeda.balanceOf(sucesso.oferta));

        console2.log("");
        console2.log("== Cenario B: fracasso / reembolso ==");
        console2.log("Token:", falha.token);
        console2.log("Oferta (escrow):", falha.oferta);
        console2.log("Estado final (2 = EncerradaFalha):", uint256(OfertaCaptacao(falha.oferta).estado()));
        console2.log("Total arrecadado (abaixo da meta minima):", OfertaCaptacao(falha.oferta).totalArrecadado());
        console2.log("MockBRL devolvido ao investidor 1:", infra.moeda.balanceOf(cfg.investidor1));
        console2.log("MockBRL devolvido ao investidor 2:", infra.moeda.balanceOf(cfg.investidor2));
        console2.log("MockBRL restante no escrow (deve ser 0):", infra.moeda.balanceOf(falha.oferta));
    }
}
