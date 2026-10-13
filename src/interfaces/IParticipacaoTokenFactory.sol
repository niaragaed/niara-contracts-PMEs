// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IParticipacaoTokenFactory
/// @notice Minimal interface used by `LiquidacaoSecundaria` (Phase 4) to validate that a
/// token is a genuine offering of this platform before settling an assignment, without
/// depending on the concrete `ParticipacaoTokenFactory` type.
interface IParticipacaoTokenFactory {
    /// @notice `true` for every token address already created by this factory.
    function isOferta(address token) external view returns (bool);
}
