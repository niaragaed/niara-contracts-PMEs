// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IParticipacaoToken
/// @notice Interface consumida por `ParticipacaoTokenFactory` (para inicializar clones) e por
/// `EmissaoGateway` (para atestar/emitir/pausar), sem que esses contratos precisem depender do
/// tipo concreto `ParticipacaoToken` nem da lib upgradeable.
interface IParticipacaoToken {
    /// @notice Inicializa o clone recém-criado (roda no clone, nunca no template — ver
    /// `ParticipacaoToken._disableInitializers` no construtor da implementação).
    function initialize(
        string memory nome_,
        string memory simbolo_,
        address gateway_,
        address transferPolicy_,
        string memory empresa_,
        bytes32 cnpjRef_,
        string memory serie_
    ) external;

    /// @notice Eleva (nunca reduz) o teto de cotas autorizadas — a atestação societária.
    function setCotasAutorizadas(uint256 novoTeto) external;

    /// @notice Cunha cotas para `to`, respeitando `totalSupply() + amount <= cotasAutorizadas`.
    function mint(address to, uint256 amount) external;

    function pause() external;
    function unpause() external;
}
