// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockHarness} from "./mocks/TimelockHarness.sol";
import {TimelockedAccessControl} from "../src/governance/TimelockedAccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice `token.SOME_ROLE()` and similar are external calls (staticcall): if they appear
/// on the same line as a `vm.prank`/`vm.expectRevert` meant for another call, they "steal"
/// the cheatcode (which only applies to the next external call). That is why every role
/// bytes32 is resolved into a variable outside any prank.
contract TimelockedAccessControlTest is Test {
    TimelockHarness public harness;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");

    uint256 public constant TIMELOCK_DELAY = 2 days;
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public constant SOME_ROLE = keccak256("SOME_ROLE");

    function setUp() public {
        harness = new TimelockHarness(admin, TIMELOCK_DELAY);
    }

    // ── Construtor ──────────────────────────────────────────────────────────────────────

    function test_Constructor_RevertsForDelayBelowMin() public {
        uint256 tooLow = harness.MIN_TIMELOCK_DELAY() - 1;
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.InvalidTimelockDelay.selector, tooLow));
        new TimelockHarness(admin, tooLow);
    }

    function test_Constructor_RevertsForDelayAboveMax() public {
        uint256 tooHigh = harness.MAX_TIMELOCK_DELAY() + 1;
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.InvalidTimelockDelay.selector, tooHigh));
        new TimelockHarness(admin, tooHigh);
    }

    function test_Constructor_AcceptsMinDelay() public {
        TimelockHarness h = new TimelockHarness(admin, harness.MIN_TIMELOCK_DELAY());
        assertEq(h.timelockDelay(), harness.MIN_TIMELOCK_DELAY());
    }

    // ── Timelock delay ──────────────────────────────────────────────────────────────────

    function test_SetTimelockDelay_RevertsForOutOfBoundsProposal() public {
        uint256 tooHigh = harness.MAX_TIMELOCK_DELAY() + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.InvalidTimelockDelay.selector, tooHigh));
        harness.proposeSetTimelockDelay(tooHigh);
    }

    function test_SetTimelockDelay_RevertsBeforeDelayElapses() public {
        uint256 newDelay = 5 days;
        vm.prank(admin);
        harness.proposeSetTimelockDelay(newDelay);

        bytes32 actionId = keccak256(abi.encode("SET_TIMELOCK_DELAY", newDelay));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockedAccessControl.TimelockNotElapsed.selector, actionId, block.timestamp + TIMELOCK_DELAY
            )
        );
        harness.executeSetTimelockDelay(newDelay);
    }

    function test_SetTimelockDelay_SucceedsAfterDelay() public {
        uint256 newDelay = 5 days;
        vm.prank(admin);
        harness.proposeSetTimelockDelay(newDelay);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        harness.executeSetTimelockDelay(newDelay);

        assertEq(harness.timelockDelay(), newDelay);
    }

    function test_SetTimelockDelay_RevertsForNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, DEFAULT_ADMIN_ROLE)
        );
        harness.proposeSetTimelockDelay(5 days);
    }

    // ── Generic propose/execute ─────────────────────────────────────────────────────────

    function test_ProposeAction_RevertsIfAlreadyPending() public {
        uint256 newDelay = 5 days;
        vm.prank(admin);
        harness.proposeSetTimelockDelay(newDelay);

        bytes32 actionId = keccak256(abi.encode("SET_TIMELOCK_DELAY", newDelay));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.ActionAlreadyPending.selector, actionId));
        harness.proposeSetTimelockDelay(newDelay);
    }

    function test_ExecuteAction_RevertsIfNotPending() public {
        bytes32 actionId = keccak256(abi.encode("SET_TIMELOCK_DELAY", uint256(5 days)));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.ActionNotPending.selector, actionId));
        harness.executeSetTimelockDelay(5 days);
    }

    function test_CancelAction_ClearsPendingProposal() public {
        uint256 newDelay = 5 days;
        vm.prank(admin);
        harness.proposeSetTimelockDelay(newDelay);

        bytes32 actionId = keccak256(abi.encode("SET_TIMELOCK_DELAY", newDelay));
        vm.prank(admin);
        harness.cancelAction(actionId);

        assertEq(harness.pendingActions(actionId), 0);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.ActionNotPending.selector, actionId));
        harness.executeSetTimelockDelay(newDelay);
    }

    function test_CancelAction_RevertsIfNotPending() public {
        bytes32 actionId = keccak256(abi.encode("SET_TIMELOCK_DELAY", uint256(5 days)));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockedAccessControl.ActionNotPending.selector, actionId));
        harness.cancelAction(actionId);
    }

    function test_CancelAction_RevertsForNonAdmin() public {
        vm.prank(admin);
        harness.proposeSetTimelockDelay(5 days);
        bytes32 actionId = keccak256(abi.encode("SET_TIMELOCK_DELAY", uint256(5 days)));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, DEFAULT_ADMIN_ROLE)
        );
        harness.cancelAction(actionId);
    }

    // ── Standard grantRole/revokeRole disabled ─────────────────────────────────────────

    function test_GrantRole_AlwaysReverts() public {
        vm.expectRevert(TimelockedAccessControl.RoleChangeRequiresTimelock.selector);
        harness.grantRole(SOME_ROLE, alice);
    }

    function test_RevokeRole_AlwaysReverts() public {
        vm.expectRevert(TimelockedAccessControl.RoleChangeRequiresTimelock.selector);
        harness.revokeRole(SOME_ROLE, alice);
    }

    // ── proposeGrantRole/executeGrantRole ───────────────────────────────────────────────

    function test_GrantRole_ViaTimelock_Succeeds() public {
        vm.prank(admin);
        harness.proposeGrantRole(SOME_ROLE, alice);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        harness.executeGrantRole(SOME_ROLE, alice);

        assertTrue(harness.hasRole(SOME_ROLE, alice));
    }

    function test_RevokeRole_ViaTimelock_Succeeds() public {
        vm.prank(admin);
        harness.proposeGrantRole(SOME_ROLE, alice);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        harness.executeGrantRole(SOME_ROLE, alice);

        vm.prank(admin);
        harness.proposeRevokeRole(SOME_ROLE, alice);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        harness.executeRevokeRole(SOME_ROLE, alice);

        assertFalse(harness.hasRole(SOME_ROLE, alice));
    }

    function test_RenounceRole_WorksWithoutTimelock() public {
        vm.prank(admin);
        harness.proposeGrantRole(SOME_ROLE, alice);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        harness.executeGrantRole(SOME_ROLE, alice);

        vm.prank(alice);
        harness.renounceRole(SOME_ROLE, alice);

        assertFalse(harness.hasRole(SOME_ROLE, alice));
    }
}
