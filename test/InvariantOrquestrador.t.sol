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

/// @notice Testes de invariante com fuzzing stateful do domínio do `OfertaOrquestrador`: o
/// `HandlerOrquestrador` executa sequências aleatórias de autorizarEmissor/revogarEmissor/
/// pausar/criarOfertaCompleta/fecharUltimaOferta(ComFalha|ComSucesso), mais tentativas
/// deliberadas de burlar as guardas, e as funções abaixo verificam que os invariantes do
/// orquestrador se mantêm após CADA chamada. Mesma escala das demais suítes de invariante
/// (`runs=256 * depth=100` = 25.600 chamadas por invariante, ver `[invariant]` em
/// foundry.toml).
contract InvariantOrquestradorTest is Test {
    ParticipacaoToken public tokenImplementacao;
    ParticipacaoTokenFactory public tokenFactory;
    EmissaoGateway public gateway;
    OfertaCaptacao public ofertaImplementacao;
    OfertaCaptacaoFactory public captacaoFactory;
    RegistroInvestidorQualificado public registro;
    DenyAllTransferPolicy public policy;
    MockBRL public moeda;
    OfertaOrquestrador public orq;
    HandlerOrquestrador public handler;

    address public admin = makeAddr("adminOrq");
    address public agenteOrq = makeAddr("agenteOrqInv");
    address public agenteGateway = makeAddr("agenteGatewayInv");
    address public protocoloWallet = makeAddr("protocoloWalletInv");
    address public investidorFuzz = makeAddr("investidorFuzzInv");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    uint256 public constant TAXA_BPS_MAXIMA = 100;

    function setUp() public {
        _deployContracts();
        _wireRoles();
        _deployHandler();
    }

    function _deployContracts() internal {
        tokenImplementacao = new ParticipacaoToken();
        policy = new DenyAllTransferPolicy();
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        tokenFactory = new ParticipacaoTokenFactory(
            admin, address(tokenImplementacao), address(gateway), address(policy), TIMELOCK_DELAY
        );

        registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        moeda = new MockBRL();
        ofertaImplementacao = new OfertaCaptacao();
        captacaoFactory = new OfertaCaptacaoFactory(
            admin, address(ofertaImplementacao), address(gateway), address(registro), address(moeda), TIMELOCK_DELAY
        );

        orq = new OfertaOrquestrador(
            admin,
            address(tokenFactory),
            address(gateway),
            address(captacaoFactory),
            protocoloWallet,
            0, // taxaBps inicial — dormente, mesmo padrão do restante do repositório
            // tetoPorInvestidor generoso o bastante para cobrir a meta máxima de qualquer
            // oferta de teste (até TETO_OFERTA) sem precisar qualificar o investidor fuzz —
            // simplificação deliberada do harness, não uma trava real de negócio.
            15_000_000 ether,
            TIMELOCK_DELAY
        );
    }

    function _wireRoles() internal {
        _grantRoleOn(address(tokenFactory), tokenFactory.AGENTE_ROLE(), address(orq));
        _grantRoleOn(address(gateway), gateway.AGENTE_ROLE(), address(orq));
        _grantRoleOn(address(captacaoFactory), captacaoFactory.AGENTE_ROLE(), address(orq));

        // AGENTE_ROLE na EmissaoGateway para o handler poder cancelar() ofertas e fechar o
        // ciclo "uma aberta por vez" pelo caminho de falha.
        _grantRoleOn(address(gateway), gateway.AGENTE_ROLE(), agenteGateway);

        // AGENTE_ROLE do próprio orquestrador, para o handler gerir allowlist/pausa.
        _grantRoleOn(address(orq), orq.AGENTE_ROLE(), agenteOrq);
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
                orq: orq,
                tokenFactory: tokenFactory,
                captacaoFactory: captacaoFactory,
                moeda: moeda,
                admin: admin,
                agenteOrq: agenteOrq,
                agenteGateway: agenteGateway,
                actors: actors,
                investidorFuzz: investidorFuzz
            })
        );

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    function _handlerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = HandlerOrquestrador.autorizarEmissor.selector;
        selectors[1] = HandlerOrquestrador.revogarEmissor.selector;
        selectors[2] = HandlerOrquestrador.pausarOuDespausar.selector;
        selectors[3] = HandlerOrquestrador.criarOfertaCompleta.selector;
        selectors[4] = HandlerOrquestrador.fecharUltimaOfertaComFalha.selector;
        selectors[5] = HandlerOrquestrador.fecharUltimaOfertaComSucesso.selector;
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

    // ── Invariante 1: totalSupply <= cotasAutorizadas para todo token criado via orquestrador ──

    function invariant_TotalSupplyNeverExceedsCotasAutorizadas() public view {
        uint256 n = handler.numTokens();
        for (uint256 i = 0; i < n; i++) {
            ParticipacaoToken token = ParticipacaoToken(handler.tokens(i));
            assertLe(token.totalSupply(), token.cotasAutorizadas());
        }
    }

    // ── Invariante 2: nenhuma oferta criada via orquestrador existe fora dos limites Res. 88 ──

    function invariant_NenhumaOfertaForaDosLimitesRes88() public view {
        uint256 n = handler.numOfertas();
        for (uint256 i = 0; i < n; i++) {
            OfertaCaptacao oferta = OfertaCaptacao(handler.ofertas(i));
            uint256 criadoEm = handler.ghost_criadoEm(address(oferta));

            assertLe(oferta.metaMaxima(), orq.TETO_OFERTA());
            assertLe(oferta.prazo() - criadoEm, orq.PRAZO_MAXIMO());
            assertLe(oferta.metaMaxima() * orq.LOTE_ADICIONAL_DENOMINADOR(), oferta.metaMinima() * orq.LOTE_ADICIONAL_NUMERADOR());
        }
    }

    // ── Invariante 3: nenhum emissor tem mais de uma oferta Aberta simultaneamente ──────────

    function invariant_NenhumEmissorComMaisDeUmaOfertaAberta() public view {
        uint256 numEmissores = handler.numEmissoresRastreados();
        uint256 numOfertas = handler.numOfertas();

        for (uint256 e = 0; e < numEmissores; e++) {
            address emissor = handler.emissoresRastreados(e);
            uint256 abertasDoEmissor = 0;

            for (uint256 i = 0; i < numOfertas; i++) {
                OfertaCaptacao oferta = OfertaCaptacao(handler.ofertas(i));
                if (oferta.emissorWallet() == emissor && oferta.estado() == OfertaCaptacao.Estado.Aberta) {
                    abertasDoEmissor++;
                }
            }

            assertLe(abertasDoEmissor, 1);
        }
    }

    // ── Invariante 4: emissorWallet de toda oferta estava em emissoresAutorizados na criação ──

    function invariant_TodaOfertaTinhaEmissorAutorizadoNaCriacao() public view {
        uint256 n = handler.numOfertas();
        for (uint256 i = 0; i < n; i++) {
            address oferta = handler.ofertas(i);
            assertTrue(handler.ghost_autorizadoNaCriacao(oferta));
        }
    }

    // ── Invariantes adicionais (mesmo padrão de profundidade defensiva das fases anteriores) ──

    function invariant_NoUnauthorizedAdminActionEverSucceeded() public view {
        assertFalse(handler.ghost_unauthorizedAdminActionSucceeded());
    }

    function invariant_TaxaBpsNeverExceedsMaximo() public view {
        assertLe(orq.taxaBps(), TAXA_BPS_MAXIMA);
    }
}
