// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEmissaoGateway
/// @notice Minimal interface used by `OfertaCaptacao` to trigger the fundraising-scoped mint,
/// without the escrow depending on the concrete `EmissaoGateway` type or on the
/// `TimelockedAccessControl`/`AccessControl` import chain.
interface IEmissaoGateway {
    /// @notice Mints `cotas` of `token` to `to`. Only runs if `msg.sender` is the
    /// `OfertaCaptacao` registered as authorized for that `token` (see
    /// `EmissaoGateway.registrarCaptacao`).
    function emitirParaCaptacao(address token, address to, uint256 cotas) external;
}
