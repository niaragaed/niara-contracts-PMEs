// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockedAccessControl} from "../governance/TimelockedAccessControl.sol";

/// @title RegistroInvestidorQualificado
/// @notice Registro on-chain da flag de qualificação/sem-limite de cada investidor, atestada
/// pelo AGENTE. `OfertaCaptacao` consulta esta flag para decidir se aplica o
/// `tetoPorInvestidor` de uma oferta específica a um dado investidor.
/// @dev O teto ANUAL CRUZADO ENTRE PLATAFORMAS previsto na Resolução CVM 88 é OFF-CHAIN e
/// AUTO-DECLARATÓRIO. Esta flag é apenas a forma on-chain de uma verificação de suitability que
/// a plataforma já é obrigada a fazer off-chain — não é a plataforma decidindo arbitrariamente
/// quem "pode mais". Este contrato não tem, e não pode ter, visibilidade de aportes do mesmo
/// investidor em outras plataformas; nenhuma automação deve sugerir o contrário.
contract RegistroInvestidorQualificado is TimelockedAccessControl {
    /// @notice Papel operacional: agente/plataforma autorizado a definir a flag de
    /// qualificação. Gestão de quem detém este papel passa pelo timelock herdado (mesma
    /// disciplina de `EmissaoGateway`/`ParticipacaoTokenFactory`).
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    /// @notice `true` se `investidor` foi atestado como qualificado/sem-limite pelo AGENTE.
    mapping(address => bool) public ehQualificado;

    event QualificacaoAlterada(address indexed investidor, bool qualificado);

    error ZeroAddress();

    constructor(address admin_, uint256 timelockDelay_) TimelockedAccessControl(timelockDelay_) {
        if (admin_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Define a flag de qualificação de `investidor`. Ação operacional e imediata (sem
    /// timelock) — onboarding de investidor precisa ser ágil; a gestão de quem detém
    /// `AGENTE_ROLE` em si continua passando pelo timelock herdado.
    function definirQualificado(address investidor, bool qualificado) external onlyRole(AGENTE_ROLE) {
        ehQualificado[investidor] = qualificado;
        emit QualificacaoAlterada(investidor, qualificado);
    }
}
