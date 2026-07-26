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

/// @notice Testes de invariante com fuzzing stateful do domínio de captação (Fase 2): o
/// `HandlerCaptacao` executa sequências aleatórias de criarCaptacao/aportar/encerrar/
/// resgatarCotas/liberarParaEmissor/reembolsar/definirQualificado/cancelar, mais tentativas
/// deliberadas de burlar guardas, e as funções abaixo verificam que os invariantes de dinheiro
/// da Fase 2 se mantêm após CADA chamada. Mesma escala de `InvariantTest` (Fase 1):
/// `runs=256 * depth=100` = 25.600 chamadas por invariante (ver `[invariant]` em foundry.toml).
contract InvariantCaptacaoTest is Test {
    OfertaCaptacaoFactory public factory;
    OfertaCaptacao public captacaoImplementacao;
    EmissaoGateway public gateway;
    RegistroInvestidorQualificado public registro;
    ParticipacaoToken public tokenImplementacao;
    DenyAllTransferPolicy public policy;
    MockBRL public moeda;
    HandlerCaptacao public handler;

    address public admin = makeAddr("admin");
    address public agente = makeAddr("agente");
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
        tokenImplementacao = new ParticipacaoToken();
        policy = new DenyAllTransferPolicy();
        captacaoImplementacao = new OfertaCaptacao();

        factory = new OfertaCaptacaoFactory(
            admin,
            address(captacaoImplementacao),
            address(gateway),
            address(registro),
            address(moeda),
            TIMELOCK_DELAY
        );
    }

    function _wireRoles() internal {
        _grantRoleOn(address(gateway), gateway.AGENTE_ROLE(), agente);
        _grantRoleOn(address(registro), registro.AGENTE_ROLE(), agente);
        _grantRoleOn(address(factory), factory.AGENTE_ROLE(), agente);
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
                registro: registro,
                moeda: moeda,
                tokenImplementacao: tokenImplementacao,
                policy: policy,
                admin: admin,
                agente: agente,
                emissorWallet: emissorWallet,
                protocoloWallet: protocoloWallet,
                actors: actors
            })
        );

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    function _handlerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](15);
        selectors[0] = HandlerCaptacao.criarCaptacaoEToken.selector;
        selectors[1] = HandlerCaptacao.aportar.selector;
        selectors[2] = HandlerCaptacao.avancarTempo.selector;
        selectors[3] = HandlerCaptacao.encerrar.selector;
        selectors[4] = HandlerCaptacao.tentarEncerrarPrematuramente.selector;
        selectors[5] = HandlerCaptacao.definirQualificado.selector;
        selectors[6] = HandlerCaptacao.cancelar.selector;
        selectors[7] = HandlerCaptacao.reembolsar.selector;
        selectors[8] = HandlerCaptacao.tentarReembolsarDuasVezes.selector;
        selectors[9] = HandlerCaptacao.resgatarCotas.selector;
        selectors[10] = HandlerCaptacao.tentarResgatarDuasVezes.selector;
        selectors[11] = HandlerCaptacao.liberarParaEmissor.selector;
        selectors[12] = HandlerCaptacao.tentarLiberarDuasVezes.selector;
        selectors[13] = HandlerCaptacao.tentarAportarForaDoEstado.selector;
        selectors[14] = HandlerCaptacao.tentarExcederTetoSemQualificacao.selector;
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

    // ── Invariante central: contabilidade do escrow ──────────────────────────────────────

    function invariant_EscrowAccountingMatchesCustody() public view {
        uint256 n = handler.numCaptacoes();
        for (uint256 i = 0; i < n; i++) {
            OfertaCaptacao oferta = OfertaCaptacao(handler.captacoes(i));
            uint256 esperado = oferta.recursosLiberados()
                ? 0
                : oferta.totalArrecadado() - handler.ghost_sumReembolsado(address(oferta));
            assertEq(moeda.balanceOf(address(oferta)), esperado);
        }
    }

    // ── Reembolso nunca excede o arrecadado; nenhum duplo reembolso ─────────────────────

    function invariant_ReembolsoNuncaExcedeArrecadado() public view {
        uint256 n = handler.numCaptacoes();
        for (uint256 i = 0; i < n; i++) {
            OfertaCaptacao oferta = OfertaCaptacao(handler.captacoes(i));
            assertLe(handler.ghost_sumReembolsado(address(oferta)), oferta.totalArrecadado());
        }
    }

    function invariant_NoDoubleReembolsoEverSucceeded() public view {
        assertFalse(handler.ghost_doubleReembolsoSucceeded());
    }

    // ── Não distribui cota além do subscrito; nenhum duplo resgate ──────────────────────

    function invariant_CotasMintadasNuncaExcedemSubscrito() public view {
        uint256 n = handler.numCaptacoes();
        for (uint256 i = 0; i < n; i++) {
            OfertaCaptacao oferta = OfertaCaptacao(handler.captacoes(i));
            assertLe(handler.ghost_sumCotasMintadas(address(oferta)), oferta.totalArrecadado() / oferta.precoPorCota());
        }
    }

    function invariant_NoDoubleResgateEverSucceeded() public view {
        assertFalse(handler.ghost_doubleResgateSucceeded());
    }

    // ── Nunca acima da meta máxima ───────────────────────────────────────────────────────

    function invariant_TotalArrecadadoNeverExceedsMetaMaxima() public view {
        uint256 n = handler.numCaptacoes();
        for (uint256 i = 0; i < n; i++) {
            OfertaCaptacao oferta = OfertaCaptacao(handler.captacoes(i));
            assertLe(oferta.totalArrecadado(), oferta.metaMaxima());
        }
    }

    // ── Teto por investidor respeitado (não-qualificados) ───────────────────────────────
    //
    // Checado no momento da chamada (ghost), não como snapshot retroativo: qualificação é uma
    // flag mutável, e um investidor pode legitimamente ficar acima do teto vigente se foi
    // qualificado no momento do aporte e desqualificado depois — sem confisco retroativo.

    function invariant_NoTetoBypassEverSucceeded() public view {
        assertFalse(handler.ghost_tetoBypassSucceeded());
    }

    // ── Exclusão sucesso/fracasso: nunca os dois para a mesma captação ──────────────────

    function invariant_NuncaReembolsoEMintJuntos() public view {
        uint256 n = handler.numCaptacoes();
        for (uint256 i = 0; i < n; i++) {
            address oferta = handler.captacoes(i);
            bool houveReembolso = handler.ghost_houveReembolso(oferta);
            bool houveMintOuLiberacao = handler.ghost_houveMintOuLiberacao(oferta);
            assertFalse(houveReembolso && houveMintOuLiberacao);
        }
    }

    // ── Estados monotônicos / guardas de autorização e liberação dupla ──────────────────

    function invariant_NoUnauthorizedActionEverSucceeded() public view {
        assertFalse(handler.ghost_unauthorizedActionSucceeded());
    }

    function invariant_NoDoubleLiberacaoEverSucceeded() public view {
        assertFalse(handler.ghost_doubleLiberacaoSucceeded());
    }

    function invariant_NoAportarForaDoEstadoEverSucceeded() public view {
        assertFalse(handler.ghost_aportarForaDoEstadoSucceeded());
    }

    function invariant_NoEncerramentoPrematuroEverSucceeded() public view {
        assertFalse(handler.ghost_encerramentoPrematuroSucceeded());
    }
}
