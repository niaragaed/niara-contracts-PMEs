// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockedAccessControl} from "../governance/TimelockedAccessControl.sol";
import {ITransferPolicy} from "../interfaces/ITransferPolicy.sol";

/// @title RestrictedTransferPolicy
/// @notice Política sofisticada da Fase 3: lock-up + allowlist de investidor elegível + flag
/// mestre de liberação do secundário. Compartilhada entre todos os tokens que apontarem para
/// ela — todo o estado é mantido por `token` (ver `ITransferPolicy.canTransfer`, que já recebe
/// o endereço do token na assinatura), então uma única instância deste contrato serve qualquer
/// número de ofertas sem precisar de clonagem.
/// @dev PROTÓTIPO EM TESTNET, SEM AUDITORIA EXTERNA. Modela a restrição de mercado secundário
/// exigida pela Resolução CVM 88 — ligar o secundário DE VERDADE depende de prazo cumprido E de
/// autorização da plataforma, uma decisão de governança/negócio que este contrato apenas
/// executa (via `setSecundarioLiberado`, atrás de timelock); a substância dessa decisão (o
/// "pode" regulatório/contratual) é sempre externa ao código.
///
/// `canTransfer` só é chamada pelo token em transferências titular→titular — mint/burn não
/// passam por aqui (ver `ParticipacaoToken._update`). O parâmetro `from` não é usado na lógica:
/// quem já detém o token é titular por construção (só chegou lá via mint), então a única
/// checagem de elegibilidade que importa é sobre o destinatário (`to`), que é quem a CVM 88
/// exige que seja investidor ativo.
contract RestrictedTransferPolicy is TimelockedAccessControl, ITransferPolicy {
    /// @notice Mesmo papel operacional das demais peças da plataforma — allowlist/lock-up
    /// precisam de onboarding ágil, sem timelock na ação em si (a gestão de quem detém o papel
    /// continua passando pelo timelock herdado).
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    /// @notice `true` uma vez que `definirLockup(token, ...)` já foi chamado — torna o campo
    /// abaixo "set-once" sem depender de um valor sentinela ambíguo (um lock-up de `0`
    /// segundos, ou seja "sem carência", também é uma configuração válida).
    mapping(address => bool) public lockupDefinido;

    /// @notice Timestamp a partir do qual transferências titular→titular de `token` deixam de
    /// ser barradas pela carência (ainda sujeitas às demais condições).
    mapping(address => uint64) public lockupAte;

    /// @notice `true` se `investidor` está na allowlist de destinatário elegível para `token`.
    mapping(address => mapping(address => bool)) public elegivel;

    /// @notice Flag mestre por token — secundário desligado (`false`) por padrão. Ligar é ato
    /// de governança (timelock), não operacional.
    mapping(address => bool) public secundarioLiberado;

    event ElegibilidadeAlterada(address indexed token, address indexed investidor, bool elegivel);
    event LockupDefinido(address indexed token, uint64 lockupAte);
    event SecundarioLiberadoChangeProposed(address indexed token, bool liberado, uint256 executeAfter);
    event SecundarioLiberadoChanged(address indexed token, bool liberado);

    error ZeroAddress();
    error LockupJaDefinido(uint64 atual);

    constructor(address admin_, uint256 timelockDelay_) TimelockedAccessControl(timelockDelay_) {
        if (admin_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Verifica se uma transferência titular→titular de `token` é permitida: exige (1)
    /// secundário liberado, (2) fora da carência de lock-up e (3) destinatário elegível — nessa
    /// ordem, todas necessárias.
    function canTransfer(address token, address, address to, uint256) external view returns (bool) {
        if (!secundarioLiberado[token]) return false;
        if (block.timestamp < lockupAte[token]) return false;
        if (!elegivel[token][to]) return false;
        return true;
    }

    // ── Operacional (AGENTE, imediato) ─────────────────────────────────────────────────────

    /// @notice Define se `investidor` é destinatário elegível de transferências de `token`.
    function definirElegivel(address token, address investidor, bool estaElegivel) external onlyRole(AGENTE_ROLE) {
        elegivel[token][investidor] = estaElegivel;
        emit ElegibilidadeAlterada(token, investidor, estaElegivel);
    }

    /// @notice Define a carência de `token`, uma única vez — o "prazo gravado na oferta".
    /// Qualquer alteração posterior a essa primeira definição exigiria um mecanismo à parte
    /// (não existe nesta fase): o prazo, uma vez fixado, é para valer.
    function definirLockup(address token, uint64 novoLockupAte) external onlyRole(AGENTE_ROLE) {
        if (lockupDefinido[token]) revert LockupJaDefinido(lockupAte[token]);
        lockupDefinido[token] = true;
        lockupAte[token] = novoLockupAte;
        emit LockupDefinido(token, novoLockupAte);
    }

    // ── Governado por timelock (decisão sensível: abre o secundário de fato) ──────────────

    function proposeSetSecundarioLiberado(address token, bool liberado)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        bytes32 actionId = keccak256(abi.encode("SET_SECUNDARIO_LIBERADO", token, liberado));
        executeAfter = _scheduleAction(actionId);
        emit SecundarioLiberadoChangeProposed(token, liberado, executeAfter);
    }

    function executeSetSecundarioLiberado(address token, bool liberado) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 actionId = keccak256(abi.encode("SET_SECUNDARIO_LIBERADO", token, liberado));
        _consumeAction(actionId);
        secundarioLiberado[token] = liberado;
        emit SecundarioLiberadoChanged(token, liberado);
    }
}
