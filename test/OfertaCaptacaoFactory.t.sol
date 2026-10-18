// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";
import {OfertaCaptacao} from "../src/captacao/OfertaCaptacao.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RegistroInvestidorQualificado} from "../src/registro/RegistroInvestidorQualificado.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";

contract OfertaCaptacaoFactoryTest is Test {
    OfertaCaptacaoFactory public factory;
    OfertaCaptacao public implementacao;
    EmissaoGateway public gateway;
    RegistroInvestidorQualificado public registro;
    MockBRL public moeda;
    ParticipacaoToken public token;

    address public admin = makeAddr("admin");
    address public agent = makeAddr("agente");
    address public stranger = makeAddr("estranho");
    address public emissorWallet = makeAddr("emissorWallet");
    address public protocoloWallet = makeAddr("protocoloWallet");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    bytes32 public agentRole;

    uint256 public constant MIN_TARGET = 10_000 ether;
    uint256 public constant MAX_TARGET = 50_000 ether;
    uint256 public constant PRICE_PER_SHARE = 1 ether;
    uint256 public constant PER_INVESTOR_CAP = 5_000 ether;
    uint256 public constant FEE_BPS = 50;

    function setUp() public {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        moeda = new MockBRL();
        implementacao = new OfertaCaptacao();

        factory = new OfertaCaptacaoFactory(
            admin, address(implementacao), address(gateway), address(registro), address(moeda), TIMELOCK_DELAY
        );
        agentRole = factory.AGENTE_ROLE();
        _grantRole(address(factory), agentRole, agent);
        _grantRole(address(gateway), gateway.AGENTE_ROLE(), agent);

        DenyAllTransferPolicy policy = new DenyAllTransferPolicy();
        ParticipacaoToken tokenImpl = new ParticipacaoToken();
        token = ParticipacaoToken(Clones.clone(address(tokenImpl)));
        token.initialize("Oferta X", "nX", address(gateway), address(policy), "Empresa X", bytes32(0), "2026-A");
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
        return block.timestamp + 30 days;
    }

    function _createFundraising() internal returns (address) {
        vm.prank(agent);
        return factory.criarCaptacao(
            address(token),
            MIN_TARGET,
            MAX_TARGET,
            PRICE_PER_SHARE,
            _validDeadline(),
            PER_INVESTOR_CAP,
            FEE_BPS,
            emissorWallet,
            protocoloWallet
        );
    }

    // ── Construtor ──────────────────────────────────────────────────────────────────────

    function test_Constructor_RevertsForZeroAdmin() public {
        vm.expectRevert(OfertaCaptacaoFactory.ZeroAddress.selector);
        new OfertaCaptacaoFactory(
            address(0), address(implementacao), address(gateway), address(registro), address(moeda), TIMELOCK_DELAY
        );
    }

    function test_Constructor_RevertsForZeroImplementacao() public {
        vm.expectRevert(OfertaCaptacaoFactory.ZeroAddress.selector);
        new OfertaCaptacaoFactory(
            admin, address(0), address(gateway), address(registro), address(moeda), TIMELOCK_DELAY
        );
    }

    function test_Constructor_RevertsForZeroGateway() public {
        vm.expectRevert(OfertaCaptacaoFactory.ZeroAddress.selector);
        new OfertaCaptacaoFactory(
            admin, address(implementacao), address(0), address(registro), address(moeda), TIMELOCK_DELAY
        );
    }

    function test_Constructor_RevertsForZeroRegistro() public {
        vm.expectRevert(OfertaCaptacaoFactory.ZeroAddress.selector);
        new OfertaCaptacaoFactory(
            admin, address(implementacao), address(gateway), address(0), address(moeda), TIMELOCK_DELAY
        );
    }

    function test_Constructor_RevertsForZeroMoeda() public {
        vm.expectRevert(OfertaCaptacaoFactory.ZeroAddress.selector);
        new OfertaCaptacaoFactory(
            admin, address(implementacao), address(gateway), address(registro), address(0), TIMELOCK_DELAY
        );
    }

    // ── criarCaptacao ───────────────────────────────────────────────────────────────────

    function test_CriarCaptacao_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agentRole)
        );
        factory.criarCaptacao(
            address(token),
            MIN_TARGET,
            MAX_TARGET,
            PRICE_PER_SHARE,
            _validDeadline(),
            PER_INVESTOR_CAP,
            FEE_BPS,
            emissorWallet,
            protocoloWallet
        );
    }

    function test_CriarCaptacao_ClonesAndInitializes() public {
        address offeringAddr = _createFundraising();
        OfertaCaptacao oferta = OfertaCaptacao(offeringAddr);

        assertEq(address(oferta.token()), address(token));
        assertEq(oferta.gateway(), address(gateway));
        assertEq(address(oferta.registro()), address(registro));
        assertEq(address(oferta.moeda()), address(moeda));
        assertEq(oferta.emissorWallet(), emissorWallet);
        assertEq(oferta.protocoloWallet(), protocoloWallet);
        assertEq(oferta.metaMinima(), MIN_TARGET);
        assertEq(oferta.metaMaxima(), MAX_TARGET);
        assertEq(oferta.precoPorCota(), PRICE_PER_SHARE);
        assertEq(oferta.tetoPorInvestidor(), PER_INVESTOR_CAP);
        assertEq(oferta.taxaBps(), FEE_BPS);
        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.Aberta));
    }

    function test_CriarCaptacao_RegistersCaptacao() public {
        address offeringAddr = _createFundraising();
        assertTrue(factory.isCaptacao(offeringAddr));
        assertEq(factory.numCaptacoes(), 1);
        assertEq(factory.captacoes(0), offeringAddr);
    }

    function test_CriarCaptacao_RevertsForZeroToken() public {
        vm.prank(agent);
        vm.expectRevert(OfertaCaptacaoFactory.ZeroAddress.selector);
        factory.criarCaptacao(
            address(0),
            MIN_TARGET,
            MAX_TARGET,
            PRICE_PER_SHARE,
            _validDeadline(),
            PER_INVESTOR_CAP,
            FEE_BPS,
            emissorWallet,
            protocoloWallet
        );
    }

    function test_CriarCaptacao_RevertsForMinTargetAboveMax() public {
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(OfertaCaptacaoFactory.MetasInvalidas.selector, MAX_TARGET + 1, MAX_TARGET)
        );
        factory.criarCaptacao(
            address(token),
            MAX_TARGET + 1,
            MAX_TARGET,
            PRICE_PER_SHARE,
            _validDeadline(),
            PER_INVESTOR_CAP,
            FEE_BPS,
            emissorWallet,
            protocoloWallet
        );
    }

    function test_CriarCaptacao_RevertsForZeroPreco() public {
        vm.prank(agent);
        vm.expectRevert(OfertaCaptacaoFactory.PrecoInvalido.selector);
        factory.criarCaptacao(
            address(token),
            MIN_TARGET,
            MAX_TARGET,
            0,
            _validDeadline(),
            PER_INVESTOR_CAP,
            FEE_BPS,
            emissorWallet,
            protocoloWallet
        );
    }

    function test_CriarCaptacao_RevertsForPastDeadline() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(OfertaCaptacaoFactory.PrazoInvalido.selector, block.timestamp));
        factory.criarCaptacao(
            address(token),
            MIN_TARGET,
            MAX_TARGET,
            PRICE_PER_SHARE,
            block.timestamp,
            PER_INVESTOR_CAP,
            FEE_BPS,
            emissorWallet,
            protocoloWallet
        );
    }

    function test_CriarCaptacao_RevertsForTaxaAboveMaximo() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(OfertaCaptacaoFactory.TaxaExcedeMaximo.selector, 101, 100));
        factory.criarCaptacao(
            address(token),
            MIN_TARGET,
            MAX_TARGET,
            PRICE_PER_SHARE,
            _validDeadline(),
            PER_INVESTOR_CAP,
            101,
            emissorWallet,
            protocoloWallet
        );
    }

    function test_CriarCaptacao_RevertsWhenPaused() public {
        vm.prank(agent);
        factory.pause();

        vm.prank(agent);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.criarCaptacao(
            address(token),
            MIN_TARGET,
            MAX_TARGET,
            PRICE_PER_SHARE,
            _validDeadline(),
            PER_INVESTOR_CAP,
            FEE_BPS,
            emissorWallet,
            protocoloWallet
        );
    }

    function test_CriarCaptacao_MultipleOffersAreIndependentClones() public {
        address offeringA = _createFundraising();
        address offeringB = _createFundraising();

        assertTrue(offeringA != offeringB);
        assertEq(factory.numCaptacoes(), 2);
    }

    // ── Pausa ───────────────────────────────────────────────────────────────────────────

    function test_Pause_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agentRole)
        );
        factory.pause();
    }

    function test_PauseUnpause_RoundTrip() public {
        vm.prank(agent);
        factory.pause();
        assertTrue(factory.paused());

        vm.prank(agent);
        factory.unpause();
        assertFalse(factory.paused());
    }

    // ── Implementation swap via timelock ────────────────────────────────────────────────

    function test_SetImplementacao_RequiresTimelock() public {
        OfertaCaptacao newImpl = new OfertaCaptacao();

        vm.prank(admin);
        factory.proposeSetImplementacao(address(newImpl));

        vm.prank(admin);
        vm.expectRevert();
        factory.executeSetImplementacao(address(newImpl));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        factory.executeSetImplementacao(address(newImpl));

        assertEq(factory.implementacao(), address(newImpl));
    }

    function test_SetImplementacao_OnlyAffectsFutureOffers() public {
        address oldOffering = _createFundraising();

        OfertaCaptacao newImpl = new OfertaCaptacao();
        vm.prank(admin);
        factory.proposeSetImplementacao(address(newImpl));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        factory.executeSetImplementacao(address(newImpl));

        address newOffering = _createFundraising();

        assertTrue(oldOffering != newOffering);
        assertEq(uint256(OfertaCaptacao(oldOffering).estado()), uint256(OfertaCaptacao.Estado.Aberta));
    }

    function test_SetImplementacao_RevertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(OfertaCaptacaoFactory.ZeroAddress.selector);
        factory.proposeSetImplementacao(address(0));
    }
}
