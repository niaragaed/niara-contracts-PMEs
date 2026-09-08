// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Mock de teste: aceita `atestarCotas` como no-op (sempre sucesso) e reverte
/// deliberadamente em `registrarCaptacao`, para provar que
/// `OfertaOrquestrador.criarOfertaCompleta` desfaz atomicamente TODAS as subchamadas
/// anteriores (incluindo os dois `Clones.clone`) quando a quarta chamada falha.
/// @dev Não é possível forçar essa falha usando só os contratos reais: `EmissaoGateway.
/// registrarCaptacao` não tem nenhuma validação além do mesmo `AGENTE_ROLE` que já protege
/// `atestarCotas` (a segunda chamada) — então, com contratos reais, faltar o papel sempre
/// derrubaria a chamada 2, nunca isoladamente a 4ª. Este mock substitui só o `emissaoGateway`
/// de uma instância de `OfertaOrquestrador` dedicada a este teste; `tokenFactory` e
/// `captacaoFactory` continuam sendo os contratos reais.
contract MockEmissaoGatewayRevertaEmRegistrar {
    error FalhaForcadaParaTeste();

    function atestarCotas(address, uint256) external pure {}

    function registrarCaptacao(address, address) external pure {
        revert FalhaForcadaParaTeste();
    }
}
