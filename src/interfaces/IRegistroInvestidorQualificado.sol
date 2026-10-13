// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRegistroInvestidorQualificado
/// @notice Interface used by `OfertaCaptacao` to read an investor's qualification flag,
/// without depending on the `TimelockedAccessControl` import chain.
interface IRegistroInvestidorQualificado {
    /// @notice `true` if `investidor` was attested as qualified/uncapped by the AGENT.
    function ehQualificado(address investidor) external view returns (bool);
}
