// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITransferPolicy} from "../interfaces/ITransferPolicy.sol";

/// @title DenyAllTransferPolicy
/// @notice Política-padrão da Fase 1: nega toda transferência titular→titular. O mercado
/// secundário fica totalmente desligado — cotas só se movem por mint (captação) e, no futuro,
/// por caminhos explícitos ainda não implementados. Substituível por governança (via troca do
/// endereço de política, ver `ParticipacaoTokenFactory`) sem tocar no token; a política
/// sofisticada (lock-up + allowlist + flag de liberação) é Fase 3.
contract DenyAllTransferPolicy is ITransferPolicy {
    /// @notice Sempre retorna `false` — nenhuma transferência titular→titular é permitida.
    function canTransfer(address, address, address, uint256) external pure returns (bool) {
        return false;
    }
}
