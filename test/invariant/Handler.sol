// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParticipacaoTokenFactory} from "../../src/token/ParticipacaoTokenFactory.sol";
import {ParticipacaoToken} from "../../src/token/ParticipacaoToken.sol";
import {EmissaoGateway} from "../../src/emissao/EmissaoGateway.sol";

/// @notice Stateful fuzzing actor: exposes one action per public function (create offering,
/// attest, issue, try to transfer, try to bypass `onlyGateway`/`AGENTE_ROLE`/double
/// initialization, pauses) so Foundry's invariant engine explores random sequences of these
/// steps.
/// @dev Mirrors the design of `niara-contracts/test/invariant/Handler.sol` (see Lineage in
/// CLAUDE.md): most calls use parameters bounded (`bound`) to valid states; a fraction
/// (`_chaos`, ~1 in 5) deliberately takes the invalid path. External calls are not wrapped in
/// try/catch: with `fail_on_revert = false` (see foundry.toml), a genuine revert is tolerated
/// by the runner and atomically undoes any side effect of this call, including the "ghost"
/// variables below. A "ghost" only becomes `true` when a call that SHOULD revert (access
/// violation, double initialization, forbidden transfer) ends without reverting, i.e. when the
/// corresponding invariant was actually broken.
contract Handler is Test {
    ParticipacaoTokenFactory public factory;
    EmissaoGateway public gateway;

    address public admin;
    address public agent;
    address[] public actors;

    address[] public tokens;

    /// @notice Becomes `true` if the token's `mint`/`setCotasAutorizadas`/`pause`/`unpause` are
    /// called successfully by anyone other than the configured `gateway`.
    bool public ghost_unauthorizedTokenCallSucceeded;

    /// @notice Becomes `true` if the gateway's `atestarCotas`/`emitir`/`pausarToken`/
    /// `despausarToken`, or the factory's `criarOferta`, are called successfully by someone
    /// without `AGENTE_ROLE`.
    bool public ghost_unauthorizedRoleCallSucceeded;

    /// @notice Becomes `true` if any holder→holder transfer (`transfer`/`transferFrom`)
    /// succeeds; the `DenyAllTransferPolicy` should always deny.
    bool public ghost_transferSucceeded;

    /// @notice Becomes `true` if `initialize` can be called a second time on an already
    /// initialized clone.
    bool public ghost_reinitializeSucceeded;

    struct Config {
        ParticipacaoTokenFactory factory;
        EmissaoGateway gateway;
        address admin;
        address agent;
        address[] actors;
    }

    constructor(Config memory config) {
        factory = config.factory;
        gateway = config.gateway;
        admin = config.admin;
        agent = config.agent;
        actors = config.actors;
    }

    // ── Selection helpers ──────────────────────────────────────────────────────────────

    function _actorAt(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _distinctActor(uint256 seed, address other) internal view returns (address) {
        uint256 idx = seed % actors.length;
        address candidate = actors[idx];
        if (candidate == other) {
            candidate = actors[(idx + 1) % actors.length];
        }
        return candidate;
    }

    function _pickToken(uint256 seed) internal view returns (ParticipacaoToken) {
        return ParticipacaoToken(tokens[seed % tokens.length]);
    }

    /// @dev ~1 in 5 calls takes the "chaotic" path (invalid on purpose).
    function _chaos(uint256 seed) internal pure returns (bool) {
        return seed % 5 == 0;
    }

    // ── Offering creation ───────────────────────────────────────────────────────────────

    function criarOferta(uint256 seed, uint256 chaosSeed) external {
        address caller = _chaos(chaosSeed) ? _actorAt(chaosSeed) : agent;

        string memory nome = string(abi.encodePacked("Oferta ", vm.toString(seed)));
        string memory simbolo = string(abi.encodePacked("nOF", vm.toString(seed % 1000)));
        string memory empresa = string(abi.encodePacked("Empresa ", vm.toString(seed)));
        bytes32 cnpjRef = keccak256(abi.encode("cnpj", seed));
        string memory serie = vm.toString(seed % 100);

        vm.prank(caller);
        address token = factory.criarOferta(nome, simbolo, empresa, cnpjRef, serie);
        tokens.push(token);

        if (caller != agent) ghost_unauthorizedRoleCallSucceeded = true;
    }

    // ── Attestation and issuance ────────────────────────────────────────────────────────

    function atestarCotas(uint256 tokenSeed, uint256 newCapSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        ParticipacaoToken token = _pickToken(tokenSeed);
        uint256 atual = token.cotasAutorizadas();

        bool chaos = _chaos(chaosSeed);
        uint256 novoTeto =
            chaos ? newCapSeed % (atual == 0 ? 1 : atual) : bound(newCapSeed, atual, atual + 1_000_000 ether);
        address caller = chaos && chaosSeed % 2 == 0 ? _actorAt(chaosSeed) : agent;

        vm.prank(caller);
        gateway.atestarCotas(address(token), novoTeto);

        if (caller != agent) ghost_unauthorizedRoleCallSucceeded = true;
    }

    function emitir(uint256 tokenSeed, uint256 toSeed, uint256 amountSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        ParticipacaoToken token = _pickToken(tokenSeed);
        address to = _actorAt(toSeed);

        uint256 remaining = token.cotasAutorizadas() - token.totalSupply();
        bool chaos = _chaos(chaosSeed);

        uint256 amount;
        if (chaos) {
            amount = amountSeed % (2 * (remaining == 0 ? 1 ether : remaining) + 1); // may exceed the remainder, including zero.
        } else {
            if (remaining == 0) return;
            amount = bound(amountSeed, 1, remaining);
        }

        address caller = chaos && chaosSeed % 2 == 0 ? _actorAt(chaosSeed) : agent;

        vm.prank(caller);
        gateway.emitir(address(token), to, amount);

        if (caller != agent) ghost_unauthorizedRoleCallSucceeded = true;
    }

    // ── Pausas ──────────────────────────────────────────────────────────────────────────

    function pauseOrUnpauseToken(uint256 tokenSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        ParticipacaoToken token = _pickToken(tokenSeed);
        bool isPaused = token.paused();
        address caller = _chaos(chaosSeed) ? _actorAt(chaosSeed) : agent;

        vm.prank(caller);
        if (isPaused) {
            gateway.despausarToken(address(token));
        } else {
            gateway.pausarToken(address(token));
        }

        if (caller != agent) ghost_unauthorizedRoleCallSucceeded = true;
    }

    function pauseOrUnpauseFactory(uint256 chaosSeed) external {
        bool isPaused = factory.paused();
        address caller = _chaos(chaosSeed) ? _actorAt(chaosSeed) : agent;

        vm.prank(caller);
        if (isPaused) {
            factory.unpause();
        } else {
            factory.pause();
        }

        if (caller != agent) ghost_unauthorizedRoleCallSucceeded = true;
    }

    // ── Holder→holder transfer attempts (should always revert) ────────────────────────────

    function tryTransfer(uint256 tokenSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        if (tokens.length == 0) return;
        ParticipacaoToken token = _pickToken(tokenSeed);
        address from = _actorAt(fromSeed);
        address to = _distinctActor(toSeed, from);

        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);

        vm.prank(from);
        token.transfer(to, amount);

        // Only reaches here if it did NOT revert: the deny-all policy was violated.
        ghost_transferSucceeded = true;
    }

    function tryTransferFrom(uint256 tokenSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        if (tokens.length == 0) return;
        ParticipacaoToken token = _pickToken(tokenSeed);
        address from = _actorAt(fromSeed);
        address to = _distinctActor(toSeed, from);

        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);

        vm.prank(from);
        token.approve(to, amount);

        vm.prank(to);
        token.transferFrom(from, to, amount);

        ghost_transferSucceeded = true;
    }

    // ── Tentativas de burlar onlyGateway direto no token ───────────────────────────────

    function tryCallRestrictedOnToken(uint256 tokenSeed, uint256 actorSeed, uint256 actionSeed) external {
        if (tokens.length == 0) return;
        ParticipacaoToken token = _pickToken(tokenSeed);
        address actor_ = _actorAt(actorSeed);
        uint256 action = actionSeed % 4;

        vm.prank(actor_);
        if (action == 0) {
            token.mint(actor_, 1);
        } else if (action == 1) {
            token.setCotasAutorizadas(token.cotasAutorizadas() + 1);
        } else if (action == 2) {
            token.pause();
        } else {
            token.unpause();
        }

        // Only reaches here if it did NOT revert: `onlyGateway` was bypassed.
        ghost_unauthorizedTokenCallSucceeded = true;
    }

    // ── Attempt to reinitialize an already initialized clone ────────────────────────────

    function tryReinitialize(uint256 tokenSeed) external {
        if (tokens.length == 0) return;
        ParticipacaoToken token = _pickToken(tokenSeed);

        token.initialize("X", "X", address(gateway), address(gateway), "X", bytes32(0), "X");

        // Only reaches here if it did NOT revert: double initialization was allowed.
        ghost_reinitializeSucceeded = true;
    }

    // ── Views for InvariantTest ─────────────────────────────────────────────────────────

    function numTokens() external view returns (uint256) {
        return tokens.length;
    }

    function numActors() external view returns (uint256) {
        return actors.length;
    }
}
