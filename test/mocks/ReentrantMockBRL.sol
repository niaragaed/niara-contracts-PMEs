// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Moeda maliciosa usada SÓ em testes: ao ser transferida para fora de um contrato
/// (`transfer`), tenta reentrar num alvo configurável antes de retornar. Simula uma stablecoin
/// de BRL real que, diferente de `MockBRL`, tivesse hook/callback — o gotcha documentado no
/// CLAUDE.md ("tratar como se a moeda pudesse ter callback") existe justamente para este caso.
contract ReentrantMockBRL is ERC20 {
    address public alvo;
    bytes public callDataAtaque;
    bool public ativo;
    bool public reentradaBloqueada;

    constructor() ERC20("Reentrant Mock BRL", "rBRL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Arma o próximo `transfer`/`transferFrom` para tentar reentrar `alvo` com
    /// `callData_` (calldata completo — selector + argumentos, ex.:
    /// `abi.encodeWithSelector(OfertaCaptacao.reembolsar.selector)`).
    function configurarAtaque(address alvo_, bytes calldata callData_) external {
        alvo = alvo_;
        callDataAtaque = callData_;
        ativo = true;
        reentradaBloqueada = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        _tentarReentrar();
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        _tentarReentrar();
        return ok;
    }

    function _tentarReentrar() internal {
        if (!ativo) return;
        ativo = false; // evita loop infinito na própria tentativa de ataque
        (bool success,) = alvo.call(callDataAtaque);
        reentradaBloqueada = !success;
    }
}
