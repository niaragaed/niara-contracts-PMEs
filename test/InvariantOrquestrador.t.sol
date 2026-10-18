// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {OfertaCaptacao} from "../src/captacao/OfertaCaptacao.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";
import {RegistroInvestidorQualificado} from "../src/registro/RegistroInvestidorQualificado.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";
import {OfertaOrquestrador} from "../src/orquestracao/OfertaOrquestrador.sol";
import {HandlerOrquestrador} from "./invariant/HandlerOrquestrador.sol";

/// @notice Stateful fuzzing invariant tests for the `OfertaOrquestrador` domain: the
/// `HandlerOrquestrador` runs random sequences of autorizarEmissor/revogarEmissor/
/// pausar/criarOfertaCompleta/fecharUltimaOferta(ComFalha|ComSucesso), plus deliberate
/// attempts to bypass the guards, and the functions below check that the orchestrator's
/// invariants hold after EVERY call. Same scale as the other invariant suites
/// (`runs=256 * depth=100` = 25,600 calls per invariant, see `[invariant]` in foundry.toml).
contract InvariantOrquestradorTest is Test {
    ParticipacaoToken public tokenImplementation;
    ParticipacaoTokenFactory public tokenFactory;
    EmissaoGateway public gateway;
    OfertaCaptacao public offeringImplementation;
    OfertaCaptacaoFactory public captacaoFactory;
    RegistroInvestidorQualificado public registro;
    DenyAllTransferPolicy public policy;
    MockBRL public moeda;
    OfertaOrquestrador public orq;
    HandlerOrquestrador public handler;

    address public admin = makeAddr("adminOrq");
    address public orchestratorAgent = makeAddr("agenteOrqInv");
    address public gatewayAgent = makeAddr("agenteGatewayInv");
    address public protocoloWallet = makeAddr("protocoloWalletInv");
    address public fuzzInvestor = makeAddr("investidorFuzzInv");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    uint256 public constant TAXA_BPS_MAXIMA = 100;

    function setUp() public {
        _deployContracts();
        _wireRoles();
        _deployHandler();
    }

    function _deployContracts() internal {
        tokenImplementation = new ParticipacaoToken();
        policy = new DenyAllTransferPolicy();
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        tokenFactory = new ParticipacaoTokenFactory(
            admin, address(tokenImplementation), address(gateway), address(policy), TIMELOCK_DELAY
        );

        registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        moeda = new MockBRL();
        offeringImplementation = new OfertaCaptacao();
        captacaoFactory = new OfertaCaptacaoFactory(
            admin, address(offeringImplementation), address(gateway), address(registro), address(moeda), TIMELOCK_DELAY
        );

        orq = new OfertaOrquestrador(
            admin,
            address(tokenFactory),
            address(gateway),
            address(captacaoFactory),
            protocoloWallet,
            0, // initial taxaBps: dormant, same pattern as the rest of the repository
            // tetoPorInvestidor generous enough to cover any test offering's maximum target
            // (up to TETO_OFERTA) without having to qualify the fuzz investor: a deliberate
            // harness simplification, not a real business lock.
            15_000_000 ether,
            TIMELOCK_DELAY
        );
    }

    function _wireRoles() internal {
        _grantRoleOn(address(tokenFactory), tokenFactory.AGENTE_ROLE(), address(orq));
        _grantRoleOn(address(gateway), gateway.AGENTE_ROLE(), address(orq));
        _grantRoleOn(address(captacaoFactory), captacaoFactory.AGENTE_ROLE(), address(orq));

        // AGENTE_ROLE on EmissaoGateway so the handler can cancelar() offerings and close the
        // "one open at a time" cycle through the failure path.
        _grantRoleOn(address(gateway), gateway.AGENTE_ROLE(), gatewayAgent);

        // The orchestrator's own AGENTE_ROLE, so the handler can manage the allowlist/pause.
        _grantRoleOn(address(orq), orq.AGENTE_ROLE(), orchestratorAgent);
    }

    function _deployHandler() internal {
        address[] memory actors = new address[](5);
        actors[0] = makeAddr("emissorFuzz1");
        actors[1] = makeAddr("emissorFuzz2");
        actors[2] = makeAddr("emissorFuzz3");
        actors[3] = makeAddr("emissorFuzz4");
        actors[4] = makeAddr("emissorFuzz5");

        handler = new HandlerOrquestrador(
            HandlerOrquestrador.Config({
                orch: orq,
                tokenFactory: tokenFactory,
                fundraisingFactory: captacaoFactory,
                currency: moeda,
                admin: admin,
                orchestratorAgent: orchestratorAgent,
                gatewayAgent: gatewayAgent,
                actors: actors,
                fuzzInvestor: fuzzInvestor
            })
        );

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    function _handlerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = HandlerOrquestrador.autorizarEmissor.selector;
        selectors[1] = HandlerOrquestrador.revogarEmissor.selector;
        selectors[2] = HandlerOrquestrador.pauseOrUnpause.selector;
        selectors[3] = HandlerOrquestrador.criarOfertaCompleta.selector;
        selectors[4] = HandlerOrquestrador.closeLastOfferingWithFailure.selector;
        selectors[5] = HandlerOrquestrador.closeLastOfferingWithSuccess.selector;
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

    // ── Invariant 1: totalSupply <= cotasAutorizadas for every token created via the orchestrator ──

    function invariant_TotalSupplyNeverExceedsCotasAutorizadas() public view {
        uint256 n = handler.numTokens();
        for (uint256 i = 0; i < n; i++) {
            ParticipacaoToken token = ParticipacaoToken(handler.tokens(i));
            assertLe(token.totalSupply(), token.cotasAutorizadas());
        }
    }

    // ── Invariant 2: no offering created via the orchestrator exists outside the Res. 88 limits ──

    function invariant_NoOfferingOutsideRes88Limits() public view {
        uint256 n = handler.numOfertas();
        for (uint256 i = 0; i < n; i++) {
            OfertaCaptacao oferta = OfertaCaptacao(handler.ofertas(i));
            uint256 createdAt = handler.ghost_createdAt(address(oferta));

            assertLe(oferta.metaMaxima(), orq.TETO_OFERTA());
            assertLe(oferta.prazo() - createdAt, orq.PRAZO_MAXIMO());
            assertLe(
                oferta.metaMaxima() * orq.LOTE_ADICIONAL_DENOMINADOR(),
                oferta.metaMinima() * orq.LOTE_ADICIONAL_NUMERADOR()
            );
        }
    }

    // ── Invariant 3: no issuer has more than one open offering at the same time ─────────────

    function invariant_NoIssuerWithMoreThanOneOpenOffering() public view {
        uint256 issuerCount = handler.trackedIssuerCount();
        uint256 numOfertas = handler.numOfertas();

        for (uint256 e = 0; e < issuerCount; e++) {
            address emissor = handler.trackedIssuers(e);
            uint256 openByIssuer = 0;

            for (uint256 i = 0; i < numOfertas; i++) {
                OfertaCaptacao oferta = OfertaCaptacao(handler.ofertas(i));
                if (oferta.emissorWallet() == emissor && oferta.estado() == OfertaCaptacao.Estado.Aberta) {
                    openByIssuer++;
                }
            }

            assertLe(openByIssuer, 1);
        }
    }

    // ── Invariant 4: every offering's emissorWallet was in emissoresAutorizados at creation ──

    function invariant_TodaOfertaTinhaEmissorAutorizadoNaCriacao() public view {
        uint256 n = handler.numOfertas();
        for (uint256 i = 0; i < n; i++) {
            address oferta = handler.ofertas(i);
            assertTrue(handler.ghost_authorizedAtCreation(oferta));
        }
    }

    // ── Additional invariants (same defensive-depth pattern as the earlier phases) ──────────

    function invariant_NoUnauthorizedAdminActionEverSucceeded() public view {
        assertFalse(handler.ghost_unauthorizedAdminActionSucceeded());
    }

    function invariant_TaxaBpsNeverExceedsMaximo() public view {
        assertLe(orq.taxaBps(), TAXA_BPS_MAXIMA);
    }
}
