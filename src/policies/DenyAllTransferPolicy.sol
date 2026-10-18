// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITransferPolicy} from "../interfaces/ITransferPolicy.sol";

/// @title DenyAllTransferPolicy
/// @notice Phase 1 default policy: denies every holder→holder transfer. The secondary market
/// is fully off: shares only move by mint (fundraising) and, in the future, through explicit
/// paths not implemented yet. Replaceable by governance (by changing the policy address, see
/// `ParticipacaoTokenFactory`) without touching the token; the sophisticated policy (lock-up +
/// allowlist + release flag) is Phase 3.
contract DenyAllTransferPolicy is ITransferPolicy {
    /// @notice Always returns `false`: no holder→holder transfer is allowed.
    function canTransfer(address, address, address, uint256) external pure returns (bool) {
        return false;
    }
}
