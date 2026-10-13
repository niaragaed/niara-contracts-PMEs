// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";
import {LiquidacaoSecundaria} from "../src/secundario/LiquidacaoSecundaria.sol";
import {ReentrantMockBRL} from "./mocks/ReentrantMockBRL.sol";

/// @notice Dedicated proof that `nonReentrant` (+ CEI) blocks re-entry into `liquidarCessao`,
/// same pattern as `test/OfertaCaptacaoReentrancy.t.sol` (Phase 2, see CLAUDE.md). Uses
/// `ReentrantMockBRL`, which tries to re-enter the configured target from its own
/// `transferFrom`, simulating a real BRL stablecoin with a hook/callback; the benign `MockBRL`
/// would not exercise this protection.
contract LiquidacaoSecundariaReentrancyTest is Test {
    EmissaoGateway public gateway;
    ParticipacaoTokenFactory public factory;
    RestrictedTransferPolicy public policy;
    ReentrantMockBRL public moeda;
    LiquidacaoSecundaria public settlement;
    ParticipacaoToken public token;

    address public admin = makeAddr("admin");
    address public agent = makeAddr("agente");
    address public protocoloWallet = makeAddr("protocoloWallet");
    address public vendedor = makeAddr("vendedor");
    address public comprador = makeAddr("comprador");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    uint256 public constant PRICE_PER_SHARE = 100 ether;
    uint256 public constant SELLER_INITIAL_SHARES = 50 ether;
    uint256 public constant BUYER_INITIAL_BALANCE = 1_000_000 ether;

    function setUp() public {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        policy = new RestrictedTransferPolicy(admin, TIMELOCK_DELAY);
        moeda = new ReentrantMockBRL();

        ParticipacaoToken tokenImpl = new ParticipacaoToken();
        factory =
            new ParticipacaoTokenFactory(admin, address(tokenImpl), address(gateway), address(policy), TIMELOCK_DELAY);

        settlement = new LiquidacaoSecundaria(admin, address(moeda), address(factory), protocoloWallet, TIMELOCK_DELAY);

        _grantRole(address(gateway), gateway.AGENTE_ROLE(), agent);
        _grantRole(address(factory), factory.AGENTE_ROLE(), agent);
        _grantRole(address(policy), policy.AGENTE_ROLE(), agent);
        _grantRole(address(settlement), settlement.AGENTE_ROLE(), agent);

        vm.prank(agent);
        address tokenAddr = factory.criarOferta("Oferta X", "nX", "Empresa X", bytes32(0), "2026-A");
        token = ParticipacaoToken(tokenAddr);

        vm.prank(agent);
        gateway.atestarCotas(address(token), 1_000_000 ether);
        vm.prank(agent);
        gateway.emitir(address(token), vendedor, SELLER_INITIAL_SHARES);

        vm.prank(agent);
        policy.definirLockup(address(token), uint64(block.timestamp));
        vm.prank(agent);
        policy.definirElegivel(address(token), comprador, true);
        vm.prank(admin);
        policy.proposeSetSecundarioLiberado(address(token), true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        policy.executeSetSecundarioLiberado(address(token), true);

        moeda.mint(comprador, BUYER_INITIAL_BALANCE);
        vm.prank(vendedor);
        token.approve(address(settlement), type(uint256).max);
        vm.prank(comprador);
        moeda.approve(address(settlement), type(uint256).max);
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

    function test_LiquidarCessao_BlockedByReentrancyGuard() public {
        moeda.armAttack(
            address(settlement),
            abi.encodeWithSelector(
                LiquidacaoSecundaria.liquidarCessao.selector, address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE
            )
        );

        vm.prank(agent);
        settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);

        assertTrue(moeda.reentryBlocked());

        // The original assignment completed exactly once: no double movement of shares or
        // currency.
        assertEq(token.balanceOf(comprador), 10 ether);
        assertEq(token.balanceOf(vendedor), SELLER_INITIAL_SHARES - 10 ether);
        assertEq(moeda.balanceOf(vendedor), 1_000 ether);
        assertEq(moeda.balanceOf(comprador), BUYER_INITIAL_BALANCE - 1_000 ether);
    }
}
