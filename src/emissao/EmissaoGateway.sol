// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockedAccessControl} from "../governance/TimelockedAccessControl.sol";
import {IParticipacaoToken} from "../interfaces/IParticipacaoToken.sol";

/// @title EmissaoGateway
/// @notice Coordena on-chain a emissão de cotas: atesta o teto autorizado (`atestarCotas`)
/// antes de liberar a cunhagem (`emitir`) — mesmo padrão atestar→mintar do `BackingGateway` da
/// exchange (`niara-contracts`, ver Linhagem no CLAUDE.md), adaptado de "lastro custodiado"
/// para "cotas autorizadas em ato societário".
/// @dev Detém o papel operacional único desta fase (`AGENTE_ROLE`) sobre qualquer
/// `ParticipacaoToken` que aponte este contrato como `gateway`. Gestão de papéis passa pelo
/// timelock herdado de `TimelockedAccessControl`.
contract EmissaoGateway is TimelockedAccessControl {
    /// @notice Papel operacional: agente/plataforma autorizado a atestar, emitir e pausar
    /// tokens de oferta.
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    /// @notice Papel reservado para ações futuras específicas da empresa emissora (ex.:
    /// propor a própria oferta). Sem uso funcional nesta fase — ver "Pendências conhecidas"
    /// no CLAUDE.md.
    bytes32 public constant EMISSOR_ROLE = keccak256("EMISSOR_ROLE");

    event CotasAtestadas(address indexed token, uint256 novoTeto);
    event CotasEmitidasViaGateway(address indexed token, address indexed to, uint256 amount);
    event TokenPausado(address indexed token);
    event TokenDespausado(address indexed token);

    error ZeroAddress();

    constructor(address admin_, uint256 timelockDelay_) TimelockedAccessControl(timelockDelay_) {
        if (admin_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Eleva o teto de cotas autorizadas de `token` para `novoTeto`.
    function atestarCotas(address token, uint256 novoTeto) external onlyRole(AGENTE_ROLE) {
        IParticipacaoToken(token).setCotasAutorizadas(novoTeto);
        emit CotasAtestadas(token, novoTeto);
    }

    /// @notice Cunha `amount` de `token` para `to`, dentro do teto já atestado.
    function emitir(address token, address to, uint256 amount) external onlyRole(AGENTE_ROLE) {
        IParticipacaoToken(token).mint(to, amount);
        emit CotasEmitidasViaGateway(token, to, amount);
    }

    /// @notice Pausa `token` em caso de emergência.
    function pausarToken(address token) external onlyRole(AGENTE_ROLE) {
        IParticipacaoToken(token).pause();
        emit TokenPausado(token);
    }

    /// @notice Remove a pausa de `token`.
    function despausarToken(address token) external onlyRole(AGENTE_ROLE) {
        IParticipacaoToken(token).unpause();
        emit TokenDespausado(token);
    }
}
