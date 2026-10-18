// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {Handler} from "./invariant/Handler.sol";

/// @notice Stateful fuzzing invariant tests (Foundry `invariant_*`): the `Handler` runs random
/// sequences of criarOferta/atestarCotas/emitir/transfer attempts/access-bypass attempts,
/// triggered by different actors (agent and three investors), and the functions below check
/// that the platform's core invariants hold after EVERY call in the sequence. Scale:
/// `runs=256 * depth=100` (see `[invariant]` in foundry.toml) = 25,600 calls per run,
/// deliberately mirroring the scale used in `niara-contracts` (see Lineage in CLAUDE.md).
contract InvariantTest is Test {
    ParticipacaoTokenFactory public factory;
    ParticipacaoToken public implementacao;
    EmissaoGateway public gateway;
    DenyAllTransferPolicy public policy;
    Handler public handler;

    address public admin = makeAddr("admin");
    address public agent = makeAddr("agente");

    uint256 public constant TIMELOCK_DELAY = 1 hours;

    function setUp() public {
        _deployContracts();
        _wireRoles();
        _deployHandler();
    }

    function _deployContracts() internal {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        implementacao = new ParticipacaoToken();
        policy = new DenyAllTransferPolicy();
        factory = new ParticipacaoTokenFactory(
            admin, address(implementacao), address(gateway), address(policy), TIMELOCK_DELAY
        );
    }

    function _wireRoles() internal {
        _grantRoleOn(address(gateway), gateway.AGENTE_ROLE(), agent);
        _grantRoleOn(address(factory), factory.AGENTE_ROLE(), agent);
    }

    function _deployHandler() internal {
        address[] memory actors = new address[](3);
        actors[0] = makeAddr("investidor1");
        actors[1] = makeAddr("investidor2");
        actors[2] = makeAddr("investidor3");

        handler = new Handler(
            Handler.Config({factory: factory, gateway: gateway, admin: admin, agent: agent, actors: actors})
        );

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    function _handlerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = Handler.criarOferta.selector;
        selectors[1] = Handler.atestarCotas.selector;
        selectors[2] = Handler.emitir.selector;
        selectors[3] = Handler.pauseOrUnpauseToken.selector;
        selectors[4] = Handler.pauseOrUnpauseFactory.selector;
        selectors[5] = Handler.tryTransfer.selector;
        selectors[6] = Handler.tryTransferFrom.selector;
        selectors[7] = Handler.tryCallRestrictedOnToken.selector;
        selectors[8] = Handler.tryReinitialize.selector;
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

    // ── Core invariant: totalSupply <= cotasAutorizadas, for every token created ─────────

    function invariant_TotalSupplyNeverExceedsCotasAutorizadas() public view {
        uint256 n = handler.numTokens();
        for (uint256 i = 0; i < n; i++) {
            ParticipacaoToken token = ParticipacaoToken(handler.tokens(i));
            assertLe(token.totalSupply(), token.cotasAutorizadas());
        }
    }

    // ── Invariant: sum(balances) == totalSupply, for every token created ─────────────────

    function invariant_SumOfBalancesEqualsTotalSupply() public view {
        uint256 nTokens = handler.numTokens();
        uint256 nActors = handler.numActors();
        for (uint256 i = 0; i < nTokens; i++) {
            ParticipacaoToken token = ParticipacaoToken(handler.tokens(i));
            uint256 sum = 0;
            for (uint256 j = 0; j < nActors; j++) {
                sum += token.balanceOf(handler.actors(j));
            }
            assertEq(sum, token.totalSupply());
        }
    }

    // ── Invariant: only the gateway attests/mints/pauses on the token; only AGENTE_ROLE
    // operates the gateway/factory ──────────────────────────────────────────────────────

    function invariant_NoUnauthorizedTokenCallEverSucceeded() public view {
        assertFalse(handler.ghost_unauthorizedTokenCallSucceeded());
    }

    function invariant_NoUnauthorizedRoleCallEverSucceeded() public view {
        assertFalse(handler.ghost_unauthorizedRoleCallSucceeded());
    }

    // ── Invariant: no holder→holder transfer goes through (deny-all policy) ──────────────

    function invariant_NoTransferEverSucceeded() public view {
        assertFalse(handler.ghost_transferSucceeded());
    }

    // ── Invariant: no clone can be reinitialized ──────────────────────────────────────────

    function invariant_NoReinitializeEverSucceeded() public view {
        assertFalse(handler.ghost_reinitializeSucceeded());
    }
}
