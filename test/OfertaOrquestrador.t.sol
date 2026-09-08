// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {OfertaCaptacao} from "../src/captacao/OfertaCaptacao.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";
import {RegistroInvestidorQualificado} from "../src/registro/RegistroInvestidorQualificado.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";
import {OfertaOrquestrador} from "../src/orquestracao/OfertaOrquestrador.sol";
import {MockEmissaoGatewayRevertaEmRegistrar} from "./mocks/MockEmissaoGatewayRevertaEmRegistrar.sol";

/// @notice Contrato intermediário usado para provar que `emissorWallet` é sempre quem chamou
/// `criarOfertaCompleta` por último — não há parâmetro na função para "repassar" outro
/// endereço, então mesmo um relayer autorizado só consegue gravar a si mesmo como emissor.
contract EmissorRelay {
    OfertaOrquestrador public orq;

    constructor(OfertaOrquestrador orq_) {
        orq = orq_;
    }

    function criar(
        string memory nome,
        string memory simbolo,
        string memory empresa,
        bytes32 cnpjRef,
        string memory serie,
        uint256 metaMinima,
        uint256 metaMaxima,
        uint256 precoPorCota,
        uint256 prazo
    ) external returns (address token, address oferta) {
        return orq.criarOfertaCompleta(nome, simbolo, empresa, cnpjRef, serie, metaMinima, metaMaxima, precoPorCota, prazo);
    }
}

contract OfertaOrquestradorTest is Test {
    ParticipacaoToken public tokenImpl;
    ParticipacaoTokenFactory public tokenFactory;
    EmissaoGateway public gateway;
    OfertaCaptacao public ofertaImpl;
    OfertaCaptacaoFactory public captacaoFactory;
    RegistroInvestidorQualificado public registro;
    DenyAllTransferPolicy public policy;
    MockBRL public moeda;
    OfertaOrquestrador public orq;

    address public admin = makeAddr("admin");
    address public agentePlataforma = makeAddr("agentePlataforma");
    address public agenteOrq = makeAddr("agenteOrq");
    address public emissor1 = makeAddr("emissor1");
    address public emissor2 = makeAddr("emissor2");
    address public estranho = makeAddr("estranho");
    address public protocoloWallet = makeAddr("protocoloWallet");
    address public investidor1 = makeAddr("investidor1");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    uint256 public constant TAXA_BPS_INICIAL = 0;
    uint256 public constant TETO_POR_INVESTIDOR_INICIAL = 1_000_000 ether;

    string public constant NOME = "Oferta Teste";
    string public constant SIMBOLO = "nTST";
    string public constant EMPRESA = "Empresa Teste Ltda";
    bytes32 public constant CNPJ_REF = keccak256("12.345.678/0001-99");
    string public constant SERIE = "2026-A";

    // Valores "padrão" válidos para os testes que não estão testando um limite específico:
    // metaMinima=800, metaMaxima=1000 (exatamente 125% -> passa o teste de lote adicional),
    // precoPorCota=100 (1000 % 100 == 0 -> 10 cotas).
    uint256 public constant META_MINIMA_PADRAO = 800 ether;
    uint256 public constant META_MAXIMA_PADRAO = 1000 ether;
    uint256 public constant PRECO_POR_COTA_PADRAO = 100 ether;

    function setUp() public {
        tokenImpl = new ParticipacaoToken();
        policy = new DenyAllTransferPolicy();
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        tokenFactory =
            new ParticipacaoTokenFactory(admin, address(tokenImpl), address(gateway), address(policy), TIMELOCK_DELAY);

        registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        moeda = new MockBRL();
        ofertaImpl = new OfertaCaptacao();
        captacaoFactory = new OfertaCaptacaoFactory(
            admin, address(ofertaImpl), address(gateway), address(registro), address(moeda), TIMELOCK_DELAY
        );

        orq = new OfertaOrquestrador(
            admin,
            address(tokenFactory),
            address(gateway),
            address(captacaoFactory),
            protocoloWallet,
            TAXA_BPS_INICIAL,
            TETO_POR_INVESTIDOR_INICIAL,
            TIMELOCK_DELAY
        );

        // AGENTE_ROLE do orquestrador nos 3 contratos-alvo (ver PLANO_OFERTA_ORQUESTRADOR.md).
        _grantRole(address(tokenFactory), tokenFactory.AGENTE_ROLE(), address(orq));
        _grantRole(address(gateway), gateway.AGENTE_ROLE(), address(orq));
        _grantRole(address(captacaoFactory), captacaoFactory.AGENTE_ROLE(), address(orq));

        // AGENTE_ROLE de um humano/script na infra real também, para ações manuais usadas nos
        // testes (ex.: cancelar() de uma captação para simular "encerrada com falha").
        _grantRole(address(gateway), gateway.AGENTE_ROLE(), agentePlataforma);

        // AGENTE_ROLE do próprio orquestrador (allowlist/pausa).
        _grantRole(address(orq), orq.AGENTE_ROLE(), agenteOrq);

        vm.prank(agenteOrq);
        orq.autorizarEmissor(emissor1);
    }

    function _grantRole(address target, bytes32 role, address account) internal {
        vm.prank(admin);
        (bool ok1,) = target.call(abi.encodeWithSignature("proposeGrantRole(bytes32,address)", role, account));
        require(ok1, "propose falhou");
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        (bool ok2,) = target.call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, account));
        require(ok2, "execute falhou");
    }

    function _prazoValido() internal view returns (uint256) {
        return block.timestamp + 90 days;
    }

    function _criarOfertaPadrao(address emissor) internal returns (address token, address oferta) {
        vm.prank(emissor);
        return orq.criarOfertaCompleta(
            NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, META_MINIMA_PADRAO, META_MAXIMA_PADRAO, PRECO_POR_COTA_PADRAO, _prazoValido()
        );
    }

    // ── Construtor ──────────────────────────────────────────────────────────────────────────

    function test_Constructor_RevertsForZeroAdmin() public {
        vm.expectRevert(OfertaOrquestrador.ZeroAddress.selector);
        new OfertaOrquestrador(
            address(0),
            address(tokenFactory),
            address(gateway),
            address(captacaoFactory),
            protocoloWallet,
            TAXA_BPS_INICIAL,
            TETO_POR_INVESTIDOR_INICIAL,
            TIMELOCK_DELAY
        );
    }

    function test_Constructor_RevertsForZeroTokenFactory() public {
        vm.expectRevert(OfertaOrquestrador.ZeroAddress.selector);
        new OfertaOrquestrador(
            admin,
            address(0),
            address(gateway),
            address(captacaoFactory),
            protocoloWallet,
            TAXA_BPS_INICIAL,
            TETO_POR_INVESTIDOR_INICIAL,
            TIMELOCK_DELAY
        );
    }

    function test_Constructor_RevertsForZeroEmissaoGateway() public {
        vm.expectRevert(OfertaOrquestrador.ZeroAddress.selector);
        new OfertaOrquestrador(
            admin,
            address(tokenFactory),
            address(0),
            address(captacaoFactory),
            protocoloWallet,
            TAXA_BPS_INICIAL,
            TETO_POR_INVESTIDOR_INICIAL,
            TIMELOCK_DELAY
        );
    }

    function test_Constructor_RevertsForZeroCaptacaoFactory() public {
        vm.expectRevert(OfertaOrquestrador.ZeroAddress.selector);
        new OfertaOrquestrador(
            admin,
            address(tokenFactory),
            address(gateway),
            address(0),
            protocoloWallet,
            TAXA_BPS_INICIAL,
            TETO_POR_INVESTIDOR_INICIAL,
            TIMELOCK_DELAY
        );
    }

    function test_Constructor_RevertsForZeroProtocoloWallet() public {
        vm.expectRevert(OfertaOrquestrador.ZeroAddress.selector);
        new OfertaOrquestrador(
            admin,
            address(tokenFactory),
            address(gateway),
            address(captacaoFactory),
            address(0),
            TAXA_BPS_INICIAL,
            TETO_POR_INVESTIDOR_INICIAL,
            TIMELOCK_DELAY
        );
    }

    function test_Constructor_RevertsForTaxaBpsAcimaDoMaximo() public {
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.TaxaExcedeMaximo.selector, 101, 100));
        new OfertaOrquestrador(
            admin,
            address(tokenFactory),
            address(gateway),
            address(captacaoFactory),
            protocoloWallet,
            101,
            TETO_POR_INVESTIDOR_INICIAL,
            TIMELOCK_DELAY
        );
    }

    function test_Constructor_SetsState() public view {
        assertEq(orq.tokenFactory(), address(tokenFactory));
        assertEq(orq.emissaoGateway(), address(gateway));
        assertEq(orq.captacaoFactory(), address(captacaoFactory));
        assertEq(orq.protocoloWallet(), protocoloWallet);
        assertEq(orq.taxaBps(), TAXA_BPS_INICIAL);
        assertEq(orq.tetoPorInvestidor(), TETO_POR_INVESTIDOR_INICIAL);
        assertTrue(orq.hasRole(orq.DEFAULT_ADMIN_ROLE(), admin));
    }

    // ── Allowlist ───────────────────────────────────────────────────────────────────────────

    function test_AutorizarEmissor_OnlyAgente() public {
        vm.prank(estranho);
        vm.expectRevert();
        orq.autorizarEmissor(emissor2);
    }

    function test_AutorizarEmissor_RevertsForZeroAddress() public {
        vm.prank(agenteOrq);
        vm.expectRevert(OfertaOrquestrador.ZeroAddress.selector);
        orq.autorizarEmissor(address(0));
    }

    function test_RevogarEmissor_OnlyAgente() public {
        vm.prank(estranho);
        vm.expectRevert();
        orq.revogarEmissor(emissor1);
    }

    function test_CriarOfertaCompleta_RevertsForEmissorNaoAutorizado() public {
        vm.prank(emissor2);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.EmissorNaoAutorizado.selector, emissor2));
        orq.criarOfertaCompleta(
            NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, META_MINIMA_PADRAO, META_MAXIMA_PADRAO, PRECO_POR_COTA_PADRAO, _prazoValido()
        );
    }

    function test_CriarOfertaCompleta_RevertsAposRevogacao() public {
        _criarOfertaPadrao(emissor1);

        vm.prank(agenteOrq);
        orq.revogarEmissor(emissor1);

        vm.prank(emissor1);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.EmissorNaoAutorizado.selector, emissor1));
        orq.criarOfertaCompleta(
            NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, META_MINIMA_PADRAO, META_MAXIMA_PADRAO, PRECO_POR_COTA_PADRAO, _prazoValido()
        );
    }

    // ── Limites Res. CVM 88 — boundary exato ───────────────────────────────────────────────

    function test_CriarOfertaCompleta_PrazoExatamente180Dias_Succeeds() public {
        uint256 prazo = block.timestamp + 180 days;
        vm.prank(emissor1);
        (address token, address oferta) = orq.criarOfertaCompleta(
            NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, META_MINIMA_PADRAO, META_MAXIMA_PADRAO, PRECO_POR_COTA_PADRAO, prazo
        );
        assertTrue(tokenFactory.isOferta(token));
        assertTrue(captacaoFactory.isCaptacao(oferta));
    }

    function test_CriarOfertaCompleta_Prazo180DiasMaisUmSegundo_Reverts() public {
        uint256 prazo = block.timestamp + 180 days + 1;
        vm.prank(emissor1);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.PrazoExcedeLimite.selector, prazo, 180 days));
        orq.criarOfertaCompleta(
            NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, META_MINIMA_PADRAO, META_MAXIMA_PADRAO, PRECO_POR_COTA_PADRAO, prazo
        );
    }

    function test_CriarOfertaCompleta_RevertsForPrazoNoPassadoOuPresente() public {
        vm.prank(emissor1);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.PrazoInvalido.selector, block.timestamp));
        orq.criarOfertaCompleta(
            NOME,
            SIMBOLO,
            EMPRESA,
            CNPJ_REF,
            SERIE,
            META_MINIMA_PADRAO,
            META_MAXIMA_PADRAO,
            PRECO_POR_COTA_PADRAO,
            block.timestamp
        );
    }

    function test_CriarOfertaCompleta_MetaMaximaExatamenteNoTeto_Succeeds() public {
        uint256 metaMaxima = orq.TETO_OFERTA(); // 15_000_000 ether
        uint256 metaMinima = 12_000_000 ether; // metaMaxima*100 == metaMinima*125, exato
        uint256 precoPorCota = 1_000_000 ether; // 15_000_000 % 1_000_000 == 0

        vm.prank(emissor1);
        (address token,) =
            orq.criarOfertaCompleta(NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, metaMinima, metaMaxima, precoPorCota, _prazoValido());
        assertEq(ParticipacaoToken(token).cotasAutorizadas(), 15 ether);
    }

    function test_CriarOfertaCompleta_MetaMaximaExcedeTetoPorUmWei_Reverts() public {
        uint256 teto = orq.TETO_OFERTA();
        uint256 metaMaxima = teto + 1;
        uint256 metaMinima = 12_000_000 ether;

        vm.prank(emissor1);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.MetaMaximaExcedeTeto.selector, metaMaxima, teto));
        orq.criarOfertaCompleta(
            NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, metaMinima, metaMaxima, 1_000_000 ether, _prazoValido()
        );
    }

    function test_CriarOfertaCompleta_LoteAdicionalExatamente125PorCento_Succeeds() public {
        // META_MAXIMA_PADRAO * 100 == META_MINIMA_PADRAO * 125 (1000*100 == 800*125 == 100_000)
        (address token, address oferta) = _criarOfertaPadrao(emissor1);
        assertTrue(tokenFactory.isOferta(token));
        assertTrue(captacaoFactory.isCaptacao(oferta));
    }

    function test_CriarOfertaCompleta_LoteAdicionalExcede125PorCotaPorUmWei_Reverts() public {
        uint256 metaMinima = META_MINIMA_PADRAO; // 800 ether
        uint256 metaMaxima = META_MAXIMA_PADRAO + 1; // 1000 ether + 1 wei

        vm.prank(emissor1);
        vm.expectRevert(
            abi.encodeWithSelector(OfertaOrquestrador.LoteAdicionalExcedeLimite.selector, metaMaxima, metaMinima)
        );
        orq.criarOfertaCompleta(
            NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, metaMinima, metaMaxima, PRECO_POR_COTA_PADRAO, _prazoValido()
        );
    }

    // ── Aritmética / derivação ──────────────────────────────────────────────────────────────

    function test_CriarOfertaCompleta_RevertsForPrecoPorCotaZero_ComErroNomeado() public {
        vm.prank(emissor1);
        vm.expectRevert(OfertaOrquestrador.PrecoInvalido.selector);
        orq.criarOfertaCompleta(
            NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, META_MINIMA_PADRAO, META_MAXIMA_PADRAO, 0, _prazoValido()
        );
    }

    function test_CriarOfertaCompleta_RevertsForMetaMaximaNaoMultiplaDoPreco() public {
        uint256 precoPorCota = 300 ether; // 1000 % 300 != 0
        vm.prank(emissor1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OfertaOrquestrador.PrecoNaoDivideMetaMaxima.selector, META_MAXIMA_PADRAO, precoPorCota
            )
        );
        orq.criarOfertaCompleta(
            NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, META_MINIMA_PADRAO, META_MAXIMA_PADRAO, precoPorCota, _prazoValido()
        );
    }

    function test_CriarOfertaCompleta_CotasAutorizadasEDerivadaCorretamente() public {
        (address token,) = _criarOfertaPadrao(emissor1);
        // metaMaxima/precoPorCota = 1000/100 = 10 cotas -> 10 ether em unidade bruta.
        assertEq(ParticipacaoToken(token).cotasAutorizadas(), 10 ether);
    }

    // ── Anti-manipulação ────────────────────────────────────────────────────────────────────

    function test_CriarOfertaCompleta_EmissorWalletEhSempreMsgSender() public {
        (, address oferta) = _criarOfertaPadrao(emissor1);
        assertEq(OfertaCaptacao(oferta).emissorWallet(), emissor1);
    }

    function test_CriarOfertaCompleta_EmissorWalletEhSempreMsgSender_MesmoViaContratoIntermediario() public {
        EmissorRelay relay = new EmissorRelay(orq);

        vm.prank(agenteOrq);
        orq.autorizarEmissor(address(relay));

        (, address oferta) = relay.criar(
            NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, META_MINIMA_PADRAO, META_MAXIMA_PADRAO, PRECO_POR_COTA_PADRAO, _prazoValido()
        );

        // Não existe parâmetro de `criarOfertaCompleta` para "repassar" outro emissor — mesmo
        // um relayer autorizado só consegue gravar a si mesmo, nunca um terceiro.
        assertEq(OfertaCaptacao(oferta).emissorWallet(), address(relay));
    }

    function test_CriarOfertaCompleta_TaxaBpsEProtocoloWalletVemDoStorageDoOrquestrador() public {
        (, address oferta) = _criarOfertaPadrao(emissor1);
        assertEq(OfertaCaptacao(oferta).taxaBps(), TAXA_BPS_INICIAL);
        assertEq(OfertaCaptacao(oferta).protocoloWallet(), protocoloWallet);
        assertEq(OfertaCaptacao(oferta).tetoPorInvestidor(), TETO_POR_INVESTIDOR_INICIAL);
    }

    function test_CriarOfertaCompleta_MudancaDeParametrosSoAfetaOfertasFuturas() public {
        (, address ofertaAntiga) = _criarOfertaPadrao(emissor1);

        // Muda taxaBps e protocoloWallet via timelock.
        address novoProtocoloWallet = makeAddr("novoProtocoloWallet");
        vm.prank(admin);
        orq.proposeSetTaxaBps(50);
        vm.prank(admin);
        orq.proposeSetProtocoloWallet(novoProtocoloWallet);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        orq.executeSetTaxaBps(50);
        vm.prank(admin);
        orq.executeSetProtocoloWallet(novoProtocoloWallet);

        // Fecha a oferta antiga (falha) para poder abrir a segunda do mesmo emissor.
        vm.prank(agentePlataforma);
        OfertaCaptacao(ofertaAntiga).cancelar();

        (, address ofertaNova) = _criarOfertaPadrao(emissor1);

        // A antiga manteve os parâmetros vigentes no momento em que foi criada.
        assertEq(OfertaCaptacao(ofertaAntiga).taxaBps(), TAXA_BPS_INICIAL);
        assertEq(OfertaCaptacao(ofertaAntiga).protocoloWallet(), protocoloWallet);
        // A nova reflete os parâmetros vigentes agora.
        assertEq(OfertaCaptacao(ofertaNova).taxaBps(), 50);
        assertEq(OfertaCaptacao(ofertaNova).protocoloWallet(), novoProtocoloWallet);
    }

    // ── Uma oferta aberta por vez ───────────────────────────────────────────────────────────

    function test_CriarOfertaCompleta_RevertsSeAnteriorAindaAberta() public {
        (, address ofertaAnterior) = _criarOfertaPadrao(emissor1);

        vm.prank(emissor1);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.OfertaAnteriorAindaAberta.selector, ofertaAnterior));
        orq.criarOfertaCompleta(
            NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, META_MINIMA_PADRAO, META_MAXIMA_PADRAO, PRECO_POR_COTA_PADRAO, _prazoValido()
        );
    }

    function test_CriarOfertaCompleta_PermiteSegundaAposEncerradaComFalha() public {
        (, address ofertaAnterior) = _criarOfertaPadrao(emissor1);

        vm.prank(agentePlataforma);
        OfertaCaptacao(ofertaAnterior).cancelar();
        assertEq(uint256(OfertaCaptacao(ofertaAnterior).estado()), uint256(OfertaCaptacao.Estado.EncerradaFalha));

        (address token2, address oferta2) = _criarOfertaPadrao(emissor1);
        assertTrue(tokenFactory.isOferta(token2));
        assertTrue(captacaoFactory.isCaptacao(oferta2));
        assertEq(orq.numOfertasDoEmissor(emissor1), 2);
    }

    function test_CriarOfertaCompleta_PermiteSegundaAposEncerradaComSucesso() public {
        // metaMinima == metaMaxima para permitir encerrar() antes do prazo (subscrição cheia).
        uint256 meta = 1000 ether;
        uint256 precoPorCota = 100 ether;

        vm.prank(emissor1);
        (, address ofertaAnterior) =
            orq.criarOfertaCompleta(NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, meta, meta, precoPorCota, _prazoValido());

        moeda.mint(investidor1, meta);
        vm.prank(investidor1);
        moeda.approve(ofertaAnterior, meta);
        vm.prank(investidor1);
        OfertaCaptacao(ofertaAnterior).aportar(meta);

        OfertaCaptacao(ofertaAnterior).encerrar();
        assertEq(uint256(OfertaCaptacao(ofertaAnterior).estado()), uint256(OfertaCaptacao.Estado.EncerradaSucesso));

        (, address oferta2) = _criarOfertaPadrao(emissor1);
        assertTrue(captacaoFactory.isCaptacao(oferta2));
    }

    // ── Atomicidade ─────────────────────────────────────────────────────────────────────────

    function test_CriarOfertaCompleta_RevertsSemPapeisConcedidos_SemEstadoParcial() public {
        OfertaOrquestrador orqSemPapel = new OfertaOrquestrador(
            admin,
            address(tokenFactory),
            address(gateway),
            address(captacaoFactory),
            protocoloWallet,
            TAXA_BPS_INICIAL,
            TETO_POR_INVESTIDOR_INICIAL,
            TIMELOCK_DELAY
        );
        _grantRole(address(orqSemPapel), orqSemPapel.AGENTE_ROLE(), agenteOrq);
        vm.prank(agenteOrq);
        orqSemPapel.autorizarEmissor(emissor1);

        uint256 numOfertasAntes = tokenFactory.numOfertas();
        uint256 numCaptacoesAntes = captacaoFactory.numCaptacoes();

        vm.prank(emissor1);
        vm.expectRevert();
        orqSemPapel.criarOfertaCompleta(
            NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, META_MINIMA_PADRAO, META_MAXIMA_PADRAO, PRECO_POR_COTA_PADRAO, _prazoValido()
        );

        assertEq(tokenFactory.numOfertas(), numOfertasAntes);
        assertEq(captacaoFactory.numCaptacoes(), numCaptacoesAntes);
        assertEq(orqSemPapel.numOfertasDoEmissor(emissor1), 0);
    }

    function test_CriarOfertaCompleta_RevertNaQuartaChamada_NaoCriaNadaEmNenhumLugar() public {
        MockEmissaoGatewayRevertaEmRegistrar mockGateway = new MockEmissaoGatewayRevertaEmRegistrar();

        OfertaOrquestrador orqAtomico = new OfertaOrquestrador(
            admin,
            address(tokenFactory),
            address(mockGateway),
            address(captacaoFactory),
            protocoloWallet,
            TAXA_BPS_INICIAL,
            TETO_POR_INVESTIDOR_INICIAL,
            TIMELOCK_DELAY
        );
        _grantRole(address(tokenFactory), tokenFactory.AGENTE_ROLE(), address(orqAtomico));
        _grantRole(address(captacaoFactory), captacaoFactory.AGENTE_ROLE(), address(orqAtomico));
        _grantRole(address(orqAtomico), orqAtomico.AGENTE_ROLE(), agenteOrq);

        vm.prank(agenteOrq);
        orqAtomico.autorizarEmissor(emissor1);

        uint256 numOfertasAntes = tokenFactory.numOfertas();
        uint256 numCaptacoesAntes = captacaoFactory.numCaptacoes();

        vm.prank(emissor1);
        vm.expectRevert(MockEmissaoGatewayRevertaEmRegistrar.FalhaForcadaParaTeste.selector);
        orqAtomico.criarOfertaCompleta(
            NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, META_MINIMA_PADRAO, META_MAXIMA_PADRAO, PRECO_POR_COTA_PADRAO, _prazoValido()
        );

        // Nem o token, nem a captação (criados nas subchamadas 1 e 3, ANTES da falha na 4ª)
        // persistem — a EVM desfaz tudo atomicamente, inclusive os dois `Clones.clone`.
        assertEq(tokenFactory.numOfertas(), numOfertasAntes);
        assertEq(captacaoFactory.numCaptacoes(), numCaptacoesAntes);
        assertEq(orqAtomico.numOfertasDoEmissor(emissor1), 0);
        assertEq(orqAtomico.ultimaOfertaDoEmissor(emissor1), address(0));
    }

    // ── Pausa ───────────────────────────────────────────────────────────────────────────────

    function test_Pause_OnlyAgente() public {
        vm.prank(estranho);
        vm.expectRevert();
        orq.pause();
    }

    function test_Pause_BloqueiaCriarOfertaCompleta() public {
        vm.prank(agenteOrq);
        orq.pause();

        vm.prank(emissor1);
        vm.expectRevert();
        orq.criarOfertaCompleta(
            NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, META_MINIMA_PADRAO, META_MAXIMA_PADRAO, PRECO_POR_COTA_PADRAO, _prazoValido()
        );
    }

    function test_Pause_NaoAfetaOfertasJaVivas() public {
        uint256 meta = 1000 ether;
        uint256 precoPorCota = 100 ether;

        vm.prank(emissor1);
        (address token, address oferta) =
            orq.criarOfertaCompleta(NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, meta, meta, precoPorCota, _prazoValido());

        moeda.mint(investidor1, meta);
        vm.prank(investidor1);
        moeda.approve(oferta, meta);

        vm.prank(agenteOrq);
        orq.pause();

        // Aportar, encerrar e resgatar continuam funcionando com o orquestrador pausado — a
        // pausa só desliga `criarOfertaCompleta`.
        vm.prank(investidor1);
        OfertaCaptacao(oferta).aportar(meta);

        OfertaCaptacao(oferta).encerrar();
        assertEq(uint256(OfertaCaptacao(oferta).estado()), uint256(OfertaCaptacao.Estado.EncerradaSucesso));

        vm.prank(investidor1);
        OfertaCaptacao(oferta).resgatarCotas();
        assertEq(ParticipacaoToken(token).balanceOf(investidor1), 10 ether);
    }

    function test_Unpause_OnlyAgente() public {
        vm.prank(agenteOrq);
        orq.pause();

        vm.prank(estranho);
        vm.expectRevert();
        orq.unpause();

        vm.prank(agenteOrq);
        orq.unpause();

        (address token,) = _criarOfertaPadrao(emissor1);
        assertTrue(tokenFactory.isOferta(token));
    }

    // ── Ciclo completo ponta a ponta ────────────────────────────────────────────────────────

    function test_CicloCompleto_CriaAportaEncerraResgata() public {
        uint256 meta = 1000 ether;
        uint256 precoPorCota = 100 ether;

        vm.prank(emissor1);
        (address token, address oferta) =
            orq.criarOfertaCompleta(NOME, SIMBOLO, EMPRESA, CNPJ_REF, SERIE, meta, meta, precoPorCota, _prazoValido());

        moeda.mint(investidor1, meta);
        vm.prank(investidor1);
        moeda.approve(oferta, meta);
        vm.prank(investidor1);
        OfertaCaptacao(oferta).aportar(meta);

        OfertaCaptacao(oferta).encerrar();
        assertEq(uint256(OfertaCaptacao(oferta).estado()), uint256(OfertaCaptacao.Estado.EncerradaSucesso));

        vm.prank(investidor1);
        OfertaCaptacao(oferta).resgatarCotas();

        // meta/precoPorCota = 10 cotas -> 10 ether em unidade bruta do token.
        assertEq(ParticipacaoToken(token).balanceOf(investidor1), 10 ether);
    }

    // ── Governança dos parâmetros de plataforma (timelock) ─────────────────────────────────

    function test_ProposeSetTaxaBps_OnlyDefaultAdmin() public {
        vm.prank(estranho);
        vm.expectRevert();
        orq.proposeSetTaxaBps(50);
    }

    function test_ProposeSetTaxaBps_RevertsAcimaDoMaximo() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.TaxaExcedeMaximo.selector, 101, 100));
        orq.proposeSetTaxaBps(101);
    }

    function test_ExecuteSetTaxaBps_RevertsAcimaDoMaximo_MesmoChamadoDireto() public {
        // Mesma lição já aplicada em LiquidacaoSecundaria.executeSetTaxaSecundarioBps: o teto é
        // validado também no execute, não só no propose.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.TaxaExcedeMaximo.selector, 101, 100));
        orq.executeSetTaxaBps(101);
    }

    function test_SetTaxaBps_RespeitaTimelock() public {
        vm.prank(admin);
        orq.proposeSetTaxaBps(50);

        vm.prank(admin);
        vm.expectRevert();
        orq.executeSetTaxaBps(50);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        orq.executeSetTaxaBps(50);
        assertEq(orq.taxaBps(), 50);
    }

    function test_SetProtocoloWallet_RespeitaTimelockERejeitaZeroAddress() public {
        address novo = makeAddr("novoProtocoloWallet");

        vm.prank(admin);
        vm.expectRevert(OfertaOrquestrador.ZeroAddress.selector);
        orq.proposeSetProtocoloWallet(address(0));

        vm.prank(admin);
        orq.proposeSetProtocoloWallet(novo);

        vm.prank(admin);
        vm.expectRevert();
        orq.executeSetProtocoloWallet(novo);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        orq.executeSetProtocoloWallet(novo);
        assertEq(orq.protocoloWallet(), novo);
    }

    function test_SetTetoPorInvestidor_RespeitaTimelock() public {
        vm.prank(admin);
        orq.proposeSetTetoPorInvestidor(2_000_000 ether);

        vm.prank(admin);
        vm.expectRevert();
        orq.executeSetTetoPorInvestidor(2_000_000 ether);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        orq.executeSetTetoPorInvestidor(2_000_000 ether);
        assertEq(orq.tetoPorInvestidor(), 2_000_000 ether);
    }

    // ── Views ───────────────────────────────────────────────────────────────────────────────

    function test_NumOfertasDoEmissor() public {
        assertEq(orq.numOfertasDoEmissor(emissor1), 0);
        (, address oferta) = _criarOfertaPadrao(emissor1);
        assertEq(orq.numOfertasDoEmissor(emissor1), 1);
        assertEq(orq.ofertasPorEmissor(emissor1, 0), oferta);
        assertEq(orq.ultimaOfertaDoEmissor(emissor1), oferta);
    }
}
