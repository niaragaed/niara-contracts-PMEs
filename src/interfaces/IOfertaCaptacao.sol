// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IOfertaCaptacao
/// @notice Interface consumida por `OfertaCaptacaoFactory` para inicializar o clone recém
/// criado, sem que a factory precise depender do tipo concreto `OfertaCaptacao` nem da cadeia
/// de imports de `PausableUpgradeable`/`ReentrancyGuard`.
interface IOfertaCaptacao {
    /// @dev Agrupado em struct (em vez de 12 parâmetros soltos) para evitar "stack too deep"
    /// no `initialize` — `via_ir` está desligado neste projeto (ver foundry.toml).
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

    /// @notice Inicializa o clone recém-criado (roda no clone, nunca no template — ver
    /// `OfertaCaptacao._disableInitializers` no construtor da implementação).
    function initialize(InitParams calldata params) external;
}
