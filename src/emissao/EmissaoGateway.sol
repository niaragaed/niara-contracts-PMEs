// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockedAccessControl} from "../governance/TimelockedAccessControl.sol";
import {IParticipacaoToken} from "../interfaces/IParticipacaoToken.sol";

/// @title EmissaoGateway (issuance gateway)
/// @notice Coordinates share issuance on-chain: attests the authorized cap (`atestarCotas`)
/// before allowing minting (`emitir`). Same attest→mint pattern as the exchange's
/// `BackingGateway` (`niara-contracts`, see Lineage in CLAUDE.md), adapted from "custodied
/// backing" to "shares authorized by a corporate act".
/// @dev Holds this phase's single operational role (`AGENTE_ROLE`) over any
/// `ParticipacaoToken` that points at this contract as `gateway`. Role management goes through
/// the timelock inherited from `TimelockedAccessControl`.
contract EmissaoGateway is TimelockedAccessControl {
    /// @notice Operational role: agent/platform authorized to attest, issue and pause offering
    /// tokens.
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    /// @notice Role reserved for future actions specific to the issuing company (e.g.
    /// proposing its own offering). No functional use in this phase; see "Known open items"
    /// in CLAUDE.md.
    bytes32 public constant EMISSOR_ROLE = keccak256("EMISSOR_ROLE");

    /// @notice Fundraising (`OfertaCaptacao`) authorized to mint each token via
    /// `emitirParaCaptacao`, set by the AGENT after the fundraising is created (see "Mint
    /// authorization chain" in CLAUDE.md). Keeps the token with a single mint path even when a
    /// third-party escrow, not the AGENT directly, triggers the mint when the offering succeeds.
    mapping(address => address) public ofertaCaptacaoAutorizada;

    event CotasAtestadas(address indexed token, uint256 novoTeto);
    event CotasEmitidasViaGateway(address indexed token, address indexed to, uint256 amount);
    event TokenPausado(address indexed token);
    event TokenDespausado(address indexed token);
    event CaptacaoRegistrada(address indexed token, address indexed oferta);
    event CotasEmitidasViaCaptacao(address indexed token, address indexed to, uint256 amount);
    event TransferPolicyChangeProposed(address indexed token, address indexed novaPolitica, uint256 executeAfter);
    event TransferPolicyChanged(address indexed token, address indexed novaPolitica);

    error ZeroAddress();
    error NaoAutorizado();

    constructor(address admin_, uint256 timelockDelay_) TimelockedAccessControl(timelockDelay_) {
        if (admin_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Raises the authorized share cap of `token` to `novoTeto`.
    function atestarCotas(address token, uint256 novoTeto) external onlyRole(AGENTE_ROLE) {
        IParticipacaoToken(token).setCotasAutorizadas(novoTeto);
        emit CotasAtestadas(token, novoTeto);
    }

    /// @notice Mints `amount` of `token` to `to`, within the cap already attested.
    function emitir(address token, address to, uint256 amount) external onlyRole(AGENTE_ROLE) {
        IParticipacaoToken(token).mint(to, amount);
        emit CotasEmitidasViaGateway(token, to, amount);
    }

    /// @notice Pauses `token` in an emergency.
    function pausarToken(address token) external onlyRole(AGENTE_ROLE) {
        IParticipacaoToken(token).pause();
        emit TokenPausado(token);
    }

    /// @notice Remove a pausa de `token`.
    function despausarToken(address token) external onlyRole(AGENTE_ROLE) {
        IParticipacaoToken(token).unpause();
        emit TokenDespausado(token);
    }

    /// @notice Sets `oferta` as the fundraising (`OfertaCaptacao` escrow) authorized to mint
    /// `token` via `emitirParaCaptacao`. Call it after creating the fundraising: only from then on
    /// can it mint the investors' shares on success (see the operational sequence in
    /// CLAUDE.md). Passing `address(0)` revokes the current authorization.
    function registrarCaptacao(address token, address oferta) external onlyRole(AGENTE_ROLE) {
        ofertaCaptacaoAutorizada[token] = oferta;
        emit CaptacaoRegistrada(token, oferta);
    }

    /// @notice Mints `cotas` of `token` to `to`; callable only by the `OfertaCaptacao`
    /// registered as authorized for that token (see `registrarCaptacao`). The token still
    /// checks `totalSupply() + cotas <= cotasAutorizadas`: the Phase 1 invariant stays
    /// load-bearing regardless of who triggered the mint.
    function emitirParaCaptacao(address token, address to, uint256 cotas) external {
        if (msg.sender != ofertaCaptacaoAutorizada[token]) revert NaoAutorizado();
        IParticipacaoToken(token).mint(to, cotas);
        emit CotasEmitidasViaCaptacao(token, to, cotas);
    }

    // ── Changing a token's transfer policy (subject to the timelock: a sensitive decision,
    // see "Phase 3 architecture" in CLAUDE.md) ─────────────────────────────────────────────
    //
    // `ParticipacaoToken` had no governed policy setter until Phase 3. It was added to the
    // token itself (`setTransferPolicy`, restricted to `onlyGateway`) because changing the
    // factory's policy (`transferPolicyPadrao`) only affects future offerings, and Phase 3
    // needs to be able to migrate an already-live offering from `DenyAllTransferPolicy` to
    // `RestrictedTransferPolicy` (see CLAUDE.md, section "Known open items").

    function proposeSetTransferPolicy(address token, address novaPolitica)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (token == address(0) || novaPolitica == address(0)) revert ZeroAddress();
        bytes32 actionId = keccak256(abi.encode("SET_TRANSFER_POLICY", token, novaPolitica));
        executeAfter = _scheduleAction(actionId);
        emit TransferPolicyChangeProposed(token, novaPolitica, executeAfter);
    }

    function executeSetTransferPolicy(address token, address novaPolitica) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 actionId = keccak256(abi.encode("SET_TRANSFER_POLICY", token, novaPolitica));
        _consumeAction(actionId);
        IParticipacaoToken(token).setTransferPolicy(novaPolitica);
        emit TransferPolicyChanged(token, novaPolitica);
    }
}
