// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";

contract DenyAllTransferPolicyTest is Test {
    DenyAllTransferPolicy public policy;

    function setUp() public {
        policy = new DenyAllTransferPolicy();
    }

    function testFuzz_CanTransfer_AlwaysFalse(address token, address from, address to, uint256 amount) public view {
        assertFalse(policy.canTransfer(token, from, to, amount));
    }
}
