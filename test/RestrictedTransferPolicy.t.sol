// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";

contract RestrictedTransferPolicyTest is Test {
    RestrictedTransferPolicy public policy;

    address public admin = makeAddr("admin");
    address public agent = makeAddr("agente");
    address public stranger = makeAddr("estranho");
    address public tokenA = makeAddr("tokenA");
    address public tokenB = makeAddr("tokenB");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public agentRole;

    function setUp() public {
        policy = new RestrictedTransferPolicy(admin, TIMELOCK_DELAY);
        agentRole = policy.AGENTE_ROLE();
        _grantRole(agentRole, agent);
    }

    function _grantRole(bytes32 role, address account) internal {
        vm.prank(admin);
        policy.proposeGrantRole(role, account);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        policy.executeGrantRole(role, account);
    }

    function _releaseSecondary(address token) internal {
        vm.prank(admin);
        policy.proposeSetSecundarioLiberado(token, true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        policy.executeSetSecundarioLiberado(token, true);
    }

    // ── Construtor ──────────────────────────────────────────────────────────────────────

    function test_Constructor_RevertsForZeroAdmin() public {
        vm.expectRevert(RestrictedTransferPolicy.ZeroAddress.selector);
        new RestrictedTransferPolicy(address(0), TIMELOCK_DELAY);
    }

    // ── Tabela-verdade de canTransfer ───────────────────────────────────────────────────

    function test_CanTransfer_FalseByDefault_SecondaryOff() public view {
        assertFalse(policy.canTransfer(tokenA, alice, bob, 1 ether));
    }

    function test_CanTransfer_FalseDuringLockup_EvenIfOpen() public {
        _releaseSecondary(tokenA);
        vm.prank(agent);
        policy.definirLockup(tokenA, uint64(block.timestamp + 30 days));
        vm.prank(agent);
        policy.definirElegivel(tokenA, bob, true);

        assertFalse(policy.canTransfer(tokenA, alice, bob, 1 ether));
    }

    function test_CanTransfer_FalseAfterLockup_RecipientNotEligible() public {
        _releaseSecondary(tokenA);
        vm.prank(agent);
        policy.definirLockup(tokenA, uint64(block.timestamp + 30 days));

        vm.warp(block.timestamp + 30 days);

        assertFalse(policy.canTransfer(tokenA, alice, bob, 1 ether));
    }

    function test_CanTransfer_TrueAfterLockup_RecipientEligible() public {
        _releaseSecondary(tokenA);
        vm.prank(agent);
        policy.definirLockup(tokenA, uint64(block.timestamp + 30 days));
        vm.prank(agent);
        policy.definirElegivel(tokenA, bob, true);

        vm.warp(block.timestamp + 30 days);

        assertTrue(policy.canTransfer(tokenA, alice, bob, 1 ether));
    }

    function test_CanTransfer_TrueExactlyAtLockupEnd() public {
        uint64 lockupAte = uint64(block.timestamp + 30 days);
        _releaseSecondary(tokenA);
        vm.prank(agent);
        policy.definirLockup(tokenA, lockupAte);
        vm.prank(agent);
        policy.definirElegivel(tokenA, bob, true);

        vm.warp(lockupAte);

        assertTrue(policy.canTransfer(tokenA, alice, bob, 1 ether));
    }

    // ── Isolamento por token ────────────────────────────────────────────────────────────

    function test_CanTransfer_StateIsolatedPerToken() public {
        _releaseSecondary(tokenA);
        vm.prank(agent);
        policy.definirElegivel(tokenA, bob, true);
        // tokenB never had the secondary market opened nor eligibility set.

        assertTrue(policy.canTransfer(tokenA, alice, bob, 1 ether));
        assertFalse(policy.canTransfer(tokenB, alice, bob, 1 ether));
    }

    function test_DefinirLockup_StateIsolatedPerToken() public {
        vm.prank(agent);
        policy.definirLockup(tokenA, uint64(block.timestamp + 10 days));

        // tokenB is still "unset", so definirLockup on it must not revert.
        vm.prank(agent);
        policy.definirLockup(tokenB, uint64(block.timestamp + 20 days));

        assertEq(policy.lockupAte(tokenA), block.timestamp + 10 days);
        assertEq(policy.lockupAte(tokenB), block.timestamp + 20 days);
    }

    // ── definirElegivel ─────────────────────────────────────────────────────────────────

    function test_DefinirElegivel_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agentRole)
        );
        policy.definirElegivel(tokenA, bob, true);
    }

    function test_DefinirElegivel_SetsFlag() public {
        vm.prank(agent);
        policy.definirElegivel(tokenA, bob, true);
        assertTrue(policy.elegivel(tokenA, bob));

        vm.prank(agent);
        policy.definirElegivel(tokenA, bob, false);
        assertFalse(policy.elegivel(tokenA, bob));
    }

    function test_DefinirElegivel_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(policy));
        emit RestrictedTransferPolicy.ElegibilidadeAlterada(tokenA, bob, true);
        vm.prank(agent);
        policy.definirElegivel(tokenA, bob, true);
    }

    // ── definirLockup (set-once) ────────────────────────────────────────────────────────

    function test_DefinirLockup_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agentRole)
        );
        policy.definirLockup(tokenA, uint64(block.timestamp + 30 days));
    }

    function test_DefinirLockup_SetsValue() public {
        uint64 lockupAte = uint64(block.timestamp + 30 days);
        vm.prank(agent);
        policy.definirLockup(tokenA, lockupAte);
        assertEq(policy.lockupAte(tokenA), lockupAte);
        assertTrue(policy.lockupDefinido(tokenA));
    }

    function test_DefinirLockup_RevertsOnSecondAttempt() public {
        uint64 lockupAte = uint64(block.timestamp + 30 days);
        vm.prank(agent);
        policy.definirLockup(tokenA, lockupAte);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(RestrictedTransferPolicy.LockupJaDefinido.selector, lockupAte));
        policy.definirLockup(tokenA, uint64(block.timestamp + 60 days));
    }

    function test_DefinirLockup_ZeroIsAValidSetOnceValue() public {
        vm.prank(agent);
        policy.definirLockup(tokenA, 0);
        assertTrue(policy.lockupDefinido(tokenA));

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(RestrictedTransferPolicy.LockupJaDefinido.selector, 0));
        policy.definirLockup(tokenA, uint64(block.timestamp + 30 days));
    }

    function test_DefinirLockup_EmitsEvent() public {
        uint64 lockupAte = uint64(block.timestamp + 30 days);
        vm.expectEmit(true, true, true, true, address(policy));
        emit RestrictedTransferPolicy.LockupDefinido(tokenA, lockupAte);
        vm.prank(agent);
        policy.definirLockup(tokenA, lockupAte);
    }

    // ── setSecundarioLiberado (timelock) ────────────────────────────────────────────────

    function test_SetSecundarioLiberado_RequiresTimelock() public {
        vm.prank(admin);
        policy.proposeSetSecundarioLiberado(tokenA, true);

        vm.prank(admin);
        vm.expectRevert();
        policy.executeSetSecundarioLiberado(tokenA, true);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        policy.executeSetSecundarioLiberado(tokenA, true);

        assertTrue(policy.secundarioLiberado(tokenA));
    }

    function test_SetSecundarioLiberado_OnlyAdminCanPropose() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE
            )
        );
        policy.proposeSetSecundarioLiberado(tokenA, true);
    }

    function test_SetSecundarioLiberado_AgentCannotProposeDirectly() public {
        // AGENTE_ROLE is operational (allowlist/lock-up); it does not govern the master flag.
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, DEFAULT_ADMIN_ROLE)
        );
        policy.proposeSetSecundarioLiberado(tokenA, true);
    }
}
