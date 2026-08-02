// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";
import {HandlerPolitica} from "./invariant/HandlerPolitica.sol";

/// @notice Testes de invariante com fuzzing stateful do domínio da política restrita (Fase 3):
/// o `HandlerPolitica` executa sequências aleatórias de criarToken/mintar/definirElegivel/
/// definirLockup/abrirSecundario/avancarTempo/tentarTransferir, mais tentativas deliberadas de
/// burlar guardas, e as funções abaixo verificam que a tabela-verdade de `canTransfer` e as
/// guardas de acesso se mantêm após CADA chamada. Mesma escala de `InvariantTest`/
/// `InvariantCaptacaoTest`: `runs=256 * depth=100` = 25.600 chamadas por invariante (ver
/// `[invariant]` em foundry.toml).
contract InvariantPoliticaTest is Test {
    EmissaoGateway public gateway;
    RestrictedTransferPolicy public policy;
    ParticipacaoToken public tokenImplementacao;
    HandlerPolitica public handler;

    address public admin = makeAddr("adminPolitica");
    address public agente = makeAddr("agentePolitica");

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
    }

    function _wireRoles() internal {
        _grantRoleOn(address(gateway), gateway.AGENTE_ROLE(), agente);
        _grantRoleOn(address(policy), policy.AGENTE_ROLE(), agente);
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
                tokenImplementacao: tokenImplementacao,
                admin: admin,
                agente: agente,
                actors: actors
            })
        );

        // Garante ao menos um token antes do motor de invariantes começar a chamar as demais
        // ações (elas retornam cedo se `tokens.length == 0`, mas isso desperdiçaria as
        // primeiras chamadas da sequência).
        handler.criarToken(0);

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    function _handlerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](8);
        selectors[0] = HandlerPolitica.criarToken.selector;
        selectors[1] = HandlerPolitica.mintar.selector;
        selectors[2] = HandlerPolitica.definirElegivel.selector;
        selectors[3] = HandlerPolitica.definirLockup.selector;
        selectors[4] = HandlerPolitica.tentarLockupDuplicado.selector;
        selectors[5] = HandlerPolitica.abrirSecundario.selector;
        selectors[6] = HandlerPolitica.avancarTempo.selector;
        selectors[7] = HandlerPolitica.tentarTransferir.selector;
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

    // ── Invariante central: nenhuma transferência teve resultado diferente do previsto pela
    // tabela-verdade (secundarioLiberado && !lockup && elegivel[to]) ──────────────────────

    function invariant_NoTruthTableViolationEverHappened() public view {
        assertFalse(handler.ghost_truthTableViolated());
    }

    // ── Mint nunca falha por causa do estado da política restrita ─────────────────────────

    function invariant_MintNeverFailsBecauseOfPolicyState() public view {
        assertFalse(handler.ghost_mintFailedUnexpectedly());
    }

    // ── Guardas de acesso: só AGENTE opera allowlist/lockup; só ADMIN (via timelock) liga a
    // flag mestre; lock-up é set-once ───────────────────────────────────────────────────────

    function invariant_NoUnauthorizedOperationalCallEverSucceeded() public view {
        assertFalse(handler.ghost_unauthorizedOperationalCallSucceeded());
    }

    function invariant_NoUnauthorizedSecundarioToggleEverSucceeded() public view {
        assertFalse(handler.ghost_unauthorizedSecundarioToggleSucceeded());
    }

    function invariant_NoDoubleLockupEverSucceeded() public view {
        assertFalse(handler.ghost_doubleLockupSucceeded());
    }

    // ── Isolamento entre tokens: o espelho mantido pelo handler bate com os getters reais da
    // política para todo token já criado — se uma escrita em um token vazasse para outro, o
    // espelho do outro divergiria ────────────────────────────────────────────────────────────

    function invariant_NoStateLeaksBetweenTokens() public view {
        uint256 nTokens = handler.numTokens();
        uint256 nActors = handler.numActors();
        for (uint256 i = 0; i < nTokens; i++) {
            address token = handler.tokens(i);
            assertEq(policy.secundarioLiberado(token), handler.ghost_secundarioLiberadoEsperado(token));
            assertEq(policy.lockupAte(token), handler.ghost_lockupAteEsperado(token));
            for (uint256 j = 0; j < nActors; j++) {
                address investidor = handler.actors(j);
                assertEq(policy.elegivel(token, investidor), handler.ghost_elegivelEsperado(token, investidor));
            }
        }
    }
}
