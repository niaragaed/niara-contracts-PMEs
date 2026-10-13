// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockedAccessControl} from "../governance/TimelockedAccessControl.sol";
import {ITransferPolicy} from "../interfaces/ITransferPolicy.sol";

/// @title RestrictedTransferPolicy
/// @notice Phase 3's sophisticated policy: lock-up + eligible-investor allowlist + master
/// flag that opens the secondary market. Shared by every token that points at it: all state is
/// kept per `token` (see `ITransferPolicy.canTransfer`, which already receives the token address
/// in its signature), so a single instance of this contract serves any number of offerings with
/// no cloning.
/// @dev TESTNET PROTOTYPE, NO EXTERNAL AUDIT. Models the secondary-market restriction required by
/// CVM Resolution 88: REALLY turning on the secondary market depends on the period having elapsed
/// AND on authorization from the platform, a governance/business decision this contract only
/// executes (via `setSecundarioLiberado`, behind a timelock); the substance of that decision
/// (the regulatory/contractual "may") is always external to the code.
///
/// `canTransfer` is only called by the token on holder→holder transfers; mint/burn do not go
/// through here (see `ParticipacaoToken._update`). The `from` parameter is not used in the
/// logic: whoever already holds the token is a holder by construction (it only got there via
/// mint), so the only eligibility check that matters is on the recipient (`to`), who is the
/// one CVM 88 requires to be an active investor.
contract RestrictedTransferPolicy is TimelockedAccessControl, ITransferPolicy {
    /// @notice Same operational role as the platform's other pieces: allowlist/lock-up need
    /// agile onboarding, with no timelock on the action itself (managing who holds the role still
    /// goes through the inherited timelock).
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    /// @notice `true` once `definirLockup(token, ...)` has been called: makes the field below
    /// "set-once" without depending on an ambiguous sentinel value (a lock-up of `0` seconds,
    /// i.e. "no lock-up", is also a valid configuration).
    mapping(address => bool) public lockupDefinido;

    /// @notice Timestamp from which holder→holder transfers of `token` stop being blocked by the
    /// lock-up (still subject to the other conditions).
    mapping(address => uint64) public lockupAte;

    /// @notice `true` if `investidor` is on the eligible-recipient allowlist for `token`.
    mapping(address => mapping(address => bool)) public elegivel;

    /// @notice Master flag per token: the secondary market is off (`false`) by default. Turning
    /// it on is a governance act (timelock), not an operational one.
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

    /// @notice Checks whether a holder→holder transfer of `token` is allowed: requires (1) the
    /// secondary market open, (2) outside the lock-up period and (3) an eligible recipient, in
    /// that order, all required.
    function canTransfer(address token, address, address to, uint256) external view returns (bool) {
        if (!secundarioLiberado[token]) return false;
        if (block.timestamp < lockupAte[token]) return false;
        if (!elegivel[token][to]) return false;
        return true;
    }

    // ── Operacional (AGENTE, imediato) ─────────────────────────────────────────────────────

    /// @notice Sets whether `investidor` is an eligible recipient of `token` transfers.
    function definirElegivel(address token, address investidor, bool estaElegivel) external onlyRole(AGENTE_ROLE) {
        elegivel[token][investidor] = estaElegivel;
        emit ElegibilidadeAlterada(token, investidor, estaElegivel);
    }

    /// @notice Sets `token`'s lock-up, only once: the "deadline written into the offering".
    /// Any later change to that first setting would require a separate mechanism (none exists in
    /// this phase): once fixed, the period is final.
    function definirLockup(address token, uint64 novoLockupAte) external onlyRole(AGENTE_ROLE) {
        if (lockupDefinido[token]) revert LockupJaDefinido(lockupAte[token]);
        lockupDefinido[token] = true;
        lockupAte[token] = novoLockupAte;
        emit LockupDefinido(token, novoLockupAte);
    }

    // ── Governed by timelock (sensitive decision: actually opens the secondary market) ──────

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
