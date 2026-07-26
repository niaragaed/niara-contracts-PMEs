// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {OfertaCaptacao} from "../src/captacao/OfertaCaptacao.sol";
import {IOfertaCaptacao} from "../src/interfaces/IOfertaCaptacao.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RegistroInvestidorQualificado} from "../src/registro/RegistroInvestidorQualificado.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";

contract OfertaCaptacaoTest is Test {
    OfertaCaptacao public oferta;
    EmissaoGateway public gateway;
    RegistroInvestidorQualificado public registro;
    MockBRL public moeda;
    ParticipacaoToken public token;

    address public admin = makeAddr("admin");
    address public agente = makeAddr("agente");
    address public estranho = makeAddr("estranho");
    address public emissorWallet = makeAddr("emissorWallet");
    address public protocoloWallet = makeAddr("protocoloWallet");
    address public investidor1 = makeAddr("investidor1");
    address public investidor2 = makeAddr("investidor2");

    uint256 public constant TIMELOCK_DELAY = 1 hours;

    uint256 public constant META_MINIMA = 10_000 ether;
    uint256 public constant META_MAXIMA = 50_000 ether;
    uint256 public constant PRECO_POR_COTA = 100 ether;
    uint256 public constant TETO_POR_INVESTIDOR = 20_000 ether;
    uint256 public constant TAXA_BPS = 50; // 0.5%
    uint256 public prazo;

    function setUp() public {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        moeda = new MockBRL();

        _grantRole(address(gateway), gateway.AGENTE_ROLE(), agente);
        _grantRole(address(registro), registro.AGENTE_ROLE(), agente);

        DenyAllTransferPolicy policy = new DenyAllTransferPolicy();
        ParticipacaoToken tokenImpl = new ParticipacaoToken();
        token = ParticipacaoToken(Clones.clone(address(tokenImpl)));
        token.initialize("Oferta X", "nX", address(gateway), address(policy), "Empresa X", bytes32(0), "2026-A");

        vm.prank(agente);
        gateway.atestarCotas(address(token), (META_MAXIMA / PRECO_POR_COTA) * 1 ether);

        prazo = block.timestamp + 30 days;

        OfertaCaptacao impl = new OfertaCaptacao();
        oferta = OfertaCaptacao(Clones.clone(address(impl)));
        oferta.initialize(
            IOfertaCaptacao.InitParams({
                token: address(token),
                gateway: address(gateway),
                registro: address(registro),
                moeda: address(moeda),
                emissorWallet: emissorWallet,
                protocoloWallet: protocoloWallet,
                metaMinima: META_MINIMA,
                metaMaxima: META_MAXIMA,
                precoPorCota: PRECO_POR_COTA,
                prazo: prazo,
                tetoPorInvestidor: TETO_POR_INVESTIDOR,
                taxaBps: TAXA_BPS
            })
        );

        vm.prank(agente);
        gateway.registrarCaptacao(address(token), address(oferta));

        moeda.mint(investidor1, 1_000_000 ether);
        moeda.mint(investidor2, 1_000_000 ether);
        vm.prank(investidor1);
        moeda.approve(address(oferta), type(uint256).max);
        vm.prank(investidor2);
        moeda.approve(address(oferta), type(uint256).max);
    }

    function _grantRole(address target, bytes32 role, address account) internal {
        vm.prank(admin);
        (bool ok1,) = target.call(abi.encodeWithSignature("proposeGrantRole(bytes32,address)", role, account));
        require(ok1, "propose failed");
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        (bool ok2,) = target.call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, account));
        require(ok2, "execute failed");
    }

    function _defaultParams() internal view returns (IOfertaCaptacao.InitParams memory) {
        return IOfertaCaptacao.InitParams({
            token: address(token),
            gateway: address(gateway),
            registro: address(registro),
            moeda: address(moeda),
            emissorWallet: emissorWallet,
            protocoloWallet: protocoloWallet,
            metaMinima: META_MINIMA,
            metaMaxima: META_MAXIMA,
            precoPorCota: PRECO_POR_COTA,
            prazo: prazo,
            tetoPorInvestidor: TETO_POR_INVESTIDOR,
            taxaBps: TAXA_BPS
        });
    }

    function _newClone() internal returns (OfertaCaptacao) {
        OfertaCaptacao impl = new OfertaCaptacao();
        return OfertaCaptacao(Clones.clone(address(impl)));
    }

    // ── initialize ──────────────────────────────────────────────────────────────────────

    function test_Initialize_RevertsForZeroToken() public {
        OfertaCaptacao clone = _newClone();
        IOfertaCaptacao.InitParams memory p = _defaultParams();
        p.token = address(0);
        vm.expectRevert(OfertaCaptacao.ZeroAddress.selector);
        clone.initialize(p);
    }

    function test_Initialize_RevertsForZeroEmissorWallet() public {
        OfertaCaptacao clone = _newClone();
        IOfertaCaptacao.InitParams memory p = _defaultParams();
        p.emissorWallet = address(0);
        vm.expectRevert(OfertaCaptacao.ZeroAddress.selector);
        clone.initialize(p);
    }

    function test_Initialize_RevertsForMetaMinimaZero() public {
        OfertaCaptacao clone = _newClone();
        IOfertaCaptacao.InitParams memory p = _defaultParams();
        p.metaMinima = 0;
        vm.expectRevert(abi.encodeWithSelector(OfertaCaptacao.MetasInvalidas.selector, 0, META_MAXIMA));
        clone.initialize(p);
    }

    function test_Initialize_RevertsForMetaMinimaAboveMaxima() public {
        OfertaCaptacao clone = _newClone();
        IOfertaCaptacao.InitParams memory p = _defaultParams();
        p.metaMinima = META_MAXIMA + 1;
        vm.expectRevert(abi.encodeWithSelector(OfertaCaptacao.MetasInvalidas.selector, META_MAXIMA + 1, META_MAXIMA));
        clone.initialize(p);
    }

    function test_Initialize_RevertsForZeroPreco() public {
        OfertaCaptacao clone = _newClone();
        IOfertaCaptacao.InitParams memory p = _defaultParams();
        p.precoPorCota = 0;
        vm.expectRevert(OfertaCaptacao.PrecoInvalido.selector);
        clone.initialize(p);
    }

    function test_Initialize_RevertsForPastPrazo() public {
        OfertaCaptacao clone = _newClone();
        IOfertaCaptacao.InitParams memory p = _defaultParams();
        p.prazo = block.timestamp;
        vm.expectRevert(abi.encodeWithSelector(OfertaCaptacao.PrazoInvalido.selector, block.timestamp));
        clone.initialize(p);
    }

    function test_Initialize_RevertsForTaxaAboveMaximo() public {
        OfertaCaptacao clone = _newClone();
        IOfertaCaptacao.InitParams memory p = _defaultParams();
        p.taxaBps = 101;
        vm.expectRevert(abi.encodeWithSelector(OfertaCaptacao.TaxaExcedeMaximo.selector, 101, 100));
        clone.initialize(p);
    }

    function test_Initialize_CannotBeCalledTwice() public {
        vm.expectRevert();
        oferta.initialize(_defaultParams());
    }

    // ── aportar ─────────────────────────────────────────────────────────────────────────

    function test_Aportar_UpdatesStateAndTransfersFunds() public {
        vm.prank(investidor1);
        oferta.aportar(1_000 ether);

        assertEq(oferta.totalArrecadado(), 1_000 ether);
        assertEq(oferta.aportadoPor(investidor1), 1_000 ether);
        assertEq(moeda.balanceOf(address(oferta)), 1_000 ether);
    }

    function test_Aportar_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(oferta));
        emit OfertaCaptacao.Aporte(investidor1, 1_000 ether, 1_000 ether);
        vm.prank(investidor1);
        oferta.aportar(1_000 ether);
    }

    function test_Aportar_RevertsForNonMultipleOfPreco() public {
        vm.prank(investidor1);
        vm.expectRevert(
            abi.encodeWithSelector(OfertaCaptacao.AporteNaoMultiploDoPreco.selector, 150 ether, PRECO_POR_COTA)
        );
        oferta.aportar(150 ether);
    }

    function test_Aportar_RevertsForZeroValor() public {
        vm.prank(investidor1);
        vm.expectRevert(abi.encodeWithSelector(OfertaCaptacao.AporteNaoMultiploDoPreco.selector, 0, PRECO_POR_COTA));
        oferta.aportar(0);
    }

    function test_Aportar_RevertsBeyondMetaMaxima() public {
        vm.prank(investidor1);
        vm.expectRevert(
            abi.encodeWithSelector(OfertaCaptacao.ExcedeMetaMaxima.selector, META_MAXIMA + PRECO_POR_COTA, META_MAXIMA)
        );
        oferta.aportar(META_MAXIMA + PRECO_POR_COTA);
    }

    function test_Aportar_RevertsBeyondTetoPorInvestidorForNonQualified() public {
        vm.prank(investidor1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OfertaCaptacao.ExcedeTetoInvestidor.selector, TETO_POR_INVESTIDOR + PRECO_POR_COTA, TETO_POR_INVESTIDOR
            )
        );
        oferta.aportar(TETO_POR_INVESTIDOR + PRECO_POR_COTA);
    }

    function test_Aportar_QualifiedInvestorBypassesTeto() public {
        vm.prank(agente);
        registro.definirQualificado(investidor1, true);

        vm.prank(investidor1);
        oferta.aportar(TETO_POR_INVESTIDOR + PRECO_POR_COTA);

        assertEq(oferta.aportadoPor(investidor1), TETO_POR_INVESTIDOR + PRECO_POR_COTA);
    }

    function test_Aportar_RevertsAfterPrazo() public {
        vm.warp(prazo);
        vm.prank(investidor1);
        vm.expectRevert(OfertaCaptacao.PrazoExpirado.selector);
        oferta.aportar(1_000 ether);
    }

    function test_Aportar_RevertsWhenNotAberta() public {
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(investidor1);
        vm.expectRevert(OfertaCaptacao.OfertaNaoAberta.selector);
        oferta.aportar(1_000 ether);
    }

    function test_Aportar_RevertsWhenPaused() public {
        vm.prank(agente);
        oferta.pausar();

        vm.prank(investidor1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        oferta.aportar(1_000 ether);
    }

    function test_Aportar_MultipleInvestorsAccumulate() public {
        vm.prank(investidor1);
        oferta.aportar(1_000 ether);
        vm.prank(investidor2);
        oferta.aportar(2_000 ether);

        assertEq(oferta.totalArrecadado(), 3_000 ether);
    }

    // ── encerrar ────────────────────────────────────────────────────────────────────────

    function test_Encerrar_RevertsBeforePrazoAndBelowMetaMaxima() public {
        vm.prank(investidor1);
        oferta.aportar(1_000 ether);

        vm.expectRevert(OfertaCaptacao.EncerramentoPrematuro.selector);
        oferta.encerrar();
    }

    function test_Encerrar_SuccessAtOrAboveMetaMinimaAfterPrazo() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);

        vm.warp(prazo);
        oferta.encerrar();

        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.EncerradaSucesso));
    }

    function test_Encerrar_FailureBelowMetaMinimaAfterPrazo() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA - PRECO_POR_COTA);

        vm.warp(prazo);
        oferta.encerrar();

        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.EncerradaFalha));
    }

    function test_Encerrar_EarlyCloseAtMetaMaxima() public {
        vm.prank(agente);
        registro.definirQualificado(investidor1, true);
        vm.prank(investidor1);
        oferta.aportar(META_MAXIMA);

        // ainda antes do prazo, mas atingiu a meta máxima — deve permitir encerrar.
        oferta.encerrar();

        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.EncerradaSucesso));
    }

    function test_Encerrar_RevertsWhenAlreadyEncerrada() public {
        vm.warp(prazo);
        oferta.encerrar();

        vm.expectRevert(OfertaCaptacao.OfertaNaoAberta.selector);
        oferta.encerrar();
    }

    function test_Encerrar_EmitsEvent() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);
        vm.warp(prazo);

        vm.expectEmit(true, true, true, true, address(oferta));
        emit OfertaCaptacao.OfertaEncerrada(OfertaCaptacao.Estado.EncerradaSucesso, META_MINIMA);
        oferta.encerrar();
    }

    function test_Encerrar_IsPermissionless() public {
        vm.warp(prazo);
        vm.prank(estranho);
        oferta.encerrar();
        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.EncerradaFalha));
    }

    // ── cancelar ────────────────────────────────────────────────────────────────────────

    function test_Cancelar_OnlyAgente() public {
        vm.prank(estranho);
        vm.expectRevert(OfertaCaptacao.NaoAutorizado.selector);
        oferta.cancelar();
    }

    function test_Cancelar_MovesToEncerradaFalha() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);

        vm.prank(agente);
        oferta.cancelar();

        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.EncerradaFalha));
    }

    function test_Cancelar_RevertsWhenNotAberta() public {
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(agente);
        vm.expectRevert(OfertaCaptacao.OfertaNaoAberta.selector);
        oferta.cancelar();
    }

    function test_Cancelar_AllowsRefundAfterward() public {
        vm.prank(investidor1);
        oferta.aportar(1_000 ether);

        vm.prank(agente);
        oferta.cancelar();

        vm.prank(investidor1);
        oferta.reembolsar();
        assertEq(moeda.balanceOf(investidor1), 1_000_000 ether);
    }

    // ── resgatarCotas ───────────────────────────────────────────────────────────────────

    function test_ResgatarCotas_RevertsBeforeSucesso() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);

        vm.prank(investidor1);
        vm.expectRevert(OfertaCaptacao.OfertaNaoEncerradaComSucesso.selector);
        oferta.resgatarCotas();
    }

    function test_ResgatarCotas_MintsProportionalCotas() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(investidor1);
        oferta.resgatarCotas();

        assertEq(token.balanceOf(investidor1), (META_MINIMA / PRECO_POR_COTA) * 1 ether);
    }

    function test_ResgatarCotas_RevertsOnSecondCall() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(investidor1);
        oferta.resgatarCotas();

        vm.prank(investidor1);
        vm.expectRevert(OfertaCaptacao.JaResgatado.selector);
        oferta.resgatarCotas();
    }

    function test_ResgatarCotas_RevertsForNonContributor() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(estranho);
        vm.expectRevert(OfertaCaptacao.NadaAResgatar.selector);
        oferta.resgatarCotas();
    }

    function test_ResgatarCotas_EmitsEvent() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);
        vm.warp(prazo);
        oferta.encerrar();

        vm.expectEmit(true, true, true, true, address(oferta));
        emit OfertaCaptacao.CotasResgatadas(investidor1, (META_MINIMA / PRECO_POR_COTA) * 1 ether);
        vm.prank(investidor1);
        oferta.resgatarCotas();
    }

    function test_ResgatarCotas_IndependentAcrossInvestors() public {
        vm.prank(investidor1);
        oferta.aportar(4_000 ether);
        vm.prank(investidor2);
        oferta.aportar(META_MINIMA);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(investidor1);
        oferta.resgatarCotas();

        assertEq(token.balanceOf(investidor1), (4_000 ether / PRECO_POR_COTA) * 1 ether);
        assertEq(token.balanceOf(investidor2), 0);
        assertFalse(oferta.cotasResgatadas(investidor2));
    }

    // ── liberarParaEmissor ──────────────────────────────────────────────────────────────

    function test_LiberarParaEmissor_RevertsBeforeSucesso() public {
        vm.expectRevert(OfertaCaptacao.OfertaNaoEncerradaComSucesso.selector);
        oferta.liberarParaEmissor();
    }

    function test_LiberarParaEmissor_SplitsFeeAndPrincipal() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);
        vm.warp(prazo);
        oferta.encerrar();

        oferta.liberarParaEmissor();

        uint256 taxaEsperada = (META_MINIMA * TAXA_BPS) / 10_000;
        assertEq(moeda.balanceOf(protocoloWallet), taxaEsperada);
        assertEq(moeda.balanceOf(emissorWallet), META_MINIMA - taxaEsperada);
    }

    function test_LiberarParaEmissor_ZeroTaxaSendsEverythingToEmissor() public {
        OfertaCaptacao clone = _newClone();
        IOfertaCaptacao.InitParams memory p = _defaultParams();
        p.taxaBps = 0;
        clone.initialize(p);
        vm.prank(agente);
        gateway.registrarCaptacao(address(token), address(clone));

        vm.prank(investidor1);
        moeda.approve(address(clone), type(uint256).max);
        vm.prank(investidor1);
        clone.aportar(META_MINIMA);
        vm.warp(prazo);
        clone.encerrar();

        clone.liberarParaEmissor();

        assertEq(moeda.balanceOf(protocoloWallet), 0);
        assertEq(moeda.balanceOf(emissorWallet), META_MINIMA);
    }

    function test_LiberarParaEmissor_RevertsOnSecondCall() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);
        vm.warp(prazo);
        oferta.encerrar();

        oferta.liberarParaEmissor();

        vm.expectRevert(OfertaCaptacao.RecursosJaLiberados.selector);
        oferta.liberarParaEmissor();
    }

    function test_LiberarParaEmissor_IsPermissionless() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(estranho);
        oferta.liberarParaEmissor();

        assertTrue(oferta.recursosLiberados());
    }

    function test_LiberarParaEmissor_EmitsEvent() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);
        vm.warp(prazo);
        oferta.encerrar();

        uint256 taxaEsperada = (META_MINIMA * TAXA_BPS) / 10_000;
        vm.expectEmit(true, true, true, true, address(oferta));
        emit OfertaCaptacao.RecursosLiberados(emissorWallet, META_MINIMA - taxaEsperada, protocoloWallet, taxaEsperada);
        oferta.liberarParaEmissor();
    }

    function test_LiberarParaEmissor_DrainsEscrowRegardlessOfPendingResgates() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);
        vm.warp(prazo);
        oferta.encerrar();

        oferta.liberarParaEmissor();

        assertEq(moeda.balanceOf(address(oferta)), 0);
    }

    // ── reembolsar ──────────────────────────────────────────────────────────────────────

    function test_Reembolsar_RevertsBeforeFalha() public {
        vm.prank(investidor1);
        oferta.aportar(1_000 ether);

        vm.prank(investidor1);
        vm.expectRevert(OfertaCaptacao.OfertaNaoEncerradaComFalha.selector);
        oferta.reembolsar();
    }

    function test_Reembolsar_ReturnsExactContribution() public {
        vm.prank(investidor1);
        oferta.aportar(1_000 ether);
        vm.warp(prazo);
        oferta.encerrar();

        uint256 saldoAntes = moeda.balanceOf(investidor1);
        vm.prank(investidor1);
        oferta.reembolsar();

        assertEq(moeda.balanceOf(investidor1), saldoAntes + 1_000 ether);
    }

    function test_Reembolsar_RevertsOnSecondCall() public {
        vm.prank(investidor1);
        oferta.aportar(1_000 ether);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(investidor1);
        oferta.reembolsar();

        vm.prank(investidor1);
        vm.expectRevert(OfertaCaptacao.JaReembolsado.selector);
        oferta.reembolsar();
    }

    function test_Reembolsar_RevertsForNonContributor() public {
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(estranho);
        vm.expectRevert(OfertaCaptacao.NadaAReembolsar.selector);
        oferta.reembolsar();
    }

    function test_Reembolsar_EmitsEvent() public {
        vm.prank(investidor1);
        oferta.aportar(1_000 ether);
        vm.warp(prazo);
        oferta.encerrar();

        vm.expectEmit(true, true, true, true, address(oferta));
        emit OfertaCaptacao.Reembolso(investidor1, 1_000 ether);
        vm.prank(investidor1);
        oferta.reembolsar();
    }

    function test_Reembolsar_IndependentAcrossInvestors() public {
        vm.prank(investidor1);
        oferta.aportar(1_000 ether);
        vm.prank(investidor2);
        oferta.aportar(2_000 ether);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(investidor1);
        oferta.reembolsar();

        assertTrue(oferta.reembolsado(investidor1));
        assertFalse(oferta.reembolsado(investidor2));
        assertEq(moeda.balanceOf(address(oferta)), 2_000 ether);
    }

    // ── pausar / despausar ──────────────────────────────────────────────────────────────

    function test_Pausar_OnlyAgente() public {
        vm.prank(estranho);
        vm.expectRevert(OfertaCaptacao.NaoAutorizado.selector);
        oferta.pausar();
    }

    function test_Despausar_ReenablesAporte() public {
        vm.prank(agente);
        oferta.pausar();
        vm.prank(agente);
        oferta.despausar();

        vm.prank(investidor1);
        oferta.aportar(1_000 ether);
        assertEq(oferta.totalArrecadado(), 1_000 ether);
    }

    function test_Pausar_DoesNotBlockReembolso() public {
        vm.prank(investidor1);
        oferta.aportar(1_000 ether);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(agente);
        oferta.pausar();

        vm.prank(investidor1);
        oferta.reembolsar();
        assertTrue(oferta.reembolsado(investidor1));
    }

    function test_Pausar_DoesNotBlockResgatarCotas() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(agente);
        oferta.pausar();

        vm.prank(investidor1);
        oferta.resgatarCotas();
        assertTrue(oferta.cotasResgatadas(investidor1));
    }

    function test_Pausar_DoesNotBlockLiberarParaEmissor() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(agente);
        oferta.pausar();

        oferta.liberarParaEmissor();
        assertTrue(oferta.recursosLiberados());
    }

    // ── Views ───────────────────────────────────────────────────────────────────────────

    function test_CapacidadeRestante() public {
        vm.prank(investidor1);
        oferta.aportar(1_000 ether);
        assertEq(oferta.capacidadeRestante(), META_MAXIMA - 1_000 ether);
    }

    function test_CotasDe() public {
        vm.prank(investidor1);
        oferta.aportar(1_000 ether);
        assertEq(oferta.cotasDe(investidor1), (1_000 ether / PRECO_POR_COTA) * 1 ether);
    }
}
