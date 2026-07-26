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
    address public agente = makeAddr("agente");
    address public estranho = makeAddr("estranho");
    address public investidor = makeAddr("investidor");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public agenteRole;

    function setUp() public {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        agenteRole = gateway.AGENTE_ROLE();
        _grantRole(agenteRole, agente);

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

    function test_AtestarCotas_OnlyAgente() public {
        vm.prank(estranho);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, estranho, agenteRole)
        );
        gateway.atestarCotas(address(token), 1_000 ether);
    }

    function test_AtestarCotas_UpdatesTokenCap() public {
        vm.prank(agente);
        gateway.atestarCotas(address(token), 1_000 ether);
        assertEq(token.cotasAutorizadas(), 1_000 ether);
    }

    function test_AtestarCotas_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(gateway));
        emit EmissaoGateway.CotasAtestadas(address(token), 1_000 ether);
        vm.prank(agente);
        gateway.atestarCotas(address(token), 1_000 ether);
    }

    // ── emitir ──────────────────────────────────────────────────────────────────────────

    function test_Emitir_OnlyAgente() public {
        vm.prank(agente);
        gateway.atestarCotas(address(token), 1_000 ether);

        vm.prank(estranho);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, estranho, agenteRole)
        );
        gateway.emitir(address(token), investidor, 100 ether);
    }

    function test_Emitir_MintsToInvestidor() public {
        vm.prank(agente);
        gateway.atestarCotas(address(token), 1_000 ether);

        vm.prank(agente);
        gateway.emitir(address(token), investidor, 100 ether);

        assertEq(token.balanceOf(investidor), 100 ether);
    }

    function test_Emitir_RevertsBeyondAttestedCap() public {
        vm.prank(agente);
        gateway.atestarCotas(address(token), 100 ether);

        vm.prank(agente);
        vm.expectRevert(
            abi.encodeWithSelector(ParticipacaoToken.MintExcedeCotasAutorizadas.selector, 101 ether, 100 ether)
        );
        gateway.emitir(address(token), investidor, 101 ether);
    }

    // ── pausarToken / despausarToken ────────────────────────────────────────────────────

    function test_PausarToken_OnlyAgente() public {
        vm.prank(estranho);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, estranho, agenteRole)
        );
        gateway.pausarToken(address(token));
    }

    function test_PausarToken_PausesToken() public {
        vm.prank(agente);
        gateway.pausarToken(address(token));
        assertTrue(token.paused());
    }

    function test_DespausarToken_UnpausesToken() public {
        vm.prank(agente);
        gateway.pausarToken(address(token));

        vm.prank(agente);
        gateway.despausarToken(address(token));
        assertFalse(token.paused());
    }

    // ── registrarCaptacao ───────────────────────────────────────────────────────────────

    address public captacaoFake = makeAddr("captacaoFake");

    function test_RegistrarCaptacao_OnlyAgente() public {
        vm.prank(estranho);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, estranho, agenteRole)
        );
        gateway.registrarCaptacao(address(token), captacaoFake);
    }

    function test_RegistrarCaptacao_SetsAuthorizedCaptacao() public {
        vm.prank(agente);
        gateway.registrarCaptacao(address(token), captacaoFake);
        assertEq(gateway.ofertaCaptacaoAutorizada(address(token)), captacaoFake);
    }

    function test_RegistrarCaptacao_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(gateway));
        emit EmissaoGateway.CaptacaoRegistrada(address(token), captacaoFake);
        vm.prank(agente);
        gateway.registrarCaptacao(address(token), captacaoFake);
    }

    function test_RegistrarCaptacao_CanRevokeWithZeroAddress() public {
        vm.prank(agente);
        gateway.registrarCaptacao(address(token), captacaoFake);

        vm.prank(agente);
        gateway.registrarCaptacao(address(token), address(0));
        assertEq(gateway.ofertaCaptacaoAutorizada(address(token)), address(0));
    }

    // ── emitirParaCaptacao ──────────────────────────────────────────────────────────────

    function test_EmitirParaCaptacao_OnlyAuthorizedCaptacao() public {
        vm.prank(agente);
        gateway.atestarCotas(address(token), 1_000 ether);

        vm.prank(agente);
        gateway.registrarCaptacao(address(token), captacaoFake);

        vm.prank(estranho);
        vm.expectRevert(EmissaoGateway.NaoAutorizado.selector);
        gateway.emitirParaCaptacao(address(token), investidor, 100 ether);
    }

    function test_EmitirParaCaptacao_MintsToInvestidor() public {
        vm.prank(agente);
        gateway.atestarCotas(address(token), 1_000 ether);

        vm.prank(agente);
        gateway.registrarCaptacao(address(token), captacaoFake);

        vm.prank(captacaoFake);
        gateway.emitirParaCaptacao(address(token), investidor, 100 ether);

        assertEq(token.balanceOf(investidor), 100 ether);
    }

    function test_EmitirParaCaptacao_RevertsBeyondAttestedCap() public {
        vm.prank(agente);
        gateway.atestarCotas(address(token), 100 ether);

        vm.prank(agente);
        gateway.registrarCaptacao(address(token), captacaoFake);

        vm.prank(captacaoFake);
        vm.expectRevert(
            abi.encodeWithSelector(ParticipacaoToken.MintExcedeCotasAutorizadas.selector, 101 ether, 100 ether)
        );
        gateway.emitirParaCaptacao(address(token), investidor, 101 ether);
    }

    function test_EmitirParaCaptacao_EmitsEvent() public {
        vm.prank(agente);
        gateway.atestarCotas(address(token), 1_000 ether);
        vm.prank(agente);
        gateway.registrarCaptacao(address(token), captacaoFake);

        vm.expectEmit(true, true, true, true, address(gateway));
        emit EmissaoGateway.CotasEmitidasViaCaptacao(address(token), investidor, 100 ether);
        vm.prank(captacaoFake);
        gateway.emitirParaCaptacao(address(token), investidor, 100 ether);
    }

    function test_EmitirParaCaptacao_RevertsWhenNoCaptacaoRegistered() public {
        vm.prank(agente);
        gateway.atestarCotas(address(token), 1_000 ether);

        vm.prank(captacaoFake);
        vm.expectRevert(EmissaoGateway.NaoAutorizado.selector);
        gateway.emitirParaCaptacao(address(token), investidor, 100 ether);
    }
}
