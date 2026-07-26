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
    address public agente = makeAddr("agente");
    address public estranho = makeAddr("estranho");
    address public emissorWallet = makeAddr("emissorWallet");
    address public protocoloWallet = makeAddr("protocoloWallet");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    bytes32 public agenteRole;

    uint256 public constant META_MINIMA = 10_000 ether;
    uint256 public constant META_MAXIMA = 50_000 ether;
    uint256 public constant PRECO_POR_COTA = 1 ether;
    uint256 public constant TETO_POR_INVESTIDOR = 5_000 ether;
    uint256 public constant TAXA_BPS = 50;

    function setUp() public {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        moeda = new MockBRL();
        implementacao = new OfertaCaptacao();

        factory = new OfertaCaptacaoFactory(
            admin, address(implementacao), address(gateway), address(registro), address(moeda), TIMELOCK_DELAY
        );
        agenteRole = factory.AGENTE_ROLE();
        _grantRole(address(factory), agenteRole, agente);
        _grantRole(address(gateway), gateway.AGENTE_ROLE(), agente);

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

    function _prazoValido() internal view returns (uint256) {
        return block.timestamp + 30 days;
    }

    function _criarCaptacao() internal returns (address) {
        vm.prank(agente);
        return factory.criarCaptacao(
            address(token),
            META_MINIMA,
            META_MAXIMA,
            PRECO_POR_COTA,
            _prazoValido(),
            TETO_POR_INVESTIDOR,
            TAXA_BPS,
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
        new OfertaCaptacaoFactory(admin, address(0), address(gateway), address(registro), address(moeda), TIMELOCK_DELAY);
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

    function test_CriarCaptacao_OnlyAgente() public {
        vm.prank(estranho);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, estranho, agenteRole)
        );
        factory.criarCaptacao(
            address(token),
            META_MINIMA,
            META_MAXIMA,
            PRECO_POR_COTA,
            _prazoValido(),
            TETO_POR_INVESTIDOR,
            TAXA_BPS,
            emissorWallet,
            protocoloWallet
        );
    }

    function test_CriarCaptacao_ClonesAndInitializes() public {
        address ofertaAddr = _criarCaptacao();
        OfertaCaptacao oferta = OfertaCaptacao(ofertaAddr);

        assertEq(address(oferta.token()), address(token));
        assertEq(oferta.gateway(), address(gateway));
        assertEq(address(oferta.registro()), address(registro));
        assertEq(address(oferta.moeda()), address(moeda));
        assertEq(oferta.emissorWallet(), emissorWallet);
        assertEq(oferta.protocoloWallet(), protocoloWallet);
        assertEq(oferta.metaMinima(), META_MINIMA);
        assertEq(oferta.metaMaxima(), META_MAXIMA);
        assertEq(oferta.precoPorCota(), PRECO_POR_COTA);
        assertEq(oferta.tetoPorInvestidor(), TETO_POR_INVESTIDOR);
        assertEq(oferta.taxaBps(), TAXA_BPS);
        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.Aberta));
    }

    function test_CriarCaptacao_RegistersCaptacao() public {
        address ofertaAddr = _criarCaptacao();
        assertTrue(factory.isCaptacao(ofertaAddr));
        assertEq(factory.numCaptacoes(), 1);
        assertEq(factory.captacoes(0), ofertaAddr);
    }

    function test_CriarCaptacao_RevertsForZeroToken() public {
        vm.prank(agente);
        vm.expectRevert(OfertaCaptacaoFactory.ZeroAddress.selector);
        factory.criarCaptacao(
            address(0),
            META_MINIMA,
            META_MAXIMA,
            PRECO_POR_COTA,
            _prazoValido(),
            TETO_POR_INVESTIDOR,
            TAXA_BPS,
            emissorWallet,
            protocoloWallet
        );
    }

    function test_CriarCaptacao_RevertsForMetaMinimaAboveMaxima() public {
        vm.prank(agente);
        vm.expectRevert(
            abi.encodeWithSelector(OfertaCaptacaoFactory.MetasInvalidas.selector, META_MAXIMA + 1, META_MAXIMA)
        );
        factory.criarCaptacao(
            address(token),
            META_MAXIMA + 1,
            META_MAXIMA,
            PRECO_POR_COTA,
            _prazoValido(),
            TETO_POR_INVESTIDOR,
            TAXA_BPS,
            emissorWallet,
            protocoloWallet
        );
    }

    function test_CriarCaptacao_RevertsForZeroPreco() public {
        vm.prank(agente);
        vm.expectRevert(OfertaCaptacaoFactory.PrecoInvalido.selector);
        factory.criarCaptacao(
            address(token),
            META_MINIMA,
            META_MAXIMA,
            0,
            _prazoValido(),
            TETO_POR_INVESTIDOR,
            TAXA_BPS,
            emissorWallet,
            protocoloWallet
        );
    }

    function test_CriarCaptacao_RevertsForPastPrazo() public {
        vm.prank(agente);
        vm.expectRevert(abi.encodeWithSelector(OfertaCaptacaoFactory.PrazoInvalido.selector, block.timestamp));
        factory.criarCaptacao(
            address(token),
            META_MINIMA,
            META_MAXIMA,
            PRECO_POR_COTA,
            block.timestamp,
            TETO_POR_INVESTIDOR,
            TAXA_BPS,
            emissorWallet,
            protocoloWallet
        );
    }

    function test_CriarCaptacao_RevertsForTaxaAboveMaximo() public {
        vm.prank(agente);
        vm.expectRevert(abi.encodeWithSelector(OfertaCaptacaoFactory.TaxaExcedeMaximo.selector, 101, 100));
        factory.criarCaptacao(
            address(token),
            META_MINIMA,
            META_MAXIMA,
            PRECO_POR_COTA,
            _prazoValido(),
            TETO_POR_INVESTIDOR,
            101,
            emissorWallet,
            protocoloWallet
        );
    }

    function test_CriarCaptacao_RevertsWhenPaused() public {
        vm.prank(agente);
        factory.pause();

        vm.prank(agente);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.criarCaptacao(
            address(token),
            META_MINIMA,
            META_MAXIMA,
            PRECO_POR_COTA,
            _prazoValido(),
            TETO_POR_INVESTIDOR,
            TAXA_BPS,
            emissorWallet,
            protocoloWallet
        );
    }

    function test_CriarCaptacao_MultipleOffersAreIndependentClones() public {
        address ofertaA = _criarCaptacao();
        address ofertaB = _criarCaptacao();

        assertTrue(ofertaA != ofertaB);
        assertEq(factory.numCaptacoes(), 2);
    }

    // ── Pausa ───────────────────────────────────────────────────────────────────────────

    function test_Pause_OnlyAgente() public {
        vm.prank(estranho);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, estranho, agenteRole)
        );
        factory.pause();
    }

    function test_PauseUnpause_RoundTrip() public {
        vm.prank(agente);
        factory.pause();
        assertTrue(factory.paused());

        vm.prank(agente);
        factory.unpause();
        assertFalse(factory.paused());
    }

    // ── Troca de implementação via timelock ─────────────────────────────────────────────

    function test_SetImplementacao_RequiresTimelock() public {
        OfertaCaptacao novaImpl = new OfertaCaptacao();

        vm.prank(admin);
        factory.proposeSetImplementacao(address(novaImpl));

        vm.prank(admin);
        vm.expectRevert();
        factory.executeSetImplementacao(address(novaImpl));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        factory.executeSetImplementacao(address(novaImpl));

        assertEq(factory.implementacao(), address(novaImpl));
    }

    function test_SetImplementacao_OnlyAffectsFutureOffers() public {
        address ofertaAntiga = _criarCaptacao();

        OfertaCaptacao novaImpl = new OfertaCaptacao();
        vm.prank(admin);
        factory.proposeSetImplementacao(address(novaImpl));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        factory.executeSetImplementacao(address(novaImpl));

        address ofertaNova = _criarCaptacao();

        assertTrue(ofertaAntiga != ofertaNova);
        assertEq(uint256(OfertaCaptacao(ofertaAntiga).estado()), uint256(OfertaCaptacao.Estado.Aberta));
    }

    function test_SetImplementacao_RevertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(OfertaCaptacaoFactory.ZeroAddress.selector);
        factory.proposeSetImplementacao(address(0));
    }
}
