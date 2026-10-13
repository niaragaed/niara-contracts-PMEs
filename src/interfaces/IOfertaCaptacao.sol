// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IOfertaCaptacao
/// @notice Interface used by `OfertaCaptacaoFactory` to initialize the newly created clone,
/// without the factory depending on the concrete `OfertaCaptacao` type or on the
/// `PausableUpgradeable`/`ReentrancyGuard` import chain.
interface IOfertaCaptacao {
    /// @dev Grouped in a struct (instead of 12 loose parameters) to avoid "stack too deep"
    /// in `initialize`; `via_ir` is off in this project (see foundry.toml).
    struct InitParams {
        address token;
        address gateway;
        address registro;
        address moeda;
        address emissorWallet;
        address protocoloWallet;
        uint256 metaMinima;
        uint256 metaMaxima;
        uint256 precoPorCota;
        uint256 prazo;
        uint256 tetoPorInvestidor;
        uint256 taxaBps;
    }

    /// @notice Initializes the newly created clone (runs on the clone, never on the template; see
    /// `OfertaCaptacao._disableInitializers` in the implementation's constructor).
    function initialize(InitParams calldata params) external;
}
