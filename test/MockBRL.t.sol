// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";

/// @notice Teste trivial só para validar o harness Foundry (mint/saldo do MockBRL).
contract MockBRLTest is Test {
    MockBRL public brl;
    address public alice = makeAddr("alice");

    function setUp() public {
        brl = new MockBRL();
    }

    function test_MintIncreasesBalance() public {
        brl.mint(alice, 1_000 ether);
        assertEq(brl.balanceOf(alice), 1_000 ether);
    }

    function test_MetadataIsMock() public view {
        assertEq(brl.name(), "Mock Real Brasileiro");
        assertEq(brl.symbol(), "mBRL");
        assertEq(brl.decimals(), 18);
    }
}
