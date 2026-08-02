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

/// @notice Testes de invariante com fuzzing stateful do domínio da liquidação secundária (Fase
/// 4): o `HandlerSecundario` executa sequências aleatórias de criarToken/mintarCotas/
/// mintarMoeda/aprovarCotas/aprovarMoeda/definirElegivel/definirLockup/abrirSecundario/
/// avancarTempo/tentarLiquidarCessao/ajustarTaxa, e as funções abaixo verificam conservação,
/// atomicidade e as guardas de acesso/política a cada chamada. Mesma escala das fases
/// anteriores: `runs=256 * depth=100` = 25.600 chamadas por invariante (ver `[invariant]` em
/// foundry.toml).
///
/// A factory desta suíte é implantada com a `RestrictedTransferPolicy` compartilhada como
/// `transferPolicyPadrao` (em vez de `DenyAllTransferPolicy`) — o mecanismo de TROCAR a política
/// de um token já vivo já foi provado exaustivamente em `InvariantPoliticaTest` (Fase 3); aqui o
/// foco é o dinheiro e o gate, não o mecanismo de troca em si.
contract InvariantSecundarioTest is Test {
    ParticipacaoTokenFactory public factory;
    ParticipacaoToken public tokenImplementacao;
    EmissaoGateway public gateway;
    RestrictedTransferPolicy public policy;
    MockBRL public moeda;
    LiquidacaoSecundaria public liquidacao;
    HandlerSecundario public handler;

    address public admin = makeAddr("adminSecundario");
    address public agente = makeAddr("agenteSecundario");
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
        tokenImplementacao = new ParticipacaoToken();
        factory =
            new ParticipacaoTokenFactory(admin, address(tokenImplementacao), address(gateway), address(policy), TIMELOCK_DELAY);
        moeda = new MockBRL();
        liquidacao = new LiquidacaoSecundaria(admin, address(moeda), address(factory), protocoloWallet, TIMELOCK_DELAY);
    }

    function _wireRoles() internal {
        _grantRoleOn(address(gateway), gateway.AGENTE_ROLE(), agente);
        _grantRoleOn(address(factory), factory.AGENTE_ROLE(), agente);
        _grantRoleOn(address(policy), policy.AGENTE_ROLE(), agente);
        _grantRoleOn(address(liquidacao), liquidacao.AGENTE_ROLE(), agente);
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
                moeda: moeda,
                liquidacao: liquidacao,
                admin: admin,
                agente: agente,
                actors: actors
            })
        );

        handler.criarToken(0);

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    function _handlerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](11);
        selectors[0] = HandlerSecundario.criarToken.selector;
        selectors[1] = HandlerSecundario.mintarCotas.selector;
        selectors[2] = HandlerSecundario.mintarMoeda.selector;
        selectors[3] = HandlerSecundario.aprovarCotas.selector;
        selectors[4] = HandlerSecundario.aprovarMoeda.selector;
        selectors[5] = HandlerSecundario.definirElegivel.selector;
        selectors[6] = HandlerSecundario.definirLockup.selector;
        selectors[7] = HandlerSecundario.abrirSecundario.selector;
        selectors[8] = HandlerSecundario.avancarTempo.selector;
        selectors[9] = HandlerSecundario.tentarLiquidarCessao.selector;
        selectors[10] = HandlerSecundario.ajustarTaxa.selector;
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

    // ── Invariante central: conservação de MockBRL e de cotas, para todo ator e todo token —
    // prova, ao mesmo tempo, atomicidade (nenhum saldo se move fora de uma liquidação
    // confirmada bem-sucedida) ────────────────────────────────────────────────────────────

    function invariant_ConservacaoDeMoeda() public view {
        uint256 nActors = handler.numActors();
        for (uint256 i = 0; i < nActors; i++) {
            address actor = handler.actors(i);
            assertEq(moeda.balanceOf(actor), handler.ghost_moedaEsperada(actor));
        }
        assertEq(moeda.balanceOf(protocoloWallet), handler.ghost_moedaEsperada(protocoloWallet));
    }

    function invariant_ConservacaoDeCotas() public view {
        uint256 nTokens = handler.numTokens();
        uint256 nActors = handler.numActors();
        for (uint256 i = 0; i < nTokens; i++) {
            address token = handler.tokens(i);
            for (uint256 j = 0; j < nActors; j++) {
                address actor = handler.actors(j);
                assertEq(ParticipacaoToken(token).balanceOf(actor), handler.ghost_cotasEsperadas(token, actor));
            }
        }
    }

    // ── Gate da política nunca contornado ──────────────────────────────────────────────

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

    // ── Teto de taxa nunca excedido ─────────────────────────────────────────────────────

    function invariant_TaxaNuncaExcedeuOTeto() public view {
        assertFalse(handler.ghost_taxaExcedeuTetoSucceeded());
        assertLe(liquidacao.taxaSecundarioBps(), liquidacao.TAXA_BPS_MAXIMA());
    }
}
