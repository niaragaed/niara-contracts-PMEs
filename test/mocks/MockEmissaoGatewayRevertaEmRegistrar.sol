// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test mock: accepts `atestarCotas` as a no-op (always succeeds) and deliberately
/// reverts on `registrarCaptacao`, to prove that `OfertaOrquestrador.criarOfertaCompleta`
/// atomically undoes ALL earlier subcalls (including both `Clones.clone` calls) when the
/// fourth call fails.
/// @dev This failure cannot be forced with the real contracts only: `EmissaoGateway.
/// registrarCaptacao` has no validation beyond the same `AGENTE_ROLE` that already protects
/// `atestarCotas` (the second call), so with real contracts a missing role would always take
/// down call 2, never the 4th in isolation. This mock replaces only the `emissaoGateway` of an
/// `OfertaOrquestrador` instance dedicated to this test; `tokenFactory` and `captacaoFactory`
/// are still the real contracts.
contract MockEmissaoGatewayRevertaEmRegistrar {
    error ForcedTestFailure();

    function atestarCotas(address, uint256) external pure {}

    function registrarCaptacao(address, address) external pure {
        revert ForcedTestFailure();
    }
}
