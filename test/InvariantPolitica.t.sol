// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";
import {HandlerPolitica} from "./invariant/HandlerPolitica.sol";

/// @notice Stateful fuzzing invariant tests for the restricted-policy domain (Phase 3):
/// the `HandlerPolitica` runs random sequences of criarToken/mintar/definirElegivel/
/// definirLockup/abrirSecundario/avancarTempo/tentarTransferir, plus deliberate attempts to
/// bypass guards, and the functions below check that the `canTransfer` truth table and the
/// access guards hold after EVERY call. Same scale as `InvariantTest`/
/// `InvariantCaptacaoTest`: `runs=256 * depth=100` = 25,600 calls per invariant (see
/// `[invariant]` in foundry.toml).
contract InvariantPoliticaTest is Test {
    EmissaoGateway public gateway;
    RestrictedTransferPolicy public policy;
    ParticipacaoToken public tokenImplementation;
    HandlerPolitica public handler;

    address public admin = makeAddr("adminPolitica");
    address public agent = makeAddr("agentePolitica");

    uint256 public constant TIMELOCK_DELAY = 1 hours;

    function setUp() public {
        _deployContracts();
        _wireRoles();
        _deployHandler();
    }

    function _deployContracts() internal {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        policy = new RestrictedTransferPolicy(admin, TIMELOCK_DELAY);
        tokenImplementation = new ParticipacaoToken();
    }

    function _wireRoles() internal {
        _grantRoleOn(address(gateway), gateway.AGENTE_ROLE(), agent);
        _grantRoleOn(address(policy), policy.AGENTE_ROLE(), agent);
    }

    function _deployHandler() internal {
        address[] memory actors = new address[](3);
        actors[0] = makeAddr("investidorPol1");
        actors[1] = makeAddr("investidorPol2");
        actors[2] = makeAddr("investidorPol3");

        handler = new HandlerPolitica(
            HandlerPolitica.Config({
                gateway: gateway,
                policy: policy,
                tokenImplementation: tokenImplementation,
                admin: admin,
                agent: agent,
                actors: actors
            })
        );

        // Ensures at least one token exists before the invariant engine starts calling the other
        // actions (they return early if `tokens.length == 0`, but that would waste the first calls
        // of the sequence).
        handler.createToken(0);

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    function _handlerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](8);
        selectors[0] = HandlerPolitica.createToken.selector;
        selectors[1] = HandlerPolitica.mintShares.selector;
        selectors[2] = HandlerPolitica.definirElegivel.selector;
        selectors[3] = HandlerPolitica.definirLockup.selector;
        selectors[4] = HandlerPolitica.tryDuplicateLockup.selector;
        selectors[5] = HandlerPolitica.openSecondary.selector;
        selectors[6] = HandlerPolitica.advanceTime.selector;
        selectors[7] = HandlerPolitica.tryTransfer.selector;
    }

    function _grantRoleOn(address target, bytes32 role, address account) internal {
        vm.prank(admin);
        (bool ok1,) = target.call(abi.encodeWithSignature("proposeGrantRole(bytes32,address)", role, account));
        require(ok1, "propose failed");
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        (bool ok2,) = target.call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, account));
        require(ok2, "execute failed");
    }

    // ── Core invariant: no transfer had a result different from what the truth table predicts
    // (secundarioLiberado && !lockup && elegivel[to]) ─────────────────────────────────────

    function invariant_NoTruthTableViolationEverHappened() public view {
        assertFalse(handler.ghost_truthTableViolated());
    }

    // ── Mint never fails because of the restricted policy's state ─────────────────────────

    function invariant_MintNeverFailsBecauseOfPolicyState() public view {
        assertFalse(handler.ghost_mintFailedUnexpectedly());
    }

    // ── Access guards: only the AGENT operates allowlist/lock-up; only ADMIN (via timelock) turns
    // on the master flag; lock-up is set-once ───────────────────────────────────────────────

    function invariant_NoUnauthorizedOperationalCallEverSucceeded() public view {
        assertFalse(handler.ghost_unauthorizedOperationalCallSucceeded());
    }

    function invariant_NoUnauthorizedSecundarioToggleEverSucceeded() public view {
        assertFalse(handler.ghost_unauthorizedSecondaryToggleSucceeded());
    }

    function invariant_NoDoubleLockupEverSucceeded() public view {
        assertFalse(handler.ghost_doubleLockupSucceeded());
    }

    // ── Isolation between tokens: the mirror kept by the handler matches the policy's real
    // getters for every token created; if a write to one token leaked into another, the other's
    // mirror would diverge ───────────────────────────────────────────────────────────────────

    function invariant_NoStateLeaksBetweenTokens() public view {
        uint256 nTokens = handler.numTokens();
        uint256 nActors = handler.numActors();
        for (uint256 i = 0; i < nTokens; i++) {
            address token = handler.tokens(i);
            assertEq(policy.secundarioLiberado(token), handler.ghost_expectedSecondaryOpen(token));
            assertEq(policy.lockupAte(token), handler.ghost_expectedLockupUntil(token));
            for (uint256 j = 0; j < nActors; j++) {
                address investidor = handler.actors(j);
                assertEq(policy.elegivel(token, investidor), handler.ghost_expectedEligible(token, investidor));
            }
        }
    }
}
