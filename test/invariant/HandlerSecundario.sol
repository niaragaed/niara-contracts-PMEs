// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParticipacaoToken} from "../../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../../src/emissao/EmissaoGateway.sol";
import {RestrictedTransferPolicy} from "../../src/policies/RestrictedTransferPolicy.sol";
import {LiquidacaoSecundaria} from "../../src/secundario/LiquidacaoSecundaria.sol";
import {MockBRL} from "../../src/mocks/MockBRL.sol";

/// @notice Stateful fuzzing actor for the secondary-settlement domain (Phase 4): creates tokens
/// (the factory points, by default, at the shared `RestrictedTransferPolicy`; see
/// `InvariantSecundarioTest.setUp`), mints shares and `MockBRL`, manages the policy's
/// eligibility/lock-up/master flag (same design as Phase 3's `HandlerPolitica`), manages
/// allowances, and submits assignments with random parties/quantities/prices. Same spirit as
/// `Handler`/`HandlerCaptacao`/`HandlerPolitica`: most calls use valid parameters; the
/// `tentar*` ones take the invalid path on purpose.
///
/// The core proof of this phase is the `ghost_expectedCurrency`/`ghost_expectedShares` mirror:
/// every balance inflow (share mint via gateway, `MockBRL` mint) and every successful
/// settlement updates the mirror with the SAME arithmetic the real contract should apply.
/// If `LiquidacaoSecundaria` had a conservation bug (losing dust, duplicating a leg, applying
/// the wrong fee) or an assignment blocked by the policy somehow moved funds anyway, the real
/// balance would diverge from the mirror; there is no balance path outside these two
/// mirrored routes.
contract HandlerSecundario is Test {
    ParticipacaoTokenFactory public factory;
    EmissaoGateway public gateway;
    RestrictedTransferPolicy public policy;
    MockBRL public moeda;
    LiquidacaoSecundaria public settlement;

    address public admin;
    address public agent;
    address[] public actors;

    address[] public tokens;

    mapping(address => uint256) public ghost_expectedCurrency;
    mapping(address => mapping(address => uint256)) public ghost_expectedShares;

    /// @notice Becomes `true` if a successful `liquidarCessao` happened with
    /// `policy.canTransfer(token, vendedor, comprador, quantidade) == false` at call time: the
    /// proof that the Phase 3 ↔ Phase 4 gate is never bypassed.
    bool public ghost_policyGateBypassSucceeded;

    /// @notice Becomes `true` if `liquidarCessao` succeeds when called by someone without
    /// `AGENTE_ROLE`.
    bool public ghost_unauthorizedLiquidarSucceeded;

    /// @notice Becomes `true` if `proposeSetTaxaSecundarioBps`/`proposeSetProtocoloWallet` succeed
    /// when called by someone without `DEFAULT_ADMIN_ROLE`.
    bool public ghost_unauthorizedGovernanceCallSucceeded;

    /// @notice Becomes `true` if `taxaSecundarioBps` ever exceeds the hard cap.
    bool public ghost_feeExceededCapSucceeded;

    struct Config {
        ParticipacaoTokenFactory factory;
        EmissaoGateway gateway;
        RestrictedTransferPolicy policy;
        MockBRL currency;
        LiquidacaoSecundaria settlement;
        address admin;
        address agent;
        address[] actors;
    }

    constructor(Config memory config) {
        factory = config.factory;
        gateway = config.gateway;
        policy = config.policy;
        moeda = config.currency;
        settlement = config.settlement;
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
        if (candidate == other) candidate = actors[(idx + 1) % actors.length];
        return candidate;
    }

    function _pickToken(uint256 seed) internal view returns (address) {
        return tokens[seed % tokens.length];
    }

    function _chaos(uint256 seed) internal pure returns (bool) {
        return seed % 5 == 0;
    }

    // ── Token creation (they already point at the shared Restricted policy, see setUp) ───

    function createToken(uint256 seed) external {
        vm.prank(agent);
        address token = factory.criarOferta(
            "Oferta Secundario", "nSEC", "Empresa Secundario", bytes32(0), vm.toString(seed)
        );

        vm.prank(agent);
        gateway.atestarCotas(token, 1_000_000 ether);

        tokens.push(token);
    }

    // ── Balance inflows (mirrored) ─────────────────────────────────────────────────────

    function mintSharesTo(uint256 tokenSeed, uint256 toSeed, uint256 amountSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address to = _actorAt(toSeed);

        uint256 remaining = ParticipacaoToken(token).cotasAutorizadas() - ParticipacaoToken(token).totalSupply();
        if (remaining == 0) return;
        uint256 amount = bound(amountSeed, 1, remaining);

        vm.prank(agent);
        gateway.emitir(token, to, amount);
        ghost_expectedShares[token][to] += amount;
    }

    function mintCurrency(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actorAt(actorSeed);
        uint256 amount = bound(amountSeed, 1, 1_000_000 ether);

        moeda.mint(actor, amount);
        ghost_expectedCurrency[actor] += amount;
    }

    // ── Allowances ──────────────────────────────────────────────────────────────────────

    function approveShares(uint256 tokenSeed, uint256 actorSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address actor = _actorAt(actorSeed);

        vm.prank(actor);
        ParticipacaoToken(token).approve(address(settlement), type(uint256).max);
    }

    function approveCurrency(uint256 actorSeed) external {
        address actor = _actorAt(actorSeed);
        vm.prank(actor);
        moeda.approve(address(settlement), type(uint256).max);
    }

    // ── Policy (same design as HandlerPolitica, Phase 3) ───────────────────────────────────

    function definirElegivel(uint256 tokenSeed, uint256 investorSeed, uint256 flagSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address investidor = _actorAt(investorSeed);
        bool estaElegivel = flagSeed % 2 == 0;
        address caller = _chaos(chaosSeed) ? _actorAt(chaosSeed) : agent;

        vm.prank(caller);
        try policy.definirElegivel(token, investidor, estaElegivel) {} catch {}
    }

    function definirLockup(uint256 tokenSeed, uint256 lockupSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        uint64 novoLockupAte = uint64(block.timestamp + bound(lockupSeed, 0, 30 days));

        vm.prank(agent);
        try policy.definirLockup(token, novoLockupAte) {} catch {}
    }

    function openSecondary(uint256 tokenSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address caller = _chaos(chaosSeed) ? _actorAt(chaosSeed) : admin;

        vm.prank(caller);
        try policy.proposeSetSecundarioLiberado(token, true) returns (uint256 executeAfter) {
            if (caller != admin) {
                // Defense in depth: RestrictedTransferPolicy is already covered by
                // InvariantPoliticaTest (Phase 3); here we only flag it so a regression is not hidden
                // silently if its guard breaks.
                ghost_unauthorizedGovernanceCallSucceeded = true;
                return;
            }
            vm.warp(executeAfter);
            vm.prank(admin);
            policy.executeSetSecundarioLiberado(token, true);
        } catch {}
    }

    function advanceTime(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 20 days));
    }

    // ── The core action: submitting an assignment ──────────────────────────────────────

    function trySettleAssignment(
        uint256 tokenSeed,
        uint256 sellerSeed,
        uint256 buyerSeed,
        uint256 quantitySeed,
        uint256 priceSeed,
        uint256 chaosSeed
    ) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address vendedor = _actorAt(sellerSeed);
        address comprador = _distinctActor(buyerSeed, vendedor);

        uint256 sellerBalance = ParticipacaoToken(token).balanceOf(vendedor);
        bool chaos = _chaos(chaosSeed);

        uint256 quantidade;
        if (chaos) {
            quantidade = quantitySeed % (2 * (sellerBalance == 0 ? 1 ether : sellerBalance) + 1);
        } else {
            if (sellerBalance == 0) return;
            quantidade = bound(quantitySeed, 1, sellerBalance);
        }
        uint256 precoPorCota = bound(priceSeed, 1 ether, 1_000 ether);

        address caller = chaos && chaosSeed % 3 == 0 ? _actorAt(chaosSeed) : agent;

        bool policyGate = quantidade > 0 && policy.canTransfer(token, vendedor, comprador, quantidade);

        uint256 valor = (quantidade * precoPorCota) / 1 ether;
        uint256 taxa = (valor * settlement.taxaSecundarioBps()) / 10_000;

        vm.prank(caller);
        try settlement.liquidarCessao(token, vendedor, comprador, quantidade, precoPorCota) {
            if (caller != agent) {
                ghost_unauthorizedLiquidarSucceeded = true;
                return;
            }
            if (!policyGate) {
                ghost_policyGateBypassSucceeded = true;
                return;
            }

            ghost_expectedShares[token][vendedor] -= quantidade;
            ghost_expectedShares[token][comprador] += quantidade;
            ghost_expectedCurrency[comprador] -= valor;
            ghost_expectedCurrency[vendedor] += valor - taxa;
            ghost_expectedCurrency[settlement.protocoloWallet()] += taxa;
        } catch {}
    }

    // ── Governance (fee / protocoloWallet) ─────────────────────────────────────────────

    function adjustFee(uint256 newFeeSeed, uint256 chaosSeed) external {
        bool chaos = _chaos(chaosSeed);
        uint256 novaTaxa = chaos ? bound(newFeeSeed, 101, 10_000) : bound(newFeeSeed, 0, 100);
        address caller = chaos && chaosSeed % 2 == 0 ? _actorAt(chaosSeed) : admin;

        vm.prank(caller);
        try settlement.proposeSetTaxaSecundarioBps(novaTaxa) returns (uint256 executeAfter) {
            if (caller != admin) {
                ghost_unauthorizedGovernanceCallSucceeded = true;
                return;
            }
            if (novaTaxa > settlement.TAXA_BPS_MAXIMA()) {
                ghost_feeExceededCapSucceeded = true;
                return;
            }
            vm.warp(executeAfter);
            vm.prank(admin);
            settlement.executeSetTaxaSecundarioBps(novaTaxa);
            if (settlement.taxaSecundarioBps() > settlement.TAXA_BPS_MAXIMA()) {
                ghost_feeExceededCapSucceeded = true;
            }
        } catch {}
    }

    // ── Views for InvariantSecundarioTest ──────────────────────────────────────────────

    function numTokens() external view returns (uint256) {
        return tokens.length;
    }

    function numActors() external view returns (uint256) {
        return actors.length;
    }
}
