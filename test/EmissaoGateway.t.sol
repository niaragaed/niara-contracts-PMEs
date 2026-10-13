// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";

contract EmissaoGatewayTest is Test {
    EmissaoGateway public gateway;
    ParticipacaoToken public token;
    DenyAllTransferPolicy public policy;

    address public admin = makeAddr("admin");
    address public agent = makeAddr("agente");
    address public stranger = makeAddr("estranho");
    address public investidor = makeAddr("investidor");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public agentRole;

    function setUp() public {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        agentRole = gateway.AGENTE_ROLE();
        _grantRole(agentRole, agent);

        policy = new DenyAllTransferPolicy();
        ParticipacaoToken implementacao = new ParticipacaoToken();
        address clone = Clones.clone(address(implementacao));
        token = ParticipacaoToken(clone);
        token.initialize("Oferta X", "nX", address(gateway), address(policy), "Empresa X", bytes32(0), "2026-A");
    }

    function _grantRole(bytes32 role, address account) internal {
        vm.prank(admin);
        gateway.proposeGrantRole(role, account);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        gateway.executeGrantRole(role, account);
    }

    // ── Construtor ──────────────────────────────────────────────────────────────────────

    function test_Constructor_RevertsForZeroAdmin() public {
        vm.expectRevert(EmissaoGateway.ZeroAddress.selector);
        new EmissaoGateway(address(0), TIMELOCK_DELAY);
    }

    function test_Constructor_GrantsAdminRole() public view {
        assertTrue(gateway.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    // ── atestarCotas ────────────────────────────────────────────────────────────────────

    function test_AtestarCotas_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agentRole)
        );
        gateway.atestarCotas(address(token), 1_000 ether);
    }

    function test_AtestarCotas_UpdatesTokenCap() public {
        vm.prank(agent);
        gateway.atestarCotas(address(token), 1_000 ether);
        assertEq(token.cotasAutorizadas(), 1_000 ether);
    }

    function test_AtestarCotas_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(gateway));
        emit EmissaoGateway.CotasAtestadas(address(token), 1_000 ether);
        vm.prank(agent);
        gateway.atestarCotas(address(token), 1_000 ether);
    }

    // ── emitir ──────────────────────────────────────────────────────────────────────────

    function test_Emitir_OnlyAgent() public {
        vm.prank(agent);
        gateway.atestarCotas(address(token), 1_000 ether);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agentRole)
        );
        gateway.emitir(address(token), investidor, 100 ether);
    }

    function test_Emitir_MintsToInvestor() public {
        vm.prank(agent);
        gateway.atestarCotas(address(token), 1_000 ether);

        vm.prank(agent);
        gateway.emitir(address(token), investidor, 100 ether);

        assertEq(token.balanceOf(investidor), 100 ether);
    }

    function test_Emitir_RevertsBeyondAttestedCap() public {
        vm.prank(agent);
        gateway.atestarCotas(address(token), 100 ether);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(ParticipacaoToken.MintExcedeCotasAutorizadas.selector, 101 ether, 100 ether)
        );
        gateway.emitir(address(token), investidor, 101 ether);
    }

    // ── pausarToken / despausarToken ────────────────────────────────────────────────────

    function test_PausarToken_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agentRole)
        );
        gateway.pausarToken(address(token));
    }

    function test_PausarToken_PausesToken() public {
        vm.prank(agent);
        gateway.pausarToken(address(token));
        assertTrue(token.paused());
    }

    function test_DespausarToken_UnpausesToken() public {
        vm.prank(agent);
        gateway.pausarToken(address(token));

        vm.prank(agent);
        gateway.despausarToken(address(token));
        assertFalse(token.paused());
    }

    // ── registrarCaptacao ───────────────────────────────────────────────────────────────

    address public fakeFundraising = makeAddr("captacaoFake");

    function test_RegistrarCaptacao_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agentRole)
        );
        gateway.registrarCaptacao(address(token), fakeFundraising);
    }

    function test_RegistrarCaptacao_SetsAuthorizedCaptacao() public {
        vm.prank(agent);
        gateway.registrarCaptacao(address(token), fakeFundraising);
        assertEq(gateway.ofertaCaptacaoAutorizada(address(token)), fakeFundraising);
    }

    function test_RegistrarCaptacao_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(gateway));
        emit EmissaoGateway.CaptacaoRegistrada(address(token), fakeFundraising);
        vm.prank(agent);
        gateway.registrarCaptacao(address(token), fakeFundraising);
    }

    function test_RegistrarCaptacao_CanRevokeWithZeroAddress() public {
        vm.prank(agent);
        gateway.registrarCaptacao(address(token), fakeFundraising);

        vm.prank(agent);
        gateway.registrarCaptacao(address(token), address(0));
        assertEq(gateway.ofertaCaptacaoAutorizada(address(token)), address(0));
    }

    // ── emitirParaCaptacao ──────────────────────────────────────────────────────────────

    function test_EmitirParaCaptacao_OnlyAuthorizedFundraising() public {
        vm.prank(agent);
        gateway.atestarCotas(address(token), 1_000 ether);

        vm.prank(agent);
        gateway.registrarCaptacao(address(token), fakeFundraising);

        vm.prank(stranger);
        vm.expectRevert(EmissaoGateway.NaoAutorizado.selector);
        gateway.emitirParaCaptacao(address(token), investidor, 100 ether);
    }

    function test_EmitirParaCaptacao_MintsToInvestor() public {
        vm.prank(agent);
        gateway.atestarCotas(address(token), 1_000 ether);

        vm.prank(agent);
        gateway.registrarCaptacao(address(token), fakeFundraising);

        vm.prank(fakeFundraising);
        gateway.emitirParaCaptacao(address(token), investidor, 100 ether);

        assertEq(token.balanceOf(investidor), 100 ether);
    }

    function test_EmitirParaCaptacao_RevertsBeyondAttestedCap() public {
        vm.prank(agent);
        gateway.atestarCotas(address(token), 100 ether);

        vm.prank(agent);
        gateway.registrarCaptacao(address(token), fakeFundraising);

        vm.prank(fakeFundraising);
        vm.expectRevert(
            abi.encodeWithSelector(ParticipacaoToken.MintExcedeCotasAutorizadas.selector, 101 ether, 100 ether)
        );
        gateway.emitirParaCaptacao(address(token), investidor, 101 ether);
    }

    function test_EmitirParaCaptacao_EmitsEvent() public {
        vm.prank(agent);
        gateway.atestarCotas(address(token), 1_000 ether);
        vm.prank(agent);
        gateway.registrarCaptacao(address(token), fakeFundraising);

        vm.expectEmit(true, true, true, true, address(gateway));
        emit EmissaoGateway.CotasEmitidasViaCaptacao(address(token), investidor, 100 ether);
        vm.prank(fakeFundraising);
        gateway.emitirParaCaptacao(address(token), investidor, 100 ether);
    }

    function test_EmitirParaCaptacao_RevertsWhenNoFundraisingRegistered() public {
        vm.prank(agent);
        gateway.atestarCotas(address(token), 1_000 ether);

        vm.prank(fakeFundraising);
        vm.expectRevert(EmissaoGateway.NaoAutorizado.selector);
        gateway.emitirParaCaptacao(address(token), investidor, 100 ether);
    }

    // ── Transfer policy change via timelock (Phase 3) ───────────────────────────────────

    function test_SetTransferPolicy_RequiresTimelock() public {
        DenyAllTransferPolicy novaPolitica = new DenyAllTransferPolicy();

        vm.prank(admin);
        gateway.proposeSetTransferPolicy(address(token), address(novaPolitica));

        vm.prank(admin);
        vm.expectRevert();
        gateway.executeSetTransferPolicy(address(token), address(novaPolitica));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        gateway.executeSetTransferPolicy(address(token), address(novaPolitica));

        assertEq(token.transferPolicy(), address(novaPolitica));
    }

    function test_SetTransferPolicy_OnlyAdminCanPropose() public {
        DenyAllTransferPolicy novaPolitica = new DenyAllTransferPolicy();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE)
        );
        gateway.proposeSetTransferPolicy(address(token), address(novaPolitica));
    }

    function test_SetTransferPolicy_RevertsForZeroToken() public {
        DenyAllTransferPolicy novaPolitica = new DenyAllTransferPolicy();
        vm.prank(admin);
        vm.expectRevert(EmissaoGateway.ZeroAddress.selector);
        gateway.proposeSetTransferPolicy(address(0), address(novaPolitica));
    }

    function test_SetTransferPolicy_RevertsForZeroPolitica() public {
        vm.prank(admin);
        vm.expectRevert(EmissaoGateway.ZeroAddress.selector);
        gateway.proposeSetTransferPolicy(address(token), address(0));
    }

    function test_SetTransferPolicy_EmitsEvents() public {
        DenyAllTransferPolicy novaPolitica = new DenyAllTransferPolicy();
        uint256 executeAfter = block.timestamp + TIMELOCK_DELAY;

        vm.expectEmit(true, true, true, true, address(gateway));
        emit EmissaoGateway.TransferPolicyChangeProposed(address(token), address(novaPolitica), executeAfter);
        vm.prank(admin);
        gateway.proposeSetTransferPolicy(address(token), address(novaPolitica));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, true, true, true, address(gateway));
        emit EmissaoGateway.TransferPolicyChanged(address(token), address(novaPolitica));
        vm.prank(admin);
        gateway.executeSetTransferPolicy(address(token), address(novaPolitica));
    }
}
