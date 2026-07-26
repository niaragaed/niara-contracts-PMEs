// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEmissaoGateway
/// @notice Interface mínima consumida por `OfertaCaptacao` para acionar o mint escopado por
/// captação, sem que o escrow precise depender do tipo concreto `EmissaoGateway` nem da cadeia
/// de imports de `TimelockedAccessControl`/`AccessControl`.
interface IEmissaoGateway {
    /// @notice Cunha `cotas` de `token` para `to`. Só executa se `msg.sender` for a
    /// `OfertaCaptacao` registrada como autorizada para aquele `token` (ver
    /// `EmissaoGateway.registrarCaptacao`).
    function emitirParaCaptacao(address token, address to, uint256 cotas) external;
}
