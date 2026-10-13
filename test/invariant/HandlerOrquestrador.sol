// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OfertaOrquestrador} from "../../src/orquestracao/OfertaOrquestrador.sol";
import {ParticipacaoTokenFactory} from "../../src/token/ParticipacaoTokenFactory.sol";
import {OfertaCaptacaoFactory} from "../../src/captacao/OfertaCaptacaoFactory.sol";
import {OfertaCaptacao} from "../../src/captacao/OfertaCaptacao.sol";
import {MockBRL} from "../../src/mocks/MockBRL.sol";

/// @notice Stateful fuzzing actor for the `OfertaOrquestrador` domain: exposes one action per
/// public function (authorize/revoke issuer, pause/unpause, create a complete offering, close
/// an issuer's last offering by failure or success) so Foundry's invariant engine explores
/// random sequences of these steps.
/// @dev Same design as `test/invariant/Handler.sol`/`HandlerCaptacao.sol` (see Lineage in
/// CLAUDE.md): most creation calls use parameters bounded (`bound`) to valid combinations
/// within the CVM Res. 88 limits; a fraction (`_chaos`, ~1 in 5) deliberately takes an invalid
/// path. External calls are not wrapped in try/catch: with `fail_on_revert = false` (see
/// foundry.toml), a genuine revert is tolerated by the runner and atomically undoes any side
/// effect of this call, including the "ghost" variables below.
contract HandlerOrquestrador is Test {
    OfertaOrquestrador public orq;
    ParticipacaoTokenFactory public tokenFactory;
    OfertaCaptacaoFactory public captacaoFactory;
    MockBRL public moeda;

    address public admin;
    address public orchestratorAgent;
    address public gatewayAgent;
    address[] public actors;
    address public fuzzInvestor;

    address[] public tokens;
    address[] public ofertas;

    mapping(address => bool) internal _trackedIssuerSet;
    address[] public trackedIssuers;

    /// @notice Creation timestamp of each tracked offering, used to check the 180-day limit
    /// against the recorded `prazo` (which is an absolute timestamp).
    mapping(address => uint256) public ghost_createdAt;

    /// @notice `true` if the issuer was in `emissoresAutorizados` AT THE MOMENT that offering
    /// was created (read before the call, recorded only if the call succeeded): proves that no
    /// tracked offering was born from an unauthorized issuer.
    mapping(address => bool) public ghost_authorizedAtCreation;

    /// @notice Becomes `true` if `autorizarEmissor`/`revogarEmissor`/`pause`/`unpause` succeed
    /// when called by someone without the orchestrator's `AGENTE_ROLE`.
    bool public ghost_unauthorizedAdminActionSucceeded;

    struct Config {
        OfertaOrquestrador orch;
        ParticipacaoTokenFactory tokenFactory;
        OfertaCaptacaoFactory fundraisingFactory;
        MockBRL currency;
        address admin;
        address orchestratorAgent;
        address gatewayAgent;
        address[] actors;
        address fuzzInvestor;
    }

    constructor(Config memory config) {
        orq = config.orch;
        tokenFactory = config.tokenFactory;
        captacaoFactory = config.fundraisingFactory;
        moeda = config.currency;
        admin = config.admin;
        orchestratorAgent = config.orchestratorAgent;
        gatewayAgent = config.gatewayAgent;
        actors = config.actors;
        fuzzInvestor = config.fuzzInvestor;
    }

    // ── Selection helpers ──────────────────────────────────────────────────────────────

    function _actorAt(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev ~1 in 5 calls takes the "chaotic" path (invalid on purpose).
    function _chaos(uint256 seed) internal pure returns (bool) {
        return seed % 5 == 0;
    }

    function _trackIssuer(address emissor) internal {
        if (!_trackedIssuerSet[emissor]) {
            _trackedIssuerSet[emissor] = true;
            trackedIssuers.push(emissor);
        }
    }

    // ── Allowlist ──────────────────────────────────────────────────────────────────────

    function autorizarEmissor(uint256 actorSeed, uint256 chaosSeed) external {
        address emissor = _actorAt(actorSeed);
        bool chaos = _chaos(chaosSeed);
        address caller = chaos ? emissor : orchestratorAgent;

        vm.prank(caller);
        orq.autorizarEmissor(emissor);

        _trackIssuer(emissor);
        if (caller != orchestratorAgent) ghost_unauthorizedAdminActionSucceeded = true;
    }

    function revogarEmissor(uint256 actorSeed, uint256 chaosSeed) external {
        address emissor = _actorAt(actorSeed);
        bool chaos = _chaos(chaosSeed);
        address caller = chaos ? emissor : orchestratorAgent;

        vm.prank(caller);
        orq.revogarEmissor(emissor);

        if (caller != orchestratorAgent) ghost_unauthorizedAdminActionSucceeded = true;
    }

    // ── Pausa ──────────────────────────────────────────────────────────────────────────

    function pauseOrUnpause(uint256 actorSeed, uint256 chaosSeed) external {
        bool isPaused = orq.paused();
        bool chaos = _chaos(chaosSeed);
        address caller = chaos ? _actorAt(actorSeed) : orchestratorAgent;

        vm.prank(caller);
        if (isPaused) {
            orq.unpause();
        } else {
            orq.pause();
        }

        if (caller != orchestratorAgent) ghost_unauthorizedAdminActionSucceeded = true;
    }

    // ── Atomic creation ────────────────────────────────────────────────────────────────

    function criarOfertaCompleta(
        uint256 actorSeed,
        uint256 maxTargetSeed,
        uint256 minTargetSeed,
        uint256 priceSeed,
        uint256 deadlineSeed,
        uint256 chaosSeed
    ) external {
        address emissor = _actorAt(actorSeed);
        OfferingParams memory p = _generateParams(maxTargetSeed, minTargetSeed, priceSeed, deadlineSeed, chaosSeed);
        if (p.precoPorCota == 0) return; // `_generateParams` signals "skip this call"

        bytes32 cnpjRef = keccak256(abi.encode("cnpj-fuzz", maxTargetSeed, actorSeed));
        _executeCreation(emissor, p, cnpjRef);
    }

    /// @dev Parameters grouped in a struct (memory), not loose as a multiple return, the same
    /// remedy already used in `IOfertaCaptacao.InitParams` in this repository for "stack too
    /// deep" with `via_ir` off (see `foundry.toml`): passing a single memory pointer between
    /// functions costs one stack slot, not one per field.
    struct OfferingParams {
        uint256 metaMinima;
        uint256 metaMaxima;
        uint256 precoPorCota;
        uint256 prazo;
    }

    /// @dev `precoPorCota == 0` in the return signals "skip this call" (the rare case where
    /// `priceSeed` sampled a price larger than the offering cap itself, making `maxShares == 0`).
    function _generateParams(
        uint256 maxTargetSeed,
        uint256 minTargetSeed,
        uint256 priceSeed,
        uint256 deadlineSeed,
        uint256 chaosSeed
    ) internal view returns (OfferingParams memory p) {
        uint256 teto = orq.TETO_OFERTA();
        p.precoPorCota = bound(priceSeed, 1, 1_000 ether);
        uint256 maxShares = teto / p.precoPorCota;
        if (maxShares == 0) {
            p.precoPorCota = 0;
            return p;
        }

        uint256 cotas = bound(maxTargetSeed, 1, maxShares);
        p.metaMaxima = cotas * p.precoPorCota;

        uint256 minTargetFloor = (p.metaMaxima * orq.LOTE_ADICIONAL_DENOMINADOR()) / orq.LOTE_ADICIONAL_NUMERADOR();
        if (minTargetFloor == 0) minTargetFloor = 1;
        p.metaMinima = bound(minTargetSeed, minTargetFloor, p.metaMaxima);

        p.prazo = block.timestamp + bound(deadlineSeed, 1, orq.PRAZO_MAXIMO());

        if (_chaos(chaosSeed)) {
            _applyChaos(p, chaosSeed, maxTargetSeed, deadlineSeed, teto);
        }
    }

    /// @dev Receives `p` by reference (`memory` struct) and mutates it in place; the caller
    /// sees the result without needing a return value.
    function _applyChaos(OfferingParams memory p, uint256 chaosSeed, uint256 maxTargetSeed, uint256 deadlineSeed, uint256 teto)
        internal
        view
    {
        uint256 mode = chaosSeed % 4;
        if (mode == 0) {
            p.prazo = block.timestamp + orq.PRAZO_MAXIMO() + 1 + (deadlineSeed % 365 days);
        } else if (mode == 1) {
            p.metaMaxima = teto + 1 + (maxTargetSeed % 1_000_000 ether);
        } else if (mode == 2 && p.metaMinima > 1) {
            p.metaMinima = p.metaMinima / 2; // tende a violar o lote adicional de 25%
        } else if (p.precoPorCota > 1) {
            p.metaMaxima = p.metaMaxima + 1; // breaks the exact multiple of precoPorCota
        }
    }

    function _executeCreation(address emissor, OfferingParams memory p, bytes32 cnpjRef) internal {
        bool authorizedBefore = orq.emissoresAutorizados(emissor);

        vm.prank(emissor);
        (address token, address oferta) = orq.criarOfertaCompleta(
            "Oferta Fuzz", "nFZ", "Empresa Fuzz", cnpjRef, "2026-FZ", p.metaMinima, p.metaMaxima, p.precoPorCota, p.prazo
        );

        // Only reaches here if it did NOT revert.
        tokens.push(token);
        ofertas.push(oferta);
        ghost_createdAt[oferta] = block.timestamp;
        ghost_authorizedAtCreation[oferta] = authorizedBefore;
        _trackIssuer(emissor);
    }

    // ── Closing offerings (allows a second creation by the same issuer) ─────────────────

    function closeLastOfferingWithFailure(uint256 actorSeed) external {
        address emissor = _actorAt(actorSeed);
        address offeringAddr = orq.ultimaOfertaDoEmissor(emissor);
        if (offeringAddr == address(0)) return;
        if (OfertaCaptacao(offeringAddr).estado() != OfertaCaptacao.Estado.Aberta) return;

        vm.prank(gatewayAgent);
        OfertaCaptacao(offeringAddr).cancelar();
    }

    function closeLastOfferingWithSuccess(uint256 actorSeed) external {
        address emissor = _actorAt(actorSeed);
        address offeringAddr = orq.ultimaOfertaDoEmissor(emissor);
        if (offeringAddr == address(0)) return;
        OfertaCaptacao oferta = OfertaCaptacao(offeringAddr);
        if (oferta.estado() != OfertaCaptacao.Estado.Aberta) return;

        uint256 missing = oferta.metaMaxima() - oferta.totalArrecadado();
        if (missing > 0) {
            moeda.mint(fuzzInvestor, missing);
            vm.prank(fuzzInvestor);
            moeda.approve(offeringAddr, missing);
            vm.prank(fuzzInvestor);
            oferta.aportar(missing);
        }
        oferta.encerrar();
    }

    // ── Views for InvariantOrquestradorTest ─────────────────────────────────────────────

    function numTokens() external view returns (uint256) {
        return tokens.length;
    }

    function numOfertas() external view returns (uint256) {
        return ofertas.length;
    }

    function trackedIssuerCount() external view returns (uint256) {
        return trackedIssuers.length;
    }
}
