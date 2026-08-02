// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IParticipacaoTokenFactory
/// @notice Interface mínima consumida por `LiquidacaoSecundaria` (Fase 4) para validar que um
/// token é uma oferta genuína desta plataforma antes de liquidar uma cessão, sem depender do
/// tipo concreto `ParticipacaoTokenFactory`.
interface IParticipacaoTokenFactory {
    /// @notice `true` para todo endereço de token já criado por esta factory.
    function isOferta(address token) external view returns (bool);
}
