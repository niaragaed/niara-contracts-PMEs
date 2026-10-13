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

/// @notice Intermediate contract used to prove that `emissorWallet` is always whoever last
/// called `criarOfertaCompleta`: the function has no parameter to "pass through" another
/// address, so even an authorized relayer can only record itself as the issuer.
contract IssuerRelay {
    OfertaOrquestrador public orq;

    constructor(OfertaOrquestrador orq_) {
        orq = orq_;
    }

    function create(
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
    OfertaCaptacao public offeringImpl;
    OfertaCaptacaoFactory public captacaoFactory;
    RegistroInvestidorQualificado public registro;
    DenyAllTransferPolicy public policy;
    MockBRL public moeda;
    OfertaOrquestrador public orq;

    address public admin = makeAddr("admin");
    address public platformAgent = makeAddr("agentePlataforma");
    address public orchestratorAgent = makeAddr("agenteOrq");
    address public issuer1 = makeAddr("emissor1");
    address public issuer2 = makeAddr("emissor2");
    address public stranger = makeAddr("estranho");
    address public protocoloWallet = makeAddr("protocoloWallet");
    address public investor1 = makeAddr("investidor1");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    uint256 public constant INITIAL_FEE_BPS = 0;
    uint256 public constant INITIAL_PER_INVESTOR_CAP = 1_000_000 ether;

    string public constant NAME = "Oferta Teste";
    string public constant SYMBOL = "nTST";
    string public constant COMPANY = "Empresa Teste Ltda";
    bytes32 public constant CNPJ_REF = keccak256("12.345.678/0001-99");
    string public constant SERIES = "2026-A";

    // Valid "default" values for tests that are not testing a specific limit:
    // metaMinima=800, metaMaxima=1000 (exactly 125% -> passes the additional-lot check),
    // precoPorCota=100 (1000 % 100 == 0 -> 10 shares).
    uint256 public constant DEFAULT_MIN_TARGET = 800 ether;
    uint256 public constant DEFAULT_MAX_TARGET = 1000 ether;
    uint256 public constant DEFAULT_PRICE_PER_SHARE = 100 ether;

    function setUp() public {
        tokenImpl = new ParticipacaoToken();
        policy = new DenyAllTransferPolicy();
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        tokenFactory =
            new ParticipacaoTokenFactory(admin, address(tokenImpl), address(gateway), address(policy), TIMELOCK_DELAY);

        registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        moeda = new MockBRL();
        offeringImpl = new OfertaCaptacao();
        captacaoFactory = new OfertaCaptacaoFactory(
            admin, address(offeringImpl), address(gateway), address(registro), address(moeda), TIMELOCK_DELAY
        );

        orq = new OfertaOrquestrador(
            admin,
            address(tokenFactory),
            address(gateway),
            address(captacaoFactory),
            protocoloWallet,
            INITIAL_FEE_BPS,
            INITIAL_PER_INVESTOR_CAP,
            TIMELOCK_DELAY
        );

        // The orchestrator's AGENTE_ROLE on the 3 target contracts (see PLANO_OFERTA_ORQUESTRADOR.md).
        _grantRole(address(tokenFactory), tokenFactory.AGENTE_ROLE(), address(orq));
        _grantRole(address(gateway), gateway.AGENTE_ROLE(), address(orq));
        _grantRole(address(captacaoFactory), captacaoFactory.AGENTE_ROLE(), address(orq));

        // AGENTE_ROLE for a human/script on the real infra too, for manual actions used in the
        // tests (e.g. cancelar() on a fundraising to simulate "closed with failure").
        _grantRole(address(gateway), gateway.AGENTE_ROLE(), platformAgent);

        // The orchestrator's own AGENTE_ROLE (allowlist/pause).
        _grantRole(address(orq), orq.AGENTE_ROLE(), orchestratorAgent);

        vm.prank(orchestratorAgent);
        orq.autorizarEmissor(issuer1);
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

    function _validDeadline() internal view returns (uint256) {
        return block.timestamp + 90 days;
    }

    function _createDefaultOffering(address emissor) internal returns (address token, address oferta) {
        vm.prank(emissor);
        return orq.criarOfertaCompleta(
            NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, DEFAULT_MIN_TARGET, DEFAULT_MAX_TARGET, DEFAULT_PRICE_PER_SHARE, _validDeadline()
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
            INITIAL_FEE_BPS,
            INITIAL_PER_INVESTOR_CAP,
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
            INITIAL_FEE_BPS,
            INITIAL_PER_INVESTOR_CAP,
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
            INITIAL_FEE_BPS,
            INITIAL_PER_INVESTOR_CAP,
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
            INITIAL_FEE_BPS,
            INITIAL_PER_INVESTOR_CAP,
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
            INITIAL_FEE_BPS,
            INITIAL_PER_INVESTOR_CAP,
            TIMELOCK_DELAY
        );
    }

    function test_Constructor_RevertsForFeeBpsAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.TaxaExcedeMaximo.selector, 101, 100));
        new OfertaOrquestrador(
            admin,
            address(tokenFactory),
            address(gateway),
            address(captacaoFactory),
            protocoloWallet,
            101,
            INITIAL_PER_INVESTOR_CAP,
            TIMELOCK_DELAY
        );
    }

    function test_Constructor_SetsState() public view {
        assertEq(orq.tokenFactory(), address(tokenFactory));
        assertEq(orq.emissaoGateway(), address(gateway));
        assertEq(orq.captacaoFactory(), address(captacaoFactory));
        assertEq(orq.protocoloWallet(), protocoloWallet);
        assertEq(orq.taxaBps(), INITIAL_FEE_BPS);
        assertEq(orq.tetoPorInvestidor(), INITIAL_PER_INVESTOR_CAP);
        assertTrue(orq.hasRole(orq.DEFAULT_ADMIN_ROLE(), admin));
    }

    // ── Allowlist ───────────────────────────────────────────────────────────────────────────

    function test_AutorizarEmissor_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert();
        orq.autorizarEmissor(issuer2);
    }

    function test_AutorizarEmissor_RevertsForZeroAddress() public {
        vm.prank(orchestratorAgent);
        vm.expectRevert(OfertaOrquestrador.ZeroAddress.selector);
        orq.autorizarEmissor(address(0));
    }

    function test_RevogarEmissor_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert();
        orq.revogarEmissor(issuer1);
    }

    function test_CriarOfertaCompleta_RevertsForUnauthorizedIssuer() public {
        vm.prank(issuer2);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.EmissorNaoAutorizado.selector, issuer2));
        orq.criarOfertaCompleta(
            NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, DEFAULT_MIN_TARGET, DEFAULT_MAX_TARGET, DEFAULT_PRICE_PER_SHARE, _validDeadline()
        );
    }

    function test_CriarOfertaCompleta_RevertsAfterRevocation() public {
        _createDefaultOffering(issuer1);

        vm.prank(orchestratorAgent);
        orq.revogarEmissor(issuer1);

        vm.prank(issuer1);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.EmissorNaoAutorizado.selector, issuer1));
        orq.criarOfertaCompleta(
            NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, DEFAULT_MIN_TARGET, DEFAULT_MAX_TARGET, DEFAULT_PRICE_PER_SHARE, _validDeadline()
        );
    }

    // ── Limites Res. CVM 88 — boundary exato ───────────────────────────────────────────────

    function test_CriarOfertaCompleta_DeadlineExactly180Days_Succeeds() public {
        uint256 prazo = block.timestamp + 180 days;
        vm.prank(issuer1);
        (address token, address oferta) = orq.criarOfertaCompleta(
            NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, DEFAULT_MIN_TARGET, DEFAULT_MAX_TARGET, DEFAULT_PRICE_PER_SHARE, prazo
        );
        assertTrue(tokenFactory.isOferta(token));
        assertTrue(captacaoFactory.isCaptacao(oferta));
    }

    function test_CriarOfertaCompleta_Deadline180DaysPlusOneSecond_Reverts() public {
        uint256 prazo = block.timestamp + 180 days + 1;
        vm.prank(issuer1);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.PrazoExcedeLimite.selector, prazo, 180 days));
        orq.criarOfertaCompleta(
            NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, DEFAULT_MIN_TARGET, DEFAULT_MAX_TARGET, DEFAULT_PRICE_PER_SHARE, prazo
        );
    }

    function test_CriarOfertaCompleta_RevertsForDeadlineInPastOrPresent() public {
        vm.prank(issuer1);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.PrazoInvalido.selector, block.timestamp));
        orq.criarOfertaCompleta(
            NAME,
            SYMBOL,
            COMPANY,
            CNPJ_REF,
            SERIES,
            DEFAULT_MIN_TARGET,
            DEFAULT_MAX_TARGET,
            DEFAULT_PRICE_PER_SHARE,
            block.timestamp
        );
    }

    function test_CriarOfertaCompleta_MaxTargetExactlyAtCap_Succeeds() public {
        uint256 metaMaxima = orq.TETO_OFERTA(); // 15_000_000 ether
        uint256 metaMinima = 12_000_000 ether; // metaMaxima*100 == metaMinima*125, exato
        uint256 precoPorCota = 1_000_000 ether; // 15_000_000 % 1_000_000 == 0

        vm.prank(issuer1);
        (address token,) =
            orq.criarOfertaCompleta(NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, metaMinima, metaMaxima, precoPorCota, _validDeadline());
        assertEq(ParticipacaoToken(token).cotasAutorizadas(), 15 ether);
    }

    function test_CriarOfertaCompleta_MaxTargetExceedsCapByOneWei_Reverts() public {
        uint256 teto = orq.TETO_OFERTA();
        uint256 metaMaxima = teto + 1;
        uint256 metaMinima = 12_000_000 ether;

        vm.prank(issuer1);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.MetaMaximaExcedeTeto.selector, metaMaxima, teto));
        orq.criarOfertaCompleta(
            NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, metaMinima, metaMaxima, 1_000_000 ether, _validDeadline()
        );
    }

    function test_CriarOfertaCompleta_AdditionalLotExactly125Percent_Succeeds() public {
        // META_MAXIMA_PADRAO * 100 == META_MINIMA_PADRAO * 125 (1000*100 == 800*125 == 100_000)
        (address token, address oferta) = _createDefaultOffering(issuer1);
        assertTrue(tokenFactory.isOferta(token));
        assertTrue(captacaoFactory.isCaptacao(oferta));
    }

    function test_CriarOfertaCompleta_AdditionalLotExceeds125PercentByOneWei_Reverts() public {
        uint256 metaMinima = DEFAULT_MIN_TARGET; // 800 ether
        uint256 metaMaxima = DEFAULT_MAX_TARGET + 1; // 1000 ether + 1 wei

        vm.prank(issuer1);
        vm.expectRevert(
            abi.encodeWithSelector(OfertaOrquestrador.LoteAdicionalExcedeLimite.selector, metaMaxima, metaMinima)
        );
        orq.criarOfertaCompleta(
            NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, metaMinima, metaMaxima, DEFAULT_PRICE_PER_SHARE, _validDeadline()
        );
    }

    // ── Arithmetic / derivation ─────────────────────────────────────────────────────────────

    function test_CriarOfertaCompleta_RevertsForZeroPricePerShare_WithNamedError() public {
        vm.prank(issuer1);
        vm.expectRevert(OfertaOrquestrador.PrecoInvalido.selector);
        orq.criarOfertaCompleta(
            NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, DEFAULT_MIN_TARGET, DEFAULT_MAX_TARGET, 0, _validDeadline()
        );
    }

    function test_CriarOfertaCompleta_RevertsForMaxTargetNotMultipleOfPrice() public {
        uint256 precoPorCota = 300 ether; // 1000 % 300 != 0
        vm.prank(issuer1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OfertaOrquestrador.PrecoNaoDivideMetaMaxima.selector, DEFAULT_MAX_TARGET, precoPorCota
            )
        );
        orq.criarOfertaCompleta(
            NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, DEFAULT_MIN_TARGET, DEFAULT_MAX_TARGET, precoPorCota, _validDeadline()
        );
    }

    function test_CriarOfertaCompleta_AuthorizedSharesDerivedCorrectly() public {
        (address token,) = _createDefaultOffering(issuer1);
        // metaMaxima/precoPorCota = 1000/100 = 10 shares -> 10 ether in raw units.
        assertEq(ParticipacaoToken(token).cotasAutorizadas(), 10 ether);
    }

    // ── Anti-manipulation ───────────────────────────────────────────────────────────────────

    function test_CriarOfertaCompleta_IssuerWalletIsAlwaysMsgSender() public {
        (, address oferta) = _createDefaultOffering(issuer1);
        assertEq(OfertaCaptacao(oferta).emissorWallet(), issuer1);
    }

    function test_CriarOfertaCompleta_IssuerWalletIsAlwaysMsgSender_EvenViaIntermediaryContract() public {
        IssuerRelay relay = new IssuerRelay(orq);

        vm.prank(orchestratorAgent);
        orq.autorizarEmissor(address(relay));

        (, address oferta) = relay.create(
            NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, DEFAULT_MIN_TARGET, DEFAULT_MAX_TARGET, DEFAULT_PRICE_PER_SHARE, _validDeadline()
        );

        // `criarOfertaCompleta` has no parameter to "pass through" another issuer: even an
        // authorized relayer can only record itself, never a third party.
        assertEq(OfertaCaptacao(oferta).emissorWallet(), address(relay));
    }

    function test_CriarOfertaCompleta_FeeBpsAndProtocolWalletComeFromOrchestratorStorage() public {
        (, address oferta) = _createDefaultOffering(issuer1);
        assertEq(OfertaCaptacao(oferta).taxaBps(), INITIAL_FEE_BPS);
        assertEq(OfertaCaptacao(oferta).protocoloWallet(), protocoloWallet);
        assertEq(OfertaCaptacao(oferta).tetoPorInvestidor(), INITIAL_PER_INVESTOR_CAP);
    }

    function test_CriarOfertaCompleta_ParameterChangeOnlyAffectsFutureOfferings() public {
        (, address oldOffering) = _createDefaultOffering(issuer1);

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

        // Closes the old offering (failure) so the same issuer can open a second one.
        vm.prank(platformAgent);
        OfertaCaptacao(oldOffering).cancelar();

        (, address newOffering) = _createDefaultOffering(issuer1);

        // The old one kept the parameters in effect when it was created.
        assertEq(OfertaCaptacao(oldOffering).taxaBps(), INITIAL_FEE_BPS);
        assertEq(OfertaCaptacao(oldOffering).protocoloWallet(), protocoloWallet);
        // The new one reflects the parameters in effect now.
        assertEq(OfertaCaptacao(newOffering).taxaBps(), 50);
        assertEq(OfertaCaptacao(newOffering).protocoloWallet(), novoProtocoloWallet);
    }

    // ── One open offering at a time ─────────────────────────────────────────────────────────

    function test_CriarOfertaCompleta_RevertsIfPreviousStillOpen() public {
        (, address ofertaAnterior) = _createDefaultOffering(issuer1);

        vm.prank(issuer1);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.OfertaAnteriorAindaAberta.selector, ofertaAnterior));
        orq.criarOfertaCompleta(
            NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, DEFAULT_MIN_TARGET, DEFAULT_MAX_TARGET, DEFAULT_PRICE_PER_SHARE, _validDeadline()
        );
    }

    function test_CriarOfertaCompleta_AllowsSecondAfterClosedWithFailure() public {
        (, address ofertaAnterior) = _createDefaultOffering(issuer1);

        vm.prank(platformAgent);
        OfertaCaptacao(ofertaAnterior).cancelar();
        assertEq(uint256(OfertaCaptacao(ofertaAnterior).estado()), uint256(OfertaCaptacao.Estado.EncerradaFalha));

        (address token2, address offering2) = _createDefaultOffering(issuer1);
        assertTrue(tokenFactory.isOferta(token2));
        assertTrue(captacaoFactory.isCaptacao(offering2));
        assertEq(orq.numOfertasDoEmissor(issuer1), 2);
    }

    function test_CriarOfertaCompleta_AllowsSecondAfterClosedWithSuccess() public {
        // metaMinima == metaMaxima to allow encerrar() before the deadline (fully subscribed).
        uint256 target = 1000 ether;
        uint256 precoPorCota = 100 ether;

        vm.prank(issuer1);
        (, address ofertaAnterior) =
            orq.criarOfertaCompleta(NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, target, target, precoPorCota, _validDeadline());

        moeda.mint(investor1, target);
        vm.prank(investor1);
        moeda.approve(ofertaAnterior, target);
        vm.prank(investor1);
        OfertaCaptacao(ofertaAnterior).aportar(target);

        OfertaCaptacao(ofertaAnterior).encerrar();
        assertEq(uint256(OfertaCaptacao(ofertaAnterior).estado()), uint256(OfertaCaptacao.Estado.EncerradaSucesso));

        (, address offering2) = _createDefaultOffering(issuer1);
        assertTrue(captacaoFactory.isCaptacao(offering2));
    }

    // ── Atomicidade ─────────────────────────────────────────────────────────────────────────

    function test_CriarOfertaCompleta_RevertsWithoutGrantedRoles_NoPartialState() public {
        OfertaOrquestrador orchestratorWithoutRole = new OfertaOrquestrador(
            admin,
            address(tokenFactory),
            address(gateway),
            address(captacaoFactory),
            protocoloWallet,
            INITIAL_FEE_BPS,
            INITIAL_PER_INVESTOR_CAP,
            TIMELOCK_DELAY
        );
        _grantRole(address(orchestratorWithoutRole), orchestratorWithoutRole.AGENTE_ROLE(), orchestratorAgent);
        vm.prank(orchestratorAgent);
        orchestratorWithoutRole.autorizarEmissor(issuer1);

        uint256 offeringCountBefore = tokenFactory.numOfertas();
        uint256 fundraisingCountBefore = captacaoFactory.numCaptacoes();

        vm.prank(issuer1);
        vm.expectRevert();
        orchestratorWithoutRole.criarOfertaCompleta(
            NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, DEFAULT_MIN_TARGET, DEFAULT_MAX_TARGET, DEFAULT_PRICE_PER_SHARE, _validDeadline()
        );

        assertEq(tokenFactory.numOfertas(), offeringCountBefore);
        assertEq(captacaoFactory.numCaptacoes(), fundraisingCountBefore);
        assertEq(orchestratorWithoutRole.numOfertasDoEmissor(issuer1), 0);
    }

    function test_CriarOfertaCompleta_RevertOnFourthCall_CreatesNothingAnywhere() public {
        MockEmissaoGatewayRevertaEmRegistrar mockGateway = new MockEmissaoGatewayRevertaEmRegistrar();

        OfertaOrquestrador atomicOrchestrator = new OfertaOrquestrador(
            admin,
            address(tokenFactory),
            address(mockGateway),
            address(captacaoFactory),
            protocoloWallet,
            INITIAL_FEE_BPS,
            INITIAL_PER_INVESTOR_CAP,
            TIMELOCK_DELAY
        );
        _grantRole(address(tokenFactory), tokenFactory.AGENTE_ROLE(), address(atomicOrchestrator));
        _grantRole(address(captacaoFactory), captacaoFactory.AGENTE_ROLE(), address(atomicOrchestrator));
        _grantRole(address(atomicOrchestrator), atomicOrchestrator.AGENTE_ROLE(), orchestratorAgent);

        vm.prank(orchestratorAgent);
        atomicOrchestrator.autorizarEmissor(issuer1);

        uint256 offeringCountBefore = tokenFactory.numOfertas();
        uint256 fundraisingCountBefore = captacaoFactory.numCaptacoes();

        // `Clones.clone` uses plain CREATE (not CREATE2): the address that WOULD have been created
        // in subcalls 1 and 3 is predictable from each factory's current nonce, even with the call
        // reverting before the end. Predicting both addresses here lets us check afterwards,
        // precisely (not only by aggregate count), that neither ended up in the respective
        // factory's registry (`isOferta`/`isCaptacao`).
        address predictedToken = vm.computeCreateAddress(address(tokenFactory), vm.getNonce(address(tokenFactory)));
        address predictedOffering =
            vm.computeCreateAddress(address(captacaoFactory), vm.getNonce(address(captacaoFactory)));

        vm.prank(issuer1);
        vm.expectRevert(MockEmissaoGatewayRevertaEmRegistrar.ForcedTestFailure.selector);
        atomicOrchestrator.criarOfertaCompleta(
            NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, DEFAULT_MIN_TARGET, DEFAULT_MAX_TARGET, DEFAULT_PRICE_PER_SHARE, _validDeadline()
        );

        // Neither the token nor the fundraising (created in subcalls 1 and 3, BEFORE the failure in
        // the 4th) persists: the EVM undoes everything atomically, including both `Clones.clone` calls.
        assertEq(tokenFactory.numOfertas(), offeringCountBefore);
        assertEq(captacaoFactory.numCaptacoes(), fundraisingCountBefore);
        assertEq(atomicOrchestrator.numOfertasDoEmissor(issuer1), 0);
        assertEq(atomicOrchestrator.ultimaOfertaDoEmissor(issuer1), address(0));

        // Precise reinforcement: neither the address the token clone WOULD have had nor the
        // fundraising's appears registered in the respective factories. It is not only the aggregate
        // count that stayed unchanged; the specific address was never written to `isOferta`/`isCaptacao`.
        assertFalse(tokenFactory.isOferta(predictedToken));
        assertFalse(captacaoFactory.isCaptacao(predictedOffering));
    }

    // ── Pausa ───────────────────────────────────────────────────────────────────────────────

    function test_Pause_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert();
        orq.pause();
    }

    function test_Pause_BlocksCriarOfertaCompleta() public {
        vm.prank(orchestratorAgent);
        orq.pause();

        vm.prank(issuer1);
        vm.expectRevert();
        orq.criarOfertaCompleta(
            NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, DEFAULT_MIN_TARGET, DEFAULT_MAX_TARGET, DEFAULT_PRICE_PER_SHARE, _validDeadline()
        );
    }

    function test_Pause_DoesNotAffectLiveOfferings() public {
        uint256 target = 1000 ether;
        uint256 precoPorCota = 100 ether;

        vm.prank(issuer1);
        (address token, address oferta) =
            orq.criarOfertaCompleta(NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, target, target, precoPorCota, _validDeadline());

        moeda.mint(investor1, target);
        vm.prank(investor1);
        moeda.approve(oferta, target);

        vm.prank(orchestratorAgent);
        orq.pause();

        // Investing, closing and redeeming keep working with the orchestrator paused: the
        // pause only turns off `criarOfertaCompleta`.
        vm.prank(investor1);
        OfertaCaptacao(oferta).aportar(target);

        OfertaCaptacao(oferta).encerrar();
        assertEq(uint256(OfertaCaptacao(oferta).estado()), uint256(OfertaCaptacao.Estado.EncerradaSucesso));

        vm.prank(investor1);
        OfertaCaptacao(oferta).resgatarCotas();
        assertEq(ParticipacaoToken(token).balanceOf(investor1), 10 ether);
    }

    function test_Unpause_OnlyAgent() public {
        vm.prank(orchestratorAgent);
        orq.pause();

        vm.prank(stranger);
        vm.expectRevert();
        orq.unpause();

        vm.prank(orchestratorAgent);
        orq.unpause();

        (address token,) = _createDefaultOffering(issuer1);
        assertTrue(tokenFactory.isOferta(token));
    }

    // ── Ciclo completo ponta a ponta ────────────────────────────────────────────────────────

    function test_FullCycle_CreateInvestCloseRedeem() public {
        uint256 target = 1000 ether;
        uint256 precoPorCota = 100 ether;

        vm.prank(issuer1);
        (address token, address oferta) =
            orq.criarOfertaCompleta(NAME, SYMBOL, COMPANY, CNPJ_REF, SERIES, target, target, precoPorCota, _validDeadline());

        moeda.mint(investor1, target);
        vm.prank(investor1);
        moeda.approve(oferta, target);
        vm.prank(investor1);
        OfertaCaptacao(oferta).aportar(target);

        OfertaCaptacao(oferta).encerrar();
        assertEq(uint256(OfertaCaptacao(oferta).estado()), uint256(OfertaCaptacao.Estado.EncerradaSucesso));

        vm.prank(investor1);
        OfertaCaptacao(oferta).resgatarCotas();

        // target/precoPorCota = 10 shares -> 10 ether in the token's raw units.
        assertEq(ParticipacaoToken(token).balanceOf(investor1), 10 ether);
    }

    // ── Governance of platform parameters (timelock) ───────────────────────────────────────

    function test_ProposeSetTaxaBps_OnlyDefaultAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        orq.proposeSetTaxaBps(50);
    }

    function test_ProposeSetTaxaBps_RevertsAboveMax() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.TaxaExcedeMaximo.selector, 101, 100));
        orq.proposeSetTaxaBps(101);
    }

    function test_ExecuteSetTaxaBps_RevertsAboveMax_EvenWhenCalledDirectly() public {
        // Same lesson already applied in LiquidacaoSecundaria.executeSetTaxaSecundarioBps: the cap
        // is also validated in execute, not only in propose.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OfertaOrquestrador.TaxaExcedeMaximo.selector, 101, 100));
        orq.executeSetTaxaBps(101);
    }

    function test_SetTaxaBps_RespectsTimelock() public {
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

    function test_SetProtocoloWallet_RespectsTimelockAndRejectsZeroAddress() public {
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

    function test_SetTetoPorInvestidor_RespectsTimelock() public {
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
        assertEq(orq.numOfertasDoEmissor(issuer1), 0);
        (, address oferta) = _createDefaultOffering(issuer1);
        assertEq(orq.numOfertasDoEmissor(issuer1), 1);
        assertEq(orq.ofertasPorEmissor(issuer1, 0), oferta);
        assertEq(orq.ultimaOfertaDoEmissor(issuer1), oferta);
    }
}
