// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IParticipacaoToken
/// @notice Interface used by `ParticipacaoTokenFactory` (to initialize clones) and by
/// `EmissaoGateway` (to attest/issue/pause), without those contracts depending on the
/// concrete `ParticipacaoToken` type or on the upgradeable lib.
interface IParticipacaoToken {
    /// @notice Initializes the newly created clone (runs on the clone, never on the template; see
    /// `ParticipacaoToken._disableInitializers` in the implementation's constructor).
    function initialize(
        string memory nome_,
        string memory simbolo_,
        address gateway_,
        address transferPolicy_,
        string memory empresa_,
        bytes32 cnpjRef_,
        string memory serie_
    ) external;

    /// @notice Raises (never lowers) the authorized share cap: the corporate attestation.
    function setCotasAutorizadas(uint256 novoTeto) external;

    /// @notice Mints shares to `to`, respecting `totalSupply() + amount <= cotasAutorizadas`.
    function mint(address to, uint256 amount) external;

    /// @notice Changes the transfer policy read on every holder→holder transfer
    /// (see `ParticipacaoToken.setTransferPolicy`, Phase 3).
    function setTransferPolicy(address novaPolitica) external;

    /// @notice Current policy, read on every holder→holder transfer (Phase 4:
    /// `LiquidacaoSecundaria` uses this getter for the `canTransfer` pre-flight).
    function transferPolicy() external view returns (address);

    function pause() external;
    function unpause() external;
}
