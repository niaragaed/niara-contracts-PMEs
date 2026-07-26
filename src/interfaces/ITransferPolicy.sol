// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITransferPolicy
/// @notice Interface mínima consultada por `ParticipacaoToken` a cada transferência entre
/// titulares (titular→titular). Mint (`from == address(0)`) e burn (`to == address(0)`) não
/// passam pela política — são governados pelos papéis do `EmissaoGateway`, não por regra de
/// transferência. Essa separação mantém "não diluir além do autorizado" como invariante do
/// token e "quem pode transferir" como responsabilidade plugável da política.
interface ITransferPolicy {
    /// @notice Verifica se `amount` de `token` pode ser transferido de `from` para `to`.
    /// @dev Chamada apenas para transferências titular→titular — nunca para mint/burn.
    function canTransfer(address token, address from, address to, uint256 amount) external view returns (bool);
}
