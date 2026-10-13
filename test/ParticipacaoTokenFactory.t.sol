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
    address public agent = makeAddr("agente");
    address public stranger = makeAddr("estranho");
    address public gatewayAddr = makeAddr("gateway");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    bytes32 public agentRole;

    bytes32 public constant CNPJ_REF = keccak256("12.345.678/0001-99");

    function setUp() public {
        implementacao = new ParticipacaoToken();
        policy = new DenyAllTransferPolicy();

        factory =
            new ParticipacaoTokenFactory(admin, address(implementacao), gatewayAddr, address(policy), TIMELOCK_DELAY);
        agentRole = factory.AGENTE_ROLE();
        _grantRole(agentRole, agent);
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

    function test_CriarOferta_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agentRole)
        );
        factory.criarOferta("Oferta X", "nX", "Empresa X", CNPJ_REF, "2026-A");
    }

    function test_CriarOferta_ClonesAndInitializes() public {
        vm.prank(agent);
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
        vm.prank(agent);
        address tokenAddr = factory.criarOferta("Oferta X", "nX", "Empresa X", CNPJ_REF, "2026-A");

        assertTrue(factory.isOferta(tokenAddr));
        assertEq(factory.numOfertas(), 1);
        assertEq(factory.ofertas(0), tokenAddr);
    }

    function test_CriarOferta_EmitsEvent() public {
        // `Clones.clone` uses plain CREATE: the clone's address depends on the factory's
        // nonce at call time (nonce 1, since contracts start at nonce 1).
        address predictedClone = vm.computeCreateAddress(address(factory), 1);

        vm.expectEmit(true, true, true, true, address(factory));
        emit ParticipacaoTokenFactory.OfertaCriada(predictedClone, "Empresa X", CNPJ_REF, "2026-A");
        vm.prank(agent);
        factory.criarOferta("Oferta X", "nX", "Empresa X", CNPJ_REF, "2026-A");
    }

    function test_CriarOferta_MultipleOffersAreIndependentClones() public {
        vm.prank(agent);
        address tokenA = factory.criarOferta("Oferta A", "nA", "Empresa A", CNPJ_REF, "2026-A");
        vm.prank(agent);
        address tokenB = factory.criarOferta("Oferta B", "nB", "Empresa B", CNPJ_REF, "2026-B");

        assertTrue(tokenA != tokenB);
        assertEq(factory.numOfertas(), 2);
        assertEq(ParticipacaoToken(tokenA).name(), "Oferta A");
        assertEq(ParticipacaoToken(tokenB).name(), "Oferta B");
    }

    function test_CriarOferta_RevertsWhenPaused() public {
        vm.prank(agent);
        factory.pause();

        vm.prank(agent);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.criarOferta("Oferta X", "nX", "Empresa X", CNPJ_REF, "2026-A");
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
        ParticipacaoToken newImpl = new ParticipacaoToken();

        vm.prank(admin);
        factory.proposeSetImplementacao(address(newImpl));

        // The delay has not passed yet, so it must revert.
        vm.prank(admin);
        vm.expectRevert();
        factory.executeSetImplementacao(address(newImpl));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        factory.executeSetImplementacao(address(newImpl));

        assertEq(factory.implementacao(), address(newImpl));
    }

    function test_SetImplementacao_OnlyAffectsFutureOffers() public {
        vm.prank(agent);
        address oldToken = factory.criarOferta("Oferta A", "nA", "Empresa A", CNPJ_REF, "2026-A");

        ParticipacaoToken newImpl = new ParticipacaoToken();
        vm.prank(admin);
        factory.proposeSetImplementacao(address(newImpl));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        factory.executeSetImplementacao(address(newImpl));

        vm.prank(agent);
        address newToken = factory.criarOferta("Oferta B", "nB", "Empresa B", CNPJ_REF, "2026-B");

        // The old token is still functional and distinct from the new one: swapping the
        // implementation does not affect clones already created (each clone freezes the
        // implementation's logic at the time it was cloned, via delegatecall to the fixed address
        // of the template used then).
        assertTrue(oldToken != newToken);
        assertEq(ParticipacaoToken(oldToken).name(), "Oferta A");
    }

    function test_SetImplementacao_RevertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ParticipacaoTokenFactory.ZeroAddress.selector);
        factory.proposeSetImplementacao(address(0));
    }

    // ── Default policy change via timelock ──────────────────────────────────────────────

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
