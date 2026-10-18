// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockedAccessControl} from "../governance/TimelockedAccessControl.sol";

/// @title RegistroInvestidorQualificado (qualified investor registry)
/// @notice On-chain registry of each investor's qualified/uncapped flag, attested by the
/// AGENT. `OfertaCaptacao` reads this flag to decide whether to apply a specific offering's
/// `tetoPorInvestidor` to a given investor.
/// @dev The ANNUAL CAP ACROSS PLATFORMS set by CVM Resolution 88 is OFF-CHAIN and
/// SELF-DECLARED. This flag is only the on-chain form of a suitability check the platform
/// is already required to do off-chain; it is not the platform arbitrarily deciding who
/// "may invest more". This contract does not have, and cannot have, visibility into the same
/// investor's investments on other platforms; no automation should suggest otherwise.
contract RegistroInvestidorQualificado is TimelockedAccessControl {
    /// @notice Operational role: agent/platform authorized to set the qualification flag.
    /// Managing who holds this role goes through the inherited timelock (same discipline as
    /// `EmissaoGateway`/`ParticipacaoTokenFactory`).
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    /// @notice `true` if `investidor` was attested as qualified/uncapped by the AGENT.
    mapping(address => bool) public ehQualificado;

    event QualificacaoAlterada(address indexed investidor, bool qualificado);

    error ZeroAddress();

    constructor(address admin_, uint256 timelockDelay_) TimelockedAccessControl(timelockDelay_) {
        if (admin_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Sets `investidor`'s qualification flag. An operational, immediate action (no
    /// timelock): investor onboarding must be agile; managing who holds `AGENTE_ROLE` itself
    /// still goes through the inherited timelock.
    function definirQualificado(address investidor, bool qualificado) external onlyRole(AGENTE_ROLE) {
        ehQualificado[investidor] = qualificado;
        emit QualificacaoAlterada(investidor, qualificado);
    }
}
