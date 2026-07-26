// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockBRL
/// @notice MOCK DE TESTE — NÃO É DINHEIRO REAL, NÃO TEM LASTRO E NÃO REPRESENTA O REAL
/// brasileiro. Existe apenas para simular, em testnet, a moeda usada no escrow de aportes
/// das ofertas (a integração de escrow chega na Fase 2). `mint` é público e irrestrito de
/// propósito — não usar fora de ambiente de teste/demonstração.
/// @dev Usa 18 casas decimais (padrão ERC-20), não as 2 casas usuais do BRL fiat — decisão
/// documentada no CLAUDE.md ("Decisões travadas"). Simplicidade e compatibilidade com o
/// restante do sistema (ParticipacaoToken também usa 18 casas) pesaram mais do que espelhar
/// a formatação usual de centavos, já que este mock não é a fonte de verdade de valor algum.
contract MockBRL is ERC20 {
    constructor() ERC20("Mock Real Brasileiro", "mBRL") {}

    /// @notice Cunha `amount` de mBRL para `to`. Irrestrito — só para uso em testes.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
