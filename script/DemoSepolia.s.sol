// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {OfertaCaptacao} from "../src/captacao/OfertaCaptacao.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";

/// @title DemoSepolia
/// @notice Parte 2/2 da demo pública da Fase 2 em Sepolia — rodar só depois de
/// `DemoSepolia_Setup.s.sol` e de >= 1h de tempo REAL terem decorrido (ver NatSpec daquele
/// script sobre por que o timelock não pode ser pulado em rede real). Lê os endereços
/// implantados em `./script/output/demo-sepolia.json`, executa a concessão de `AGENTE_ROLE`
/// pendente, e roda o ciclo completo de uma captação com subscrição cheia: cria oferta,
/// atesta cotas, cria a captação, registra no gateway, os dois investidores aportam até a
/// meta máxima (fechamento antecipado, sem esperar o prazo), encerra, os dois resgatam
/// cotas e os recursos são liberados ao emissor.
/// @dev Parâmetros da oferta de demo fixados nesta constante — ver instrução de demo
/// (Sepolia): precoPorCota=100 mBRL, metaMinima=3000 mBRL, metaMaxima=5000 mBRL,
/// tetoPorInvestidor=20000 mBRL, taxaBps=0, aportes 3000+2000=5000=metaMaxima (50 cotas).
contract DemoSepolia is Script {
    string internal constant OUTPUT_PATH = "./script/output/demo-sepolia.json";

    uint256 internal constant META_MINIMA = 3_000 ether;
    uint256 internal constant META_MAXIMA = 5_000 ether;
    uint256 internal constant PRECO_POR_COTA = 100 ether;
    uint256 internal constant TETO_POR_INVESTIDOR = 20_000 ether;
    uint256 internal constant TAXA_BPS = 0;
    uint256 internal constant PRAZO_SEGUNDOS = 1 days;

    uint256 internal constant APORTE_INVESTIDOR1 = 3_000 ether;
    uint256 internal constant APORTE_INVESTIDOR2 = 2_000 ether;

    uint256 internal constant SALDO_ETH_MINIMO_INVESTIDOR = 0.01 ether;
    uint256 internal constant TOP_UP_ETH_INVESTIDOR = 0.02 ether;

    struct Config {
        uint256 deployerPk;
        uint256 investidor1Pk;
        uint256 investidor2Pk;
        address deployer;
        address investidor1;
        address investidor2;
        address emissorWallet;
        address protocoloWallet;
    }

    struct Infra {
        MockBRL moeda;
        EmissaoGateway gateway;
        ParticipacaoTokenFactory tokenFactory;
        OfertaCaptacaoFactory captacaoFactory;
    }

    function run() external {
        Config memory cfg = _readConfig();
        Infra memory infra = _lerEnderecos();

        vm.startBroadcast(cfg.deployerPk);
        _executarAgente(infra, cfg.deployer);
        vm.stopBroadcast();

        vm.startBroadcast(cfg.deployerPk);
        (address token, address oferta) = _criarOfertaECaptacao(infra, cfg);
        infra.moeda.mint(cfg.investidor1, APORTE_INVESTIDOR1);
        infra.moeda.mint(cfg.investidor2, APORTE_INVESTIDOR2);
        _topUpEthSeNecessario(cfg.investidor1);
        _topUpEthSeNecessario(cfg.investidor2);
        vm.stopBroadcast();

        _aportar(cfg.investidor1Pk, infra.moeda, oferta, APORTE_INVESTIDOR1);
        _aportar(cfg.investidor2Pk, infra.moeda, oferta, APORTE_INVESTIDOR2);

        vm.startBroadcast(cfg.deployerPk);
        OfertaCaptacao(oferta).encerrar();
        vm.stopBroadcast();

        vm.startBroadcast(cfg.investidor1Pk);
        OfertaCaptacao(oferta).resgatarCotas();
        vm.stopBroadcast();

        vm.startBroadcast(cfg.investidor2Pk);
        OfertaCaptacao(oferta).resgatarCotas();
        vm.stopBroadcast();

        vm.startBroadcast(cfg.deployerPk);
        OfertaCaptacao(oferta).liberarParaEmissor();
        vm.stopBroadcast();

        _logResultados(infra, cfg, token, oferta);
    }

    // ── Configuração ────────────────────────────────────────────────────────────────────

    function _readConfig() internal view returns (Config memory cfg) {
        cfg.deployerPk = vm.envUint("PRIVATE_KEY");
        cfg.investidor1Pk = vm.envUint("INVESTIDOR1_PRIVATE_KEY");
        cfg.investidor2Pk = vm.envUint("INVESTIDOR2_PRIVATE_KEY");
        cfg.deployer = vm.addr(cfg.deployerPk);
        cfg.investidor1 = vm.addr(cfg.investidor1Pk);
        cfg.investidor2 = vm.addr(cfg.investidor2Pk);
        cfg.emissorWallet = vm.envAddress("EMISSOR_WALLET_ADDRESS");
        cfg.protocoloWallet = vm.envAddress("PROTOCOLO_WALLET_ADDRESS");
    }

    function _lerEnderecos() internal returns (Infra memory infra) {
        string memory json = vm.readFile(OUTPUT_PATH);
        infra.moeda = MockBRL(vm.parseJsonAddress(json, ".moeda"));
        infra.gateway = EmissaoGateway(vm.parseJsonAddress(json, ".gateway"));
        infra.tokenFactory = ParticipacaoTokenFactory(vm.parseJsonAddress(json, ".tokenFactory"));
        infra.captacaoFactory = OfertaCaptacaoFactory(vm.parseJsonAddress(json, ".captacaoFactory"));
    }

    // ── Execução do AGENTE_ROLE proposto em DemoSepolia_Setup ──────────────────────────

    function _executarAgente(Infra memory infra, address agente) internal {
        bytes32 role = keccak256("AGENTE_ROLE");
        address[3] memory alvos =
            [address(infra.gateway), address(infra.tokenFactory), address(infra.captacaoFactory)];
        for (uint256 i = 0; i < alvos.length; i++) {
            (bool ok,) = alvos[i].call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, agente));
            require(ok, "executeGrantRole falhou (timelock ainda nao decorrido?)");
        }
        // RegistroInvestidorQualificado nao e' usado nesta demo (sem investidor qualificado
        // testado), mas seu AGENTE_ROLE tambem foi proposto em DemoSepolia_Setup — deixado
        // pendente de propósito, sem custo funcional para este ciclo.
    }

    // ── Sequência operacional: criarOferta → atestarCotas → criarCaptacao → registrarCaptacao ──

    function _criarOfertaECaptacao(Infra memory infra, Config memory cfg)
        internal
        returns (address token, address oferta)
    {
        token = infra.tokenFactory.criarOferta(
            "Oferta Demo Sepolia",
            "nCAP",
            "Empresa Captacao Demo Ltda",
            keccak256(abi.encode("cnpj-demo-sepolia", block.timestamp)),
            "2026-DEMO-SEPOLIA"
        );
        infra.gateway.atestarCotas(token, (META_MAXIMA / PRECO_POR_COTA) * 1 ether);

        oferta = infra.captacaoFactory.criarCaptacao(
            token,
            META_MINIMA,
            META_MAXIMA,
            PRECO_POR_COTA,
            block.timestamp + PRAZO_SEGUNDOS,
            TETO_POR_INVESTIDOR,
            TAXA_BPS,
            cfg.emissorWallet,
            cfg.protocoloWallet
        );
        infra.gateway.registrarCaptacao(token, oferta);
    }

    function _topUpEthSeNecessario(address investidor) internal {
        if (investidor.balance < SALDO_ETH_MINIMO_INVESTIDOR) {
            (bool ok,) = investidor.call{value: TOP_UP_ETH_INVESTIDOR}("");
            require(ok, "top-up de ETH falhou");
        }
    }

    function _aportar(uint256 investidorPk, MockBRL moeda, address oferta, uint256 valor) internal {
        vm.startBroadcast(investidorPk);
        moeda.approve(oferta, valor);
        OfertaCaptacao(oferta).aportar(valor);
        vm.stopBroadcast();
    }

    // ── Logs ────────────────────────────────────────────────────────────────────────────

    function _logResultados(Infra memory infra, Config memory cfg, address token, address oferta) internal view {
        console2.log("== DemoSepolia: ciclo completo ==");
        console2.log("Token (ParticipacaoToken):", token);
        console2.log("Oferta (escrow OfertaCaptacao):", oferta);
        console2.log("Estado final (1 = EncerradaSucesso):", uint256(OfertaCaptacao(oferta).estado()));
        console2.log("Total arrecadado:", OfertaCaptacao(oferta).totalArrecadado());
        console2.log("");
        console2.log("Cotas investidor 1:", ParticipacaoToken(token).balanceOf(cfg.investidor1));
        console2.log("Cotas investidor 2:", ParticipacaoToken(token).balanceOf(cfg.investidor2));
        console2.log("totalSupply do token (deve ser 50 ether = 50 cotas):", ParticipacaoToken(token).totalSupply());
        console2.log("");
        console2.log("MockBRL no emissor apos liberacao (deve ser 5000 ether):", infra.moeda.balanceOf(cfg.emissorWallet));
        console2.log("MockBRL no protocolo apos liberacao (taxa 0):", infra.moeda.balanceOf(cfg.protocoloWallet));
        console2.log("MockBRL restante no escrow (deve ser 0):", infra.moeda.balanceOf(oferta));
    }
}
