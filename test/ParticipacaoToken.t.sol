// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";

contract ParticipacaoTokenTest is Test {
    ParticipacaoToken public implementacao;
    ParticipacaoToken public token;
    DenyAllTransferPolicy public policy;

    address public gateway = makeAddr("gateway");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 public constant CNPJ_REF = keccak256("12.345.678/0001-99");

    function setUp() public {
        implementacao = new ParticipacaoToken();
        policy = new DenyAllTransferPolicy();

        address clone = Clones.clone(address(implementacao));
        token = ParticipacaoToken(clone);
        token.initialize("Oferta Padaria Silva", "nPAD", gateway, address(policy), "Padaria Silva Ltda", CNPJ_REF, "2026-A");
    }

    // ── Inicialização ───────────────────────────────────────────────────────────────────

    function test_Initialize_SetsMetadata() public view {
        assertEq(token.name(), "Oferta Padaria Silva");
        assertEq(token.symbol(), "nPAD");
        assertEq(token.gateway(), gateway);
        assertEq(token.transferPolicy(), address(policy));
        assertEq(token.empresa(), "Padaria Silva Ltda");
        assertEq(token.cnpjRef(), CNPJ_REF);
        assertEq(token.serie(), "2026-A");
        assertEq(token.cotasAutorizadas(), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_Initialize_RevertsOnSecondCall() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize("X", "X", gateway, address(policy), "X", bytes32(0), "X");
    }

    function test_Implementation_CannotBeInitializedDirectly() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementacao.initialize("X", "X", gateway, address(policy), "X", bytes32(0), "X");
    }

    function test_Initialize_RevertsForZeroGateway() public {
        address clone = Clones.clone(address(implementacao));
        vm.expectRevert(ParticipacaoToken.ZeroAddress.selector);
        ParticipacaoToken(clone).initialize("X", "X", address(0), address(policy), "X", bytes32(0), "X");
    }

    function test_Initialize_RevertsForZeroTransferPolicy() public {
        address clone = Clones.clone(address(implementacao));
        vm.expectRevert(ParticipacaoToken.ZeroAddress.selector);
        ParticipacaoToken(clone).initialize("X", "X", gateway, address(0), "X", bytes32(0), "X");
    }

    // ── setCotasAutorizadas ─────────────────────────────────────────────────────────────

    function test_SetCotasAutorizadas_OnlyGateway() public {
        vm.prank(alice);
        vm.expectRevert(ParticipacaoToken.NaoAutorizado.selector);
        token.setCotasAutorizadas(1_000 ether);
    }

    function test_SetCotasAutorizadas_IncreasesCap() public {
        vm.prank(gateway);
        token.setCotasAutorizadas(1_000 ether);
        assertEq(token.cotasAutorizadas(), 1_000 ether);

        vm.prank(gateway);
        token.setCotasAutorizadas(2_000 ether);
        assertEq(token.cotasAutorizadas(), 2_000 ether);
    }

    function test_SetCotasAutorizadas_RevertsOnDecrease() public {
        vm.prank(gateway);
        token.setCotasAutorizadas(1_000 ether);

        vm.prank(gateway);
        vm.expectRevert(
            abi.encodeWithSelector(ParticipacaoToken.CotasAutorizadasNaoPodemDiminuir.selector, 1_000 ether, 500 ether)
        );
        token.setCotasAutorizadas(500 ether);
    }

    function test_SetCotasAutorizadas_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit ParticipacaoToken.CotasAutorizadasAlteradas(0, 1_000 ether);
        vm.prank(gateway);
        token.setCotasAutorizadas(1_000 ether);
    }

    // ── mint ────────────────────────────────────────────────────────────────────────────

    function test_Mint_OnlyGateway() public {
        vm.prank(gateway);
        token.setCotasAutorizadas(1_000 ether);

        vm.prank(alice);
        vm.expectRevert(ParticipacaoToken.NaoAutorizado.selector);
        token.mint(alice, 100 ether);
    }

    function test_Mint_RespectsCap() public {
        vm.prank(gateway);
        token.setCotasAutorizadas(100 ether);

        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(ParticipacaoToken.MintExcedeCotasAutorizadas.selector, 101 ether, 100 ether));
        token.mint(alice, 101 ether);
    }

    function test_Mint_ExactlyAtCap_Succeeds() public {
        vm.prank(gateway);
        token.setCotasAutorizadas(100 ether);

        vm.prank(gateway);
        token.mint(alice, 100 ether);

        assertEq(token.totalSupply(), 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_Mint_RevertsWithoutAttestation() public {
        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(ParticipacaoToken.MintExcedeCotasAutorizadas.selector, 1, 0));
        token.mint(alice, 1);
    }

    function test_Mint_AccumulatesTowardCap() public {
        vm.prank(gateway);
        token.setCotasAutorizadas(100 ether);

        vm.prank(gateway);
        token.mint(alice, 60 ether);
        vm.prank(gateway);
        token.mint(bob, 40 ether);

        assertEq(token.totalSupply(), 100 ether);

        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(ParticipacaoToken.MintExcedeCotasAutorizadas.selector, 101 ether, 100 ether));
        token.mint(alice, 1 ether);
    }

    function test_Mint_EmitsEvent() public {
        vm.prank(gateway);
        token.setCotasAutorizadas(100 ether);

        vm.expectEmit(true, true, true, true, address(token));
        emit ParticipacaoToken.CotasEmitidas(alice, 50 ether);
        vm.prank(gateway);
        token.mint(alice, 50 ether);
    }

    function test_Mint_RevertsWhenPaused() public {
        vm.prank(gateway);
        token.setCotasAutorizadas(100 ether);
        vm.prank(gateway);
        token.pause();

        vm.prank(gateway);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.mint(alice, 1 ether);
    }

    // ── Transferência (política nega-tudo) ─────────────────────────────────────────────

    function test_Transfer_AlwaysRevertsBetweenHolders() public {
        vm.prank(gateway);
        token.setCotasAutorizadas(100 ether);
        vm.prank(gateway);
        token.mint(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(ParticipacaoToken.TransferenciaNaoPermitida.selector);
        token.transfer(bob, 1 ether);
    }

    function test_TransferFrom_AlwaysRevertsBetweenHolders() public {
        vm.prank(gateway);
        token.setCotasAutorizadas(100 ether);
        vm.prank(gateway);
        token.mint(alice, 100 ether);

        vm.prank(alice);
        token.approve(bob, 10 ether);

        vm.prank(bob);
        vm.expectRevert(ParticipacaoToken.TransferenciaNaoPermitida.selector);
        token.transferFrom(alice, bob, 10 ether);
    }

    // ── setTransferPolicy (Fase 3) ─────────────────────────────────────────────────────

    function test_SetTransferPolicy_OnlyGateway() public {
        DenyAllTransferPolicy novaPolitica = new DenyAllTransferPolicy();
        vm.prank(alice);
        vm.expectRevert(ParticipacaoToken.NaoAutorizado.selector);
        token.setTransferPolicy(address(novaPolitica));
    }

    function test_SetTransferPolicy_UpdatesPolicy() public {
        DenyAllTransferPolicy novaPolitica = new DenyAllTransferPolicy();
        vm.prank(gateway);
        token.setTransferPolicy(address(novaPolitica));
        assertEq(token.transferPolicy(), address(novaPolitica));
    }

    function test_SetTransferPolicy_RevertsForZeroAddress() public {
        vm.prank(gateway);
        vm.expectRevert(ParticipacaoToken.ZeroAddress.selector);
        token.setTransferPolicy(address(0));
    }

    function test_SetTransferPolicy_EmitsEvent() public {
        DenyAllTransferPolicy novaPolitica = new DenyAllTransferPolicy();
        vm.expectEmit(true, true, true, true, address(token));
        emit ParticipacaoToken.TransferPolicyAlterada(address(policy), address(novaPolitica));
        vm.prank(gateway);
        token.setTransferPolicy(address(novaPolitica));
    }

    // ── Pausa ───────────────────────────────────────────────────────────────────────────

    function test_Pause_OnlyGateway() public {
        vm.prank(alice);
        vm.expectRevert(ParticipacaoToken.NaoAutorizado.selector);
        token.pause();
    }

    function test_Unpause_OnlyGateway() public {
        vm.prank(gateway);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(ParticipacaoToken.NaoAutorizado.selector);
        token.unpause();
    }

    function test_PauseUnpause_RoundTrip() public {
        vm.prank(gateway);
        token.pause();
        assertTrue(token.paused());

        vm.prank(gateway);
        token.unpause();
        assertFalse(token.paused());
    }

    // ── Invariante local: soma de saldos == totalSupply ────────────────────────────────

    function test_Invariant_SumOfBalancesEqualsTotalSupply() public {
        vm.prank(gateway);
        token.setCotasAutorizadas(1_000 ether);

        vm.prank(gateway);
        token.mint(alice, 300 ether);
        vm.prank(gateway);
        token.mint(bob, 200 ether);

        assertEq(token.balanceOf(alice) + token.balanceOf(bob), token.totalSupply());
    }
}
