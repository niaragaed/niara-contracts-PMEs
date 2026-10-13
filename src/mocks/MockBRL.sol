// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockBRL
/// @notice TEST MOCK: NOT REAL MONEY, NOT BACKED AND NOT REPRESENTING THE BRAZILIAN
/// REAL. It exists only to simulate, on testnet, the currency used in the offerings'
/// investment escrow (escrow integration arrives in Phase 2). `mint` is public and
/// unrestricted on purpose; do not use it outside a test/demo environment.
/// @dev Uses 18 decimals (ERC-20 standard), not the usual 2 decimals of fiat BRL, a decision
/// documented in CLAUDE.md ("Locked decisions"). Simplicity and compatibility with the rest of
/// the system (ParticipacaoToken also uses 18 decimals) outweighed mirroring the usual cents
/// formatting, since this mock is not the source of truth for any value.
contract MockBRL is ERC20 {
    constructor() ERC20("Mock Real Brasileiro", "mBRL") {}

    /// @notice Mints `amount` mBRL to `to`. Unrestricted: for test use only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
