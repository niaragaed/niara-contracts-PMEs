// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRegistroInvestidorQualificado
/// @notice Interface consumida por `OfertaCaptacao` para consultar a flag de qualificação de
/// um investidor, sem depender da cadeia de imports de `TimelockedAccessControl`.
interface IRegistroInvestidorQualificado {
    /// @notice `true` se `investidor` foi atestado como qualificado/sem-limite pelo AGENTE.
    function ehQualificado(address investidor) external view returns (bool);
}
