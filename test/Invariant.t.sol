// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {Handler} from "./invariant/Handler.sol";

/// @notice Testes de invariante com fuzzing stateful (Foundry `invariant_*`): o `Handler`
/// executa sequências aleatórias de criarOferta/atestarCotas/emitir/tentativas de
/// transferência/tentativas de burlar acesso, disparadas por atores diferentes (agente e três
/// investidores), e as funções abaixo verificam que os invariantes centrais da plataforma se
/// mantêm após CADA chamada da sequência. Escala: `runs=256 * depth=100` (ver
/// `[invariant]` em foundry.toml) = 25.600 chamadas por rodada, espelhando deliberadamente a
/// escala usada em `niara-contracts` (ver Linhagem no CLAUDE.md).
contract InvariantTest is Test {
    ParticipacaoTokenFactory public factory;
    ParticipacaoToken public implementacao;
    EmissaoGateway public gateway;
    DenyAllTransferPolicy public policy;
    Handler public handler;

    address public admin = makeAddr("admin");
    address public agente = makeAddr("agente");

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
        factory =
            new ParticipacaoTokenFactory(admin, address(implementacao), address(gateway), address(policy), TIMELOCK_DELAY);
    }

    function _wireRoles() internal {
        _grantRoleOn(address(gateway), gateway.AGENTE_ROLE(), agente);
        _grantRoleOn(address(factory), factory.AGENTE_ROLE(), agente);
    }

    function _deployHandler() internal {
        address[] memory actors = new address[](3);
        actors[0] = makeAddr("investidor1");
        actors[1] = makeAddr("investidor2");
        actors[2] = makeAddr("investidor3");

        handler = new Handler(
            Handler.Config({factory: factory, gateway: gateway, admin: admin, agente: agente, actors: actors})
        );

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    function _handlerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = Handler.criarOferta.selector;
        selectors[1] = Handler.atestarCotas.selector;
        selectors[2] = Handler.emitir.selector;
        selectors[3] = Handler.pausarOuDespausarToken.selector;
        selectors[4] = Handler.pausarOuDespausarFactory.selector;
        selectors[5] = Handler.tentarTransferir.selector;
        selectors[6] = Handler.tentarTransferirFrom.selector;
        selectors[7] = Handler.tentarChamarRestritaNoToken.selector;
        selectors[8] = Handler.tentarReinicializar.selector;
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

    // ── Invariante central: totalSupply <= cotasAutorizadas, para todo token criado ───────

    function invariant_TotalSupplyNeverExceedsCotasAutorizadas() public view {
        uint256 n = handler.numTokens();
        for (uint256 i = 0; i < n; i++) {
            ParticipacaoToken token = ParticipacaoToken(handler.tokens(i));
            assertLe(token.totalSupply(), token.cotasAutorizadas());
        }
    }

    // ── Invariante: sum(saldos) == totalSupply, para todo token criado ───────────────────

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

    // ── Invariante: apenas o gateway atesta/minta/pausa no token; apenas AGENTE_ROLE opera
    // no gateway/factory ────────────────────────────────────────────────────────────────

    function invariant_NoUnauthorizedTokenCallEverSucceeded() public view {
        assertFalse(handler.ghost_unauthorizedTokenCallSucceeded());
    }

    function invariant_NoUnauthorizedRoleCallEverSucceeded() public view {
        assertFalse(handler.ghost_unauthorizedRoleCallSucceeded());
    }

    // ── Invariante: nenhuma transferência titular→titular passa (política nega-tudo) ─────

    function invariant_NoTransferEverSucceeded() public view {
        assertFalse(handler.ghost_transferSucceeded());
    }

    // ── Invariante: nenhum clone é reinicializável ────────────────────────────────────────

    function invariant_NoReinitializeEverSucceeded() public view {
        assertFalse(handler.ghost_reinitializeSucceeded());
    }
}
