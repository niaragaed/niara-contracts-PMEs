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
    address public agent = makeAddr("agente");
    address public stranger = makeAddr("estranho");
    address public emissorWallet = makeAddr("emissorWallet");
    address public protocoloWallet = makeAddr("protocoloWallet");
    address public investor1 = makeAddr("investidor1");
    address public investor2 = makeAddr("investidor2");

    uint256 public constant TIMELOCK_DELAY = 1 hours;

    uint256 public constant MIN_TARGET = 10_000 ether;
    uint256 public constant MAX_TARGET = 50_000 ether;
    uint256 public constant PRICE_PER_SHARE = 100 ether;
    uint256 public constant PER_INVESTOR_CAP = 20_000 ether;
    uint256 public constant FEE_BPS = 50; // 0.5%
    uint256 public prazo;

    function setUp() public {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        moeda = new MockBRL();

        _grantRole(address(gateway), gateway.AGENTE_ROLE(), agent);
        _grantRole(address(registro), registro.AGENTE_ROLE(), agent);

        DenyAllTransferPolicy policy = new DenyAllTransferPolicy();
        ParticipacaoToken tokenImpl = new ParticipacaoToken();
        token = ParticipacaoToken(Clones.clone(address(tokenImpl)));
        token.initialize("Oferta X", "nX", address(gateway), address(policy), "Empresa X", bytes32(0), "2026-A");

        vm.prank(agent);
        gateway.atestarCotas(address(token), (MAX_TARGET / PRICE_PER_SHARE) * 1 ether);

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
                metaMinima: MIN_TARGET,
                metaMaxima: MAX_TARGET,
                precoPorCota: PRICE_PER_SHARE,
                prazo: prazo,
                tetoPorInvestidor: PER_INVESTOR_CAP,
                taxaBps: FEE_BPS
            })
        );

        vm.prank(agent);
        gateway.registrarCaptacao(address(token), address(oferta));

        moeda.mint(investor1, 1_000_000 ether);
        moeda.mint(investor2, 1_000_000 ether);
        vm.prank(investor1);
        moeda.approve(address(oferta), type(uint256).max);
        vm.prank(investor2);
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
            metaMinima: MIN_TARGET,
            metaMaxima: MAX_TARGET,
            precoPorCota: PRICE_PER_SHARE,
            prazo: prazo,
            tetoPorInvestidor: PER_INVESTOR_CAP,
            taxaBps: FEE_BPS
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

    function test_Initialize_RevertsForZeroMinTarget() public {
        OfertaCaptacao clone = _newClone();
        IOfertaCaptacao.InitParams memory p = _defaultParams();
        p.metaMinima = 0;
        vm.expectRevert(abi.encodeWithSelector(OfertaCaptacao.MetasInvalidas.selector, 0, MAX_TARGET));
        clone.initialize(p);
    }

    function test_Initialize_RevertsForMinTargetAboveMax() public {
        OfertaCaptacao clone = _newClone();
        IOfertaCaptacao.InitParams memory p = _defaultParams();
        p.metaMinima = MAX_TARGET + 1;
        vm.expectRevert(abi.encodeWithSelector(OfertaCaptacao.MetasInvalidas.selector, MAX_TARGET + 1, MAX_TARGET));
        clone.initialize(p);
    }

    function test_Initialize_RevertsForZeroPreco() public {
        OfertaCaptacao clone = _newClone();
        IOfertaCaptacao.InitParams memory p = _defaultParams();
        p.precoPorCota = 0;
        vm.expectRevert(OfertaCaptacao.PrecoInvalido.selector);
        clone.initialize(p);
    }

    function test_Initialize_RevertsForPastDeadline() public {
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
        vm.prank(investor1);
        oferta.aportar(1_000 ether);

        assertEq(oferta.totalArrecadado(), 1_000 ether);
        assertEq(oferta.aportadoPor(investor1), 1_000 ether);
        assertEq(moeda.balanceOf(address(oferta)), 1_000 ether);
    }

    function test_Aportar_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(oferta));
        emit OfertaCaptacao.Aporte(investor1, 1_000 ether, 1_000 ether);
        vm.prank(investor1);
        oferta.aportar(1_000 ether);
    }

    function test_Aportar_RevertsForNonMultipleOfPreco() public {
        vm.prank(investor1);
        vm.expectRevert(
            abi.encodeWithSelector(OfertaCaptacao.AporteNaoMultiploDoPreco.selector, 150 ether, PRICE_PER_SHARE)
        );
        oferta.aportar(150 ether);
    }

    function test_Aportar_RevertsForZeroValor() public {
        vm.prank(investor1);
        vm.expectRevert(abi.encodeWithSelector(OfertaCaptacao.AporteNaoMultiploDoPreco.selector, 0, PRICE_PER_SHARE));
        oferta.aportar(0);
    }

    function test_Aportar_RevertsBeyondMaxTarget() public {
        vm.prank(investor1);
        vm.expectRevert(
            abi.encodeWithSelector(OfertaCaptacao.ExcedeMetaMaxima.selector, MAX_TARGET + PRICE_PER_SHARE, MAX_TARGET)
        );
        oferta.aportar(MAX_TARGET + PRICE_PER_SHARE);
    }

    function test_Aportar_RevertsBeyondPerInvestorCapForNonQualified() public {
        vm.prank(investor1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OfertaCaptacao.ExcedeTetoInvestidor.selector, PER_INVESTOR_CAP + PRICE_PER_SHARE, PER_INVESTOR_CAP
            )
        );
        oferta.aportar(PER_INVESTOR_CAP + PRICE_PER_SHARE);
    }

    function test_Aportar_QualifiedInvestorBypassesCap() public {
        vm.prank(agent);
        registro.definirQualificado(investor1, true);

        vm.prank(investor1);
        oferta.aportar(PER_INVESTOR_CAP + PRICE_PER_SHARE);

        assertEq(oferta.aportadoPor(investor1), PER_INVESTOR_CAP + PRICE_PER_SHARE);
    }

    function test_Aportar_RevertsAfterDeadline() public {
        vm.warp(prazo);
        vm.prank(investor1);
        vm.expectRevert(OfertaCaptacao.PrazoExpirado.selector);
        oferta.aportar(1_000 ether);
    }

    function test_Aportar_RevertsWhenNotAberta() public {
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(investor1);
        vm.expectRevert(OfertaCaptacao.OfertaNaoAberta.selector);
        oferta.aportar(1_000 ether);
    }

    function test_Aportar_RevertsWhenPaused() public {
        vm.prank(agent);
        oferta.pausar();

        vm.prank(investor1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        oferta.aportar(1_000 ether);
    }

    function test_Aportar_MultipleInvestorsAccumulate() public {
        vm.prank(investor1);
        oferta.aportar(1_000 ether);
        vm.prank(investor2);
        oferta.aportar(2_000 ether);

        assertEq(oferta.totalArrecadado(), 3_000 ether);
    }

    // ── encerrar ────────────────────────────────────────────────────────────────────────

    function test_Encerrar_RevertsBeforeDeadlineAndBelowMaxTarget() public {
        vm.prank(investor1);
        oferta.aportar(1_000 ether);

        vm.expectRevert(OfertaCaptacao.EncerramentoPrematuro.selector);
        oferta.encerrar();
    }

    function test_Encerrar_SuccessAtOrAboveMinTargetAfterDeadline() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);

        vm.warp(prazo);
        oferta.encerrar();

        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.EncerradaSucesso));
    }

    function test_Encerrar_FailureBelowMinTargetAfterDeadline() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET - PRICE_PER_SHARE);

        vm.warp(prazo);
        oferta.encerrar();

        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.EncerradaFalha));
    }

    function test_Encerrar_EarlyCloseAtMaxTarget() public {
        vm.prank(agent);
        registro.definirQualificado(investor1, true);
        vm.prank(investor1);
        oferta.aportar(MAX_TARGET);

        // still before the deadline, but it reached the maximum target, so closing must be allowed.
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
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);
        vm.warp(prazo);

        vm.expectEmit(true, true, true, true, address(oferta));
        emit OfertaCaptacao.OfertaEncerrada(OfertaCaptacao.Estado.EncerradaSucesso, MIN_TARGET);
        oferta.encerrar();
    }

    function test_Encerrar_IsPermissionless() public {
        vm.warp(prazo);
        vm.prank(stranger);
        oferta.encerrar();
        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.EncerradaFalha));
    }

    // ── cancelar ────────────────────────────────────────────────────────────────────────

    function test_Cancelar_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert(OfertaCaptacao.NaoAutorizado.selector);
        oferta.cancelar();
    }

    function test_Cancelar_MovesToClosedFailure() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);

        vm.prank(agent);
        oferta.cancelar();

        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.EncerradaFalha));
    }

    function test_Cancelar_RevertsWhenNotAberta() public {
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(agent);
        vm.expectRevert(OfertaCaptacao.OfertaNaoAberta.selector);
        oferta.cancelar();
    }

    function test_Cancelar_AllowsRefundAfterward() public {
        vm.prank(investor1);
        oferta.aportar(1_000 ether);

        vm.prank(agent);
        oferta.cancelar();

        vm.prank(investor1);
        oferta.reembolsar();
        assertEq(moeda.balanceOf(investor1), 1_000_000 ether);
    }

    // ── resgatarCotas ───────────────────────────────────────────────────────────────────

    function test_ResgatarCotas_RevertsBeforeSuccess() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);

        vm.prank(investor1);
        vm.expectRevert(OfertaCaptacao.OfertaNaoEncerradaComSucesso.selector);
        oferta.resgatarCotas();
    }

    function test_ResgatarCotas_MintsProportionalCotas() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(investor1);
        oferta.resgatarCotas();

        assertEq(token.balanceOf(investor1), (MIN_TARGET / PRICE_PER_SHARE) * 1 ether);
    }

    function test_ResgatarCotas_RevertsOnSecondCall() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(investor1);
        oferta.resgatarCotas();

        vm.prank(investor1);
        vm.expectRevert(OfertaCaptacao.JaResgatado.selector);
        oferta.resgatarCotas();
    }

    function test_ResgatarCotas_RevertsForNonContributor() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(stranger);
        vm.expectRevert(OfertaCaptacao.NadaAResgatar.selector);
        oferta.resgatarCotas();
    }

    function test_ResgatarCotas_EmitsEvent() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);
        vm.warp(prazo);
        oferta.encerrar();

        vm.expectEmit(true, true, true, true, address(oferta));
        emit OfertaCaptacao.CotasResgatadas(investor1, (MIN_TARGET / PRICE_PER_SHARE) * 1 ether);
        vm.prank(investor1);
        oferta.resgatarCotas();
    }

    function test_ResgatarCotas_IndependentAcrossInvestors() public {
        vm.prank(investor1);
        oferta.aportar(4_000 ether);
        vm.prank(investor2);
        oferta.aportar(MIN_TARGET);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(investor1);
        oferta.resgatarCotas();

        assertEq(token.balanceOf(investor1), (4_000 ether / PRICE_PER_SHARE) * 1 ether);
        assertEq(token.balanceOf(investor2), 0);
        assertFalse(oferta.cotasResgatadas(investor2));
    }

    // ── liberarParaEmissor ──────────────────────────────────────────────────────────────

    function test_LiberarParaEmissor_RevertsBeforeSuccess() public {
        vm.expectRevert(OfertaCaptacao.OfertaNaoEncerradaComSucesso.selector);
        oferta.liberarParaEmissor();
    }

    function test_LiberarParaEmissor_SplitsFeeAndPrincipal() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);
        vm.warp(prazo);
        oferta.encerrar();

        oferta.liberarParaEmissor();

        uint256 expectedFee = (MIN_TARGET * FEE_BPS) / 10_000;
        assertEq(moeda.balanceOf(protocoloWallet), expectedFee);
        assertEq(moeda.balanceOf(emissorWallet), MIN_TARGET - expectedFee);
    }

    function test_LiberarParaEmissor_ZeroFeeSendsEverythingToIssuer() public {
        OfertaCaptacao clone = _newClone();
        IOfertaCaptacao.InitParams memory p = _defaultParams();
        p.taxaBps = 0;
        clone.initialize(p);
        vm.prank(agent);
        gateway.registrarCaptacao(address(token), address(clone));

        vm.prank(investor1);
        moeda.approve(address(clone), type(uint256).max);
        vm.prank(investor1);
        clone.aportar(MIN_TARGET);
        vm.warp(prazo);
        clone.encerrar();

        clone.liberarParaEmissor();

        assertEq(moeda.balanceOf(protocoloWallet), 0);
        assertEq(moeda.balanceOf(emissorWallet), MIN_TARGET);
    }

    function test_LiberarParaEmissor_RevertsOnSecondCall() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);
        vm.warp(prazo);
        oferta.encerrar();

        oferta.liberarParaEmissor();

        vm.expectRevert(OfertaCaptacao.RecursosJaLiberados.selector);
        oferta.liberarParaEmissor();
    }

    function test_LiberarParaEmissor_IsPermissionless() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(stranger);
        oferta.liberarParaEmissor();

        assertTrue(oferta.recursosLiberados());
    }

    function test_LiberarParaEmissor_EmitsEvent() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);
        vm.warp(prazo);
        oferta.encerrar();

        uint256 expectedFee = (MIN_TARGET * FEE_BPS) / 10_000;
        vm.expectEmit(true, true, true, true, address(oferta));
        emit OfertaCaptacao.RecursosLiberados(emissorWallet, MIN_TARGET - expectedFee, protocoloWallet, expectedFee);
        oferta.liberarParaEmissor();
    }

    function test_LiberarParaEmissor_DrainsEscrowRegardlessOfPendingRedemptions() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);
        vm.warp(prazo);
        oferta.encerrar();

        oferta.liberarParaEmissor();

        assertEq(moeda.balanceOf(address(oferta)), 0);
    }

    // ── reembolsar ──────────────────────────────────────────────────────────────────────

    function test_Reembolsar_RevertsBeforeFailure() public {
        vm.prank(investor1);
        oferta.aportar(1_000 ether);

        vm.prank(investor1);
        vm.expectRevert(OfertaCaptacao.OfertaNaoEncerradaComFalha.selector);
        oferta.reembolsar();
    }

    function test_Reembolsar_ReturnsExactContribution() public {
        vm.prank(investor1);
        oferta.aportar(1_000 ether);
        vm.warp(prazo);
        oferta.encerrar();

        uint256 balanceBefore = moeda.balanceOf(investor1);
        vm.prank(investor1);
        oferta.reembolsar();

        assertEq(moeda.balanceOf(investor1), balanceBefore + 1_000 ether);
    }

    function test_Reembolsar_RevertsOnSecondCall() public {
        vm.prank(investor1);
        oferta.aportar(1_000 ether);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(investor1);
        oferta.reembolsar();

        vm.prank(investor1);
        vm.expectRevert(OfertaCaptacao.JaReembolsado.selector);
        oferta.reembolsar();
    }

    function test_Reembolsar_RevertsForNonContributor() public {
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(stranger);
        vm.expectRevert(OfertaCaptacao.NadaAReembolsar.selector);
        oferta.reembolsar();
    }

    function test_Reembolsar_EmitsEvent() public {
        vm.prank(investor1);
        oferta.aportar(1_000 ether);
        vm.warp(prazo);
        oferta.encerrar();

        vm.expectEmit(true, true, true, true, address(oferta));
        emit OfertaCaptacao.Reembolso(investor1, 1_000 ether);
        vm.prank(investor1);
        oferta.reembolsar();
    }

    function test_Reembolsar_IndependentAcrossInvestors() public {
        vm.prank(investor1);
        oferta.aportar(1_000 ether);
        vm.prank(investor2);
        oferta.aportar(2_000 ether);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(investor1);
        oferta.reembolsar();

        assertTrue(oferta.reembolsado(investor1));
        assertFalse(oferta.reembolsado(investor2));
        assertEq(moeda.balanceOf(address(oferta)), 2_000 ether);
    }

    // ── pausar / despausar ──────────────────────────────────────────────────────────────

    function test_Pausar_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert(OfertaCaptacao.NaoAutorizado.selector);
        oferta.pausar();
    }

    function test_Despausar_ReenablesAporte() public {
        vm.prank(agent);
        oferta.pausar();
        vm.prank(agent);
        oferta.despausar();

        vm.prank(investor1);
        oferta.aportar(1_000 ether);
        assertEq(oferta.totalArrecadado(), 1_000 ether);
    }

    function test_Pausar_DoesNotBlockReembolso() public {
        vm.prank(investor1);
        oferta.aportar(1_000 ether);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(agent);
        oferta.pausar();

        vm.prank(investor1);
        oferta.reembolsar();
        assertTrue(oferta.reembolsado(investor1));
    }

    function test_Pausar_DoesNotBlockResgatarCotas() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(agent);
        oferta.pausar();

        vm.prank(investor1);
        oferta.resgatarCotas();
        assertTrue(oferta.cotasResgatadas(investor1));
    }

    function test_Pausar_DoesNotBlockLiberarParaEmissor() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);
        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(agent);
        oferta.pausar();

        oferta.liberarParaEmissor();
        assertTrue(oferta.recursosLiberados());
    }

    // ── Views ───────────────────────────────────────────────────────────────────────────

    function test_CapacidadeRestante() public {
        vm.prank(investor1);
        oferta.aportar(1_000 ether);
        assertEq(oferta.capacidadeRestante(), MAX_TARGET - 1_000 ether);
    }

    function test_CotasDe() public {
        vm.prank(investor1);
        oferta.aportar(1_000 ether);
        assertEq(oferta.cotasDe(investor1), (1_000 ether / PRICE_PER_SHARE) * 1 ether);
    }
}
