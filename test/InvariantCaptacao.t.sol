// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";
import {OfertaCaptacao} from "../src/captacao/OfertaCaptacao.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RegistroInvestidorQualificado} from "../src/registro/RegistroInvestidorQualificado.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";
import {HandlerCaptacao} from "./invariant/HandlerCaptacao.sol";

/// @notice Stateful fuzzing invariant tests for the fundraising domain (Phase 2): the
/// `HandlerCaptacao` runs random sequences of criarCaptacao/aportar/encerrar/
/// resgatarCotas/liberarParaEmissor/reembolsar/definirQualificado/cancelar, plus deliberate
/// attempts to bypass guards, and the functions below check that Phase 2's money invariants
/// hold after EVERY call. Same scale as `InvariantTest` (Phase 1):
/// `runs=256 * depth=100` = 25,600 calls per invariant (see `[invariant]` in foundry.toml).
contract InvariantCaptacaoTest is Test {
    OfertaCaptacaoFactory public factory;
    OfertaCaptacao public fundraisingImplementation;
    EmissaoGateway public gateway;
    RegistroInvestidorQualificado public registro;
    ParticipacaoToken public tokenImplementation;
    DenyAllTransferPolicy public policy;
    MockBRL public moeda;
    HandlerCaptacao public handler;

    address public admin = makeAddr("admin");
    address public agent = makeAddr("agente");
    address public emissorWallet = makeAddr("emissorWallet");
    address public protocoloWallet = makeAddr("protocoloWallet");

    uint256 public constant TIMELOCK_DELAY = 1 hours;

    function setUp() public {
        _deployContracts();
        _wireRoles();
        _deployHandler();
    }

    function _deployContracts() internal {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        moeda = new MockBRL();
        tokenImplementation = new ParticipacaoToken();
        policy = new DenyAllTransferPolicy();
        fundraisingImplementation = new OfertaCaptacao();

        factory = new OfertaCaptacaoFactory(
            admin,
            address(fundraisingImplementation),
            address(gateway),
            address(registro),
            address(moeda),
            TIMELOCK_DELAY
        );
    }

    function _wireRoles() internal {
        _grantRoleOn(address(gateway), gateway.AGENTE_ROLE(), agent);
        _grantRoleOn(address(registro), registro.AGENTE_ROLE(), agent);
        _grantRoleOn(address(factory), factory.AGENTE_ROLE(), agent);
    }

    function _deployHandler() internal {
        address[] memory actors = new address[](3);
        actors[0] = makeAddr("investidorCap1");
        actors[1] = makeAddr("investidorCap2");
        actors[2] = makeAddr("investidorCap3");

        handler = new HandlerCaptacao(
            HandlerCaptacao.Config({
                factory: factory,
                gateway: gateway,
                registry: registro,
                currency: moeda,
                tokenImplementation: tokenImplementation,
                policy: policy,
                admin: admin,
                agent: agent,
                issuerWallet: emissorWallet,
                protocolWallet: protocoloWallet,
                actors: actors
            })
        );

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    function _handlerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](15);
        selectors[0] = HandlerCaptacao.createFundraisingAndToken.selector;
        selectors[1] = HandlerCaptacao.aportar.selector;
        selectors[2] = HandlerCaptacao.advanceTime.selector;
        selectors[3] = HandlerCaptacao.encerrar.selector;
        selectors[4] = HandlerCaptacao.tryClosePrematurely.selector;
        selectors[5] = HandlerCaptacao.definirQualificado.selector;
        selectors[6] = HandlerCaptacao.cancelar.selector;
        selectors[7] = HandlerCaptacao.reembolsar.selector;
        selectors[8] = HandlerCaptacao.tryRefundTwice.selector;
        selectors[9] = HandlerCaptacao.resgatarCotas.selector;
        selectors[10] = HandlerCaptacao.tryRedeemTwice.selector;
        selectors[11] = HandlerCaptacao.liberarParaEmissor.selector;
        selectors[12] = HandlerCaptacao.tryReleaseTwice.selector;
        selectors[13] = HandlerCaptacao.tryInvestOutOfState.selector;
        selectors[14] = HandlerCaptacao.tryExceedCapWithoutQualification.selector;
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

    // ── Core invariant: escrow accounting ────────────────────────────────────────────────

    function invariant_EscrowAccountingMatchesCustody() public view {
        uint256 n = handler.numCaptacoes();
        for (uint256 i = 0; i < n; i++) {
            OfertaCaptacao oferta = OfertaCaptacao(handler.captacoes(i));
            uint256 expected = oferta.recursosLiberados()
                ? 0
                : oferta.totalArrecadado() - handler.ghost_sumRefunded(address(oferta));
            assertEq(moeda.balanceOf(address(oferta)), expected);
        }
    }

    // ── Refunds never exceed the amount raised; no double refund ─────────────────────────

    function invariant_RefundNeverExceedsRaised() public view {
        uint256 n = handler.numCaptacoes();
        for (uint256 i = 0; i < n; i++) {
            OfertaCaptacao oferta = OfertaCaptacao(handler.captacoes(i));
            assertLe(handler.ghost_sumRefunded(address(oferta)), oferta.totalArrecadado());
        }
    }

    function invariant_NoDoubleReembolsoEverSucceeded() public view {
        assertFalse(handler.ghost_doubleRefundSucceeded());
    }

    // ── Never distributes shares beyond what was subscribed; no double redemption ────────

    function invariant_MintedSharesNeverExceedSubscribed() public view {
        uint256 n = handler.numCaptacoes();
        for (uint256 i = 0; i < n; i++) {
            OfertaCaptacao oferta = OfertaCaptacao(handler.captacoes(i));
            assertLe(handler.ghost_sumSharesMinted(address(oferta)), oferta.totalArrecadado() / oferta.precoPorCota());
        }
    }

    function invariant_NoDoubleResgateEverSucceeded() public view {
        assertFalse(handler.ghost_doubleRedeemSucceeded());
    }

    // ── Never above the maximum target ───────────────────────────────────────────────────

    function invariant_TotalRaisedNeverExceedsMaxTarget() public view {
        uint256 n = handler.numCaptacoes();
        for (uint256 i = 0; i < n; i++) {
            OfertaCaptacao oferta = OfertaCaptacao(handler.captacoes(i));
            assertLe(oferta.totalArrecadado(), oferta.metaMaxima());
        }
    }

    // ── Per-investor cap respected (non-qualified investors) ─────────────────────────────
    //
    // Checked at call time (ghost), not as a retroactive snapshot: qualification is a mutable
    // flag, and an investor can legitimately be above the current cap if they were qualified at
    // the time of investing and disqualified later, with no retroactive confiscation.

    function invariant_NoCapBypassEverSucceeded() public view {
        assertFalse(handler.ghost_capBypassSucceeded());
    }

    // ── Success/failure exclusion: never both for the same fundraising ───────────────────

    function invariant_NeverRefundAndMintTogether() public view {
        uint256 n = handler.numCaptacoes();
        for (uint256 i = 0; i < n; i++) {
            address oferta = handler.captacoes(i);
            bool hadRefund = handler.ghost_hadRefund(oferta);
            bool hadMintOrRelease = handler.ghost_hadMintOrRelease(oferta);
            assertFalse(hadRefund && hadMintOrRelease);
        }
    }

    // ── Monotonic states / authorization and double-release guards ───────────────────────

    function invariant_NoUnauthorizedActionEverSucceeded() public view {
        assertFalse(handler.ghost_unauthorizedActionSucceeded());
    }

    function invariant_NoDoubleLiberacaoEverSucceeded() public view {
        assertFalse(handler.ghost_doubleReleaseSucceeded());
    }

    function invariant_NoAportarForaDoEstadoEverSucceeded() public view {
        assertFalse(handler.ghost_investOutOfStateSucceeded());
    }

    function invariant_NoEncerramentoPrematuroEverSucceeded() public view {
        assertFalse(handler.ghost_prematureCloseSucceeded());
    }
}
