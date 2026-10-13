// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ParticipacaoToken} from "../../src/token/ParticipacaoToken.sol";
import {EmissaoGateway} from "../../src/emissao/EmissaoGateway.sol";
import {RestrictedTransferPolicy} from "../../src/policies/RestrictedTransferPolicy.sol";

/// @notice Stateful fuzzing actor for the restricted-policy domain (Phase 3): creates tokens
/// already pointing at `RestrictedTransferPolicy`, mints an initial balance via `gateway.emitir`,
/// and exposes one action per piece of the `canTransfer` truth table (set eligibility, set
/// lock-up, open the secondary market, try to transfer) plus deliberate attempts to bypass
/// guards (`tentar*`). Same design as `test/invariant/Handler.sol`/`HandlerCaptacao.sol` (see
/// Lineage in CLAUDE.md): most calls use valid parameters; the `tentar*` ones take the invalid
/// path on purpose, without try/catch, and only flip a "ghost" to `true` when a call that
/// SHOULD revert ends without reverting.
///
/// `ghost_*Esperado` mirror, in the handler's memory, the state the handler itself wrote to
/// the policy; InvariantPoliticaTest compares them against the policy's real getters on every
/// invariant. Since each of the policy's mappings is keyed by `token`, that comparison proves
/// isolation between tokens "for free": if a write to `tokenA` leaked into `tokenB`, `tokenB`'s
/// mirror would diverge from the real state.
contract HandlerPolitica is Test {
    EmissaoGateway public gateway;
    RestrictedTransferPolicy public policy;
    ParticipacaoToken public tokenImplementation;

    address public admin;
    address public agent;
    address[] public actors;

    address[] public tokens;

    mapping(address => bool) public ghost_expectedSecondaryOpen;
    mapping(address => uint64) public ghost_expectedLockupUntil;
    mapping(address => mapping(address => bool)) public ghost_expectedEligible;

    /// @notice Becomes `true` if a holder→holder transfer has a result (success/revert)
    /// different from what the truth table predicts (secundarioLiberado && !lockup &&
    /// elegivel[to]): the core proof of Phase 3.
    bool public ghost_truthTableViolated;

    /// @notice Becomes `true` if `definirElegivel`/`definirLockup` succeed when called by someone
    /// without `AGENTE_ROLE`.
    bool public ghost_unauthorizedOperationalCallSucceeded;

    /// @notice Becomes `true` if `proposeSetSecundarioLiberado` succeeds when called by someone
    /// without `DEFAULT_ADMIN_ROLE`.
    bool public ghost_unauthorizedSecondaryToggleSucceeded;

    /// @notice Becomes `true` if a second `definirLockup` on the same token succeeds
    /// (it would violate "set-once").
    bool public ghost_doubleLockupSucceeded;

    /// @notice Becomes `true` if `gateway.emitir` (mint, within the attested cap) reverts only
    /// because of the attached `RestrictedTransferPolicy`'s state; mint should never read the
    /// policy (see `ParticipacaoToken._update`, `from == address(0)`).
    bool public ghost_mintFailedUnexpectedly;

    struct Config {
        EmissaoGateway gateway;
        RestrictedTransferPolicy policy;
        ParticipacaoToken tokenImplementation;
        address admin;
        address agent;
        address[] actors;
    }

    constructor(Config memory config) {
        gateway = config.gateway;
        policy = config.policy;
        tokenImplementation = config.tokenImplementation;
        admin = config.admin;
        agent = config.agent;
        actors = config.actors;
    }

    // ── Selection helpers ──────────────────────────────────────────────────────────────

    function _actorAt(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _pickToken(uint256 seed) internal view returns (address) {
        return tokens[seed % tokens.length];
    }

    function _chaos(uint256 seed) internal pure returns (bool) {
        return seed % 5 == 0;
    }

    // ── Creating tokens with the Restricted policy already attached ───────────────────

    function createToken(uint256 seed) external {
        address clone = Clones.clone(address(tokenImplementation));
        ParticipacaoToken(clone).initialize(
            "Oferta Politica", "nPOL", address(gateway), address(policy), "Empresa Politica", bytes32(0), vm.toString(seed)
        );

        vm.prank(agent);
        gateway.atestarCotas(clone, 1_000_000 ether);

        tokens.push(clone);
    }

    // ── Mint (must always pass, regardless of the policy's state) ─────────────────────

    function mintShares(uint256 tokenSeed, uint256 toSeed, uint256 amountSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address to = _actorAt(toSeed);

        uint256 remaining = ParticipacaoToken(token).cotasAutorizadas() - ParticipacaoToken(token).totalSupply();
        if (remaining == 0) return;
        uint256 amount = bound(amountSeed, 1, remaining);

        vm.prank(agent);
        try gateway.emitir(token, to, amount) {}
        catch {
            ghost_mintFailedUnexpectedly = true;
        }
    }

    // ── Elegibilidade (operacional, AGENTE) ────────────────────────────────────────────

    function definirElegivel(uint256 tokenSeed, uint256 investorSeed, uint256 flagSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address investidor = _actorAt(investorSeed);
        bool estaElegivel = flagSeed % 2 == 0;
        bool chaos = _chaos(chaosSeed);
        address caller = chaos ? _actorAt(chaosSeed) : agent;

        vm.prank(caller);
        try policy.definirElegivel(token, investidor, estaElegivel) {
            if (caller != agent) {
                ghost_unauthorizedOperationalCallSucceeded = true;
            } else {
                ghost_expectedEligible[token][investidor] = estaElegivel;
            }
        } catch {}
    }

    // ── Lock-up (operacional, AGENTE, set-once) ────────────────────────────────────────

    function definirLockup(uint256 tokenSeed, uint256 lockupSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        bool chaos = _chaos(chaosSeed);
        address caller = chaos ? _actorAt(chaosSeed) : agent;
        uint64 novoLockupAte = uint64(block.timestamp + bound(lockupSeed, 0, 60 days));

        vm.prank(caller);
        try policy.definirLockup(token, novoLockupAte) {
            if (caller != agent) {
                ghost_unauthorizedOperationalCallSucceeded = true;
            } else {
                ghost_expectedLockupUntil[token] = novoLockupAte;
            }
        } catch {}
    }

    function tryDuplicateLockup(uint256 tokenSeed, uint256 lockupSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        if (!policy.lockupDefinido(token)) return;

        vm.prank(agent);
        policy.definirLockup(token, uint64(block.timestamp + bound(lockupSeed, 0, 60 days)));

        // Only reaches here if it did NOT revert: "set-once" was violated.
        ghost_doubleLockupSucceeded = true;
    }

    // ── Master flag (governed by timelock, treated as an atomic action from the fuzzer's
    // point of view, in the same spirit as `_grantRoleOn` in the other invariant tests) ──

    function openSecondary(uint256 tokenSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        bool chaos = _chaos(chaosSeed);
        address caller = chaos ? _actorAt(chaosSeed) : admin;

        vm.prank(caller);
        try policy.proposeSetSecundarioLiberado(token, true) returns (uint256 executeAfter) {
            if (caller != admin) {
                ghost_unauthorizedSecondaryToggleSucceeded = true;
                return;
            }
            vm.warp(executeAfter);
            vm.prank(admin);
            policy.executeSetSecundarioLiberado(token, true);
            ghost_expectedSecondaryOpen[token] = true;
        } catch {}
    }

    // ── Tempo ───────────────────────────────────────────────────────────────────────────

    function advanceTime(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 40 days));
    }

    // ── Transfer attempts: the heart of the truth table ──────────────────────────────────

    function tryTransfer(uint256 tokenSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address from = _actorAt(fromSeed);
        uint256 balance = ParticipacaoToken(token).balanceOf(from);
        if (balance == 0) return;
        uint256 idx = toSeed % actors.length;
        address to = actors[idx] == from ? actors[(idx + 1) % actors.length] : actors[idx];
        uint256 amount = bound(amountSeed, 1, balance);

        bool shouldPass = policy.secundarioLiberado(token) && block.timestamp >= policy.lockupAte(token)
            && policy.elegivel(token, to);

        vm.prank(from);
        try ParticipacaoToken(token).transfer(to, amount) returns (bool) {
            if (!shouldPass) ghost_truthTableViolated = true;
        } catch {
            if (shouldPass) ghost_truthTableViolated = true;
        }
    }

    // ── Views for InvariantPoliticaTest ────────────────────────────────────────────────

    function numTokens() external view returns (uint256) {
        return tokens.length;
    }

    function numActors() external view returns (uint256) {
        return actors.length;
    }
}
