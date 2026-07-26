// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";

contract ParticipacaoTokenFactoryTest is Test {
    ParticipacaoTokenFactory public factory;
    ParticipacaoToken public implementacao;
    DenyAllTransferPolicy public policy;

    address public admin = makeAddr("admin");
    address public agente = makeAddr("agente");
    address public estranho = makeAddr("estranho");
    address public gatewayAddr = makeAddr("gateway");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    bytes32 public agenteRole;

    bytes32 public constant CNPJ_REF = keccak256("12.345.678/0001-99");

    function setUp() public {
        implementacao = new ParticipacaoToken();
        policy = new DenyAllTransferPolicy();

        factory =
            new ParticipacaoTokenFactory(admin, address(implementacao), gatewayAddr, address(policy), TIMELOCK_DELAY);
        agenteRole = factory.AGENTE_ROLE();
        _grantRole(agenteRole, agente);
    }

    function _grantRole(bytes32 role, address account) internal {
        vm.prank(admin);
        factory.proposeGrantRole(role, account);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        factory.executeGrantRole(role, account);
    }

    // ── Construtor ──────────────────────────────────────────────────────────────────────

    function test_Constructor_RevertsForZeroAdmin() public {
        vm.expectRevert(ParticipacaoTokenFactory.ZeroAddress.selector);
        new ParticipacaoTokenFactory(address(0), address(implementacao), gatewayAddr, address(policy), TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForZeroImplementacao() public {
        vm.expectRevert(ParticipacaoTokenFactory.ZeroAddress.selector);
        new ParticipacaoTokenFactory(admin, address(0), gatewayAddr, address(policy), TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForZeroGateway() public {
        vm.expectRevert(ParticipacaoTokenFactory.ZeroAddress.selector);
        new ParticipacaoTokenFactory(admin, address(implementacao), address(0), address(policy), TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForZeroPolicy() public {
        vm.expectRevert(ParticipacaoTokenFactory.ZeroAddress.selector);
        new ParticipacaoTokenFactory(admin, address(implementacao), gatewayAddr, address(0), TIMELOCK_DELAY);
    }

    // ── criarOferta ─────────────────────────────────────────────────────────────────────

    function test_CriarOferta_OnlyAgente() public {
        vm.prank(estranho);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, estranho, agenteRole)
        );
        factory.criarOferta("Oferta X", "nX", "Empresa X", CNPJ_REF, "2026-A");
    }

    function test_CriarOferta_ClonesAndInitializes() public {
        vm.prank(agente);
        address tokenAddr = factory.criarOferta("Oferta X", "nX", "Empresa X", CNPJ_REF, "2026-A");

        ParticipacaoToken token = ParticipacaoToken(tokenAddr);
        assertEq(token.name(), "Oferta X");
        assertEq(token.symbol(), "nX");
        assertEq(token.gateway(), gatewayAddr);
        assertEq(token.transferPolicy(), address(policy));
        assertEq(token.empresa(), "Empresa X");
        assertEq(token.cnpjRef(), CNPJ_REF);
        assertEq(token.serie(), "2026-A");
    }

    function test_CriarOferta_RegistersOferta() public {
        vm.prank(agente);
        address tokenAddr = factory.criarOferta("Oferta X", "nX", "Empresa X", CNPJ_REF, "2026-A");

        assertTrue(factory.isOferta(tokenAddr));
        assertEq(factory.numOfertas(), 1);
        assertEq(factory.ofertas(0), tokenAddr);
    }

    function test_CriarOferta_EmitsEvent() public {
        // `Clones.clone` usa CREATE simples — o endereço do clone depende do nonce da
        // factory no momento da chamada (nonce 1, pois contratos começam em nonce 1).
        address clonePrevisto = vm.computeCreateAddress(address(factory), 1);

        vm.expectEmit(true, true, true, true, address(factory));
        emit ParticipacaoTokenFactory.OfertaCriada(clonePrevisto, "Empresa X", CNPJ_REF, "2026-A");
        vm.prank(agente);
        factory.criarOferta("Oferta X", "nX", "Empresa X", CNPJ_REF, "2026-A");
    }

    function test_CriarOferta_MultipleOffersAreIndependentClones() public {
        vm.prank(agente);
        address tokenA = factory.criarOferta("Oferta A", "nA", "Empresa A", CNPJ_REF, "2026-A");
        vm.prank(agente);
        address tokenB = factory.criarOferta("Oferta B", "nB", "Empresa B", CNPJ_REF, "2026-B");

        assertTrue(tokenA != tokenB);
        assertEq(factory.numOfertas(), 2);
        assertEq(ParticipacaoToken(tokenA).name(), "Oferta A");
        assertEq(ParticipacaoToken(tokenB).name(), "Oferta B");
    }

    function test_CriarOferta_RevertsWhenPaused() public {
        vm.prank(agente);
        factory.pause();

        vm.prank(agente);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.criarOferta("Oferta X", "nX", "Empresa X", CNPJ_REF, "2026-A");
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
        ParticipacaoToken novaImpl = new ParticipacaoToken();

        vm.prank(admin);
        factory.proposeSetImplementacao(address(novaImpl));

        // Ainda não decorreu o atraso — deve reverter.
        vm.prank(admin);
        vm.expectRevert();
        factory.executeSetImplementacao(address(novaImpl));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        factory.executeSetImplementacao(address(novaImpl));

        assertEq(factory.implementacao(), address(novaImpl));
    }

    function test_SetImplementacao_OnlyAffectsFutureOffers() public {
        vm.prank(agente);
        address tokenAntigo = factory.criarOferta("Oferta A", "nA", "Empresa A", CNPJ_REF, "2026-A");

        ParticipacaoToken novaImpl = new ParticipacaoToken();
        vm.prank(admin);
        factory.proposeSetImplementacao(address(novaImpl));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        factory.executeSetImplementacao(address(novaImpl));

        vm.prank(agente);
        address tokenNovo = factory.criarOferta("Oferta B", "nB", "Empresa B", CNPJ_REF, "2026-B");

        // O token antigo continua funcional e distinto do novo — a troca de implementação não
        // afeta clones já criados (cada clone congela a lógica da implementação no momento em
        // que foi clonado, via delegatecall para o endereço fixo do template usado então).
        assertTrue(tokenAntigo != tokenNovo);
        assertEq(ParticipacaoToken(tokenAntigo).name(), "Oferta A");
    }

    function test_SetImplementacao_RevertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ParticipacaoTokenFactory.ZeroAddress.selector);
        factory.proposeSetImplementacao(address(0));
    }

    // ── Troca da política padrão via timelock ───────────────────────────────────────────

    function test_SetTransferPolicyPadrao_RequiresTimelock() public {
        DenyAllTransferPolicy novaPolitica = new DenyAllTransferPolicy();

        vm.prank(admin);
        factory.proposeSetTransferPolicyPadrao(address(novaPolitica));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        factory.executeSetTransferPolicyPadrao(address(novaPolitica));

        assertEq(factory.transferPolicyPadrao(), address(novaPolitica));
    }

    function test_SetTransferPolicyPadrao_RevertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ParticipacaoTokenFactory.ZeroAddress.selector);
        factory.proposeSetTransferPolicyPadrao(address(0));
    }
}
