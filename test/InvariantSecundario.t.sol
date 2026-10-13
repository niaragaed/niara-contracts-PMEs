// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";
import {LiquidacaoSecundaria} from "../src/secundario/LiquidacaoSecundaria.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";
import {HandlerSecundario} from "./invariant/HandlerSecundario.sol";

/// @notice Stateful fuzzing invariant tests for the secondary-settlement domain (Phase 4): the
/// `HandlerSecundario` runs random sequences of criarToken/mintarCotas/
/// mintarMoeda/aprovarCotas/aprovarMoeda/definirElegivel/definirLockup/abrirSecundario/
/// avancarTempo/tentarLiquidarCessao/ajustarTaxa, and the functions below check conservation,
/// atomicity and the access/policy guards on every call. Same scale as the earlier phases:
/// `runs=256 * depth=100` = 25,600 calls per invariant (see `[invariant]` in foundry.toml).
///
/// This suite's factory is deployed with the shared `RestrictedTransferPolicy` as
/// `transferPolicyPadrao` (instead of `DenyAllTransferPolicy`): the mechanism for SWAPPING an
/// already-live token's policy was already proven exhaustively in `InvariantPoliticaTest`
/// (Phase 3); here the focus is the money and the gate, not the swap mechanism itself.
contract InvariantSecundarioTest is Test {
    ParticipacaoTokenFactory public factory;
    ParticipacaoToken public tokenImplementation;
    EmissaoGateway public gateway;
    RestrictedTransferPolicy public policy;
    MockBRL public moeda;
    LiquidacaoSecundaria public settlement;
    HandlerSecundario public handler;

    address public admin = makeAddr("adminSecundario");
    address public agent = makeAddr("agenteSecundario");
    address public protocoloWallet = makeAddr("protocoloWalletSecundario");

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
        factory =
            new ParticipacaoTokenFactory(admin, address(tokenImplementation), address(gateway), address(policy), TIMELOCK_DELAY);
        moeda = new MockBRL();
        settlement = new LiquidacaoSecundaria(admin, address(moeda), address(factory), protocoloWallet, TIMELOCK_DELAY);
    }

    function _wireRoles() internal {
        _grantRoleOn(address(gateway), gateway.AGENTE_ROLE(), agent);
        _grantRoleOn(address(factory), factory.AGENTE_ROLE(), agent);
        _grantRoleOn(address(policy), policy.AGENTE_ROLE(), agent);
        _grantRoleOn(address(settlement), settlement.AGENTE_ROLE(), agent);
    }

    function _deployHandler() internal {
        address[] memory actors = new address[](4);
        actors[0] = makeAddr("traderSecundario1");
        actors[1] = makeAddr("traderSecundario2");
        actors[2] = makeAddr("traderSecundario3");
        actors[3] = makeAddr("traderSecundario4");

        handler = new HandlerSecundario(
            HandlerSecundario.Config({
                factory: factory,
                gateway: gateway,
                policy: policy,
                currency: moeda,
                settlement: settlement,
                admin: admin,
                agent: agent,
                actors: actors
            })
        );

        handler.createToken(0);

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    function _handlerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](11);
        selectors[0] = HandlerSecundario.createToken.selector;
        selectors[1] = HandlerSecundario.mintSharesTo.selector;
        selectors[2] = HandlerSecundario.mintCurrency.selector;
        selectors[3] = HandlerSecundario.approveShares.selector;
        selectors[4] = HandlerSecundario.approveCurrency.selector;
        selectors[5] = HandlerSecundario.definirElegivel.selector;
        selectors[6] = HandlerSecundario.definirLockup.selector;
        selectors[7] = HandlerSecundario.openSecondary.selector;
        selectors[8] = HandlerSecundario.advanceTime.selector;
        selectors[9] = HandlerSecundario.trySettleAssignment.selector;
        selectors[10] = HandlerSecundario.adjustFee.selector;
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

    // ── Core invariant: conservation of MockBRL and of shares, for every actor and every token,
    // which also proves atomicity (no balance moves outside a confirmed successful
    // settlement) ─────────────────────────────────────────────────────────────────────────

    function invariant_ConservacaoDeMoeda() public view {
        uint256 nActors = handler.numActors();
        for (uint256 i = 0; i < nActors; i++) {
            address actor = handler.actors(i);
            assertEq(moeda.balanceOf(actor), handler.ghost_expectedCurrency(actor));
        }
        assertEq(moeda.balanceOf(protocoloWallet), handler.ghost_expectedCurrency(protocoloWallet));
    }

    function invariant_ConservacaoDeCotas() public view {
        uint256 nTokens = handler.numTokens();
        uint256 nActors = handler.numActors();
        for (uint256 i = 0; i < nTokens; i++) {
            address token = handler.tokens(i);
            for (uint256 j = 0; j < nActors; j++) {
                address actor = handler.actors(j);
                assertEq(ParticipacaoToken(token).balanceOf(actor), handler.ghost_expectedShares(token, actor));
            }
        }
    }

    // ── Policy gate never bypassed ──────────────────────────────────────────────────────

    function invariant_NoPolicyGateBypassEverSucceeded() public view {
        assertFalse(handler.ghost_policyGateBypassSucceeded());
    }

    // ── Guardas de acesso ───────────────────────────────────────────────────────────────

    function invariant_NoUnauthorizedLiquidarEverSucceeded() public view {
        assertFalse(handler.ghost_unauthorizedLiquidarSucceeded());
    }

    function invariant_NoUnauthorizedGovernanceCallEverSucceeded() public view {
        assertFalse(handler.ghost_unauthorizedGovernanceCallSucceeded());
    }

    // ── Fee cap never exceeded ──────────────────────────────────────────────────────────

    function invariant_FeeNeverExceededCap() public view {
        assertFalse(handler.ghost_feeExceededCapSucceeded());
        assertLe(settlement.taxaSecundarioBps(), settlement.TAXA_BPS_MAXIMA());
    }
}
