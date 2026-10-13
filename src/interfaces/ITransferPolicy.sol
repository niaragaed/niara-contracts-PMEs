// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITransferPolicy
/// @notice Minimal interface read by `ParticipacaoToken` on every transfer between
/// holders (holder→holder). Mint (`from == address(0)`) and burn (`to == address(0)`) do not
/// go through the policy: they are governed by the `EmissaoGateway` roles, not by a transfer
/// rule. This separation keeps "never dilute beyond what was authorized" as a token
/// invariant and "who can transfer" as the policy's pluggable responsibility.
interface ITransferPolicy {
    /// @notice Checks whether `amount` of `token` can be transferred from `from` to `to`.
    /// @dev Called only for holder→holder transfers, never for mint/burn.
    function canTransfer(address token, address from, address to, uint256 amount) external view returns (bool);
}
