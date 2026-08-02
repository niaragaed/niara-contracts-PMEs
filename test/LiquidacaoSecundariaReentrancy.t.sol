// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";
import {LiquidacaoSecundaria} from "../src/secundario/LiquidacaoSecundaria.sol";
import {ReentrantMockBRL} from "./mocks/ReentrantMockBRL.sol";

/// @notice Prova dedicada de que `nonReentrant` (+ CEI) barra reentrada em `liquidarCessao` —
/// mesmo padrão de `test/OfertaCaptacaoReentrancy.t.sol` (Fase 2, ver CLAUDE.md). Usa
/// `ReentrantMockBRL`, que tenta reentrar o alvo configurado a partir do seu próprio
/// `transferFrom`, simulando uma stablecoin de BRL real com hook/callback — `MockBRL` (benigna)
/// não exercitaria essa proteção.
contract LiquidacaoSecundariaReentrancyTest is Test {
    EmissaoGateway public gateway;
    ParticipacaoTokenFactory public factory;
    RestrictedTransferPolicy public policy;
    ReentrantMockBRL public moeda;
    LiquidacaoSecundaria public liquidacao;
    ParticipacaoToken public token;

    address public admin = makeAddr("admin");
    address public agente = makeAddr("agente");
    address public protocoloWallet = makeAddr("protocoloWallet");
    address public vendedor = makeAddr("vendedor");
    address public comprador = makeAddr("comprador");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    uint256 public constant PRECO_POR_COTA = 100 ether;
    uint256 public constant COTAS_INICIAIS_VENDEDOR = 50 ether;
    uint256 public constant SALDO_INICIAL_COMPRADOR = 1_000_000 ether;

    function setUp() public {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        policy = new RestrictedTransferPolicy(admin, TIMELOCK_DELAY);
        moeda = new ReentrantMockBRL();

        ParticipacaoToken tokenImpl = new ParticipacaoToken();
        factory =
            new ParticipacaoTokenFactory(admin, address(tokenImpl), address(gateway), address(policy), TIMELOCK_DELAY);

        liquidacao = new LiquidacaoSecundaria(admin, address(moeda), address(factory), protocoloWallet, TIMELOCK_DELAY);

        _grantRole(address(gateway), gateway.AGENTE_ROLE(), agente);
        _grantRole(address(factory), factory.AGENTE_ROLE(), agente);
        _grantRole(address(policy), policy.AGENTE_ROLE(), agente);
        _grantRole(address(liquidacao), liquidacao.AGENTE_ROLE(), agente);

        vm.prank(agente);
        address tokenAddr = factory.criarOferta("Oferta X", "nX", "Empresa X", bytes32(0), "2026-A");
        token = ParticipacaoToken(tokenAddr);

        vm.prank(agente);
        gateway.atestarCotas(address(token), 1_000_000 ether);
        vm.prank(agente);
        gateway.emitir(address(token), vendedor, COTAS_INICIAIS_VENDEDOR);

        vm.prank(agente);
        policy.definirLockup(address(token), uint64(block.timestamp));
        vm.prank(agente);
        policy.definirElegivel(address(token), comprador, true);
        vm.prank(admin);
        policy.proposeSetSecundarioLiberado(address(token), true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        policy.executeSetSecundarioLiberado(address(token), true);

        moeda.mint(comprador, SALDO_INICIAL_COMPRADOR);
        vm.prank(vendedor);
        token.approve(address(liquidacao), type(uint256).max);
        vm.prank(comprador);
        moeda.approve(address(liquidacao), type(uint256).max);
    }

    function _grantRole(address target, bytes32 role, address account) internal {
        vm.prank(admin);
        (bool ok1,) = target.call(abi.encodeWithSignature("proposeGrantRole(bytes32,address)", role, account));
        require(ok1, "propose failed");
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        (bool ok2,) = target.call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, account));
        require(ok2, "execute failed");
    }

    function test_LiquidarCessao_BlockedByReentrancyGuard() public {
        moeda.configurarAtaque(
            address(liquidacao),
            abi.encodeWithSelector(
                LiquidacaoSecundaria.liquidarCessao.selector, address(token), vendedor, comprador, 10 ether, PRECO_POR_COTA
            )
        );

        vm.prank(agente);
        liquidacao.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRECO_POR_COTA);

        assertTrue(moeda.reentradaBloqueada());

        // A cessão original completou exatamente uma vez — sem duplo movimento de cotas nem
        // de moeda.
        assertEq(token.balanceOf(comprador), 10 ether);
        assertEq(token.balanceOf(vendedor), COTAS_INICIAIS_VENDEDOR - 10 ether);
        assertEq(moeda.balanceOf(vendedor), 1_000 ether);
        assertEq(moeda.balanceOf(comprador), SALDO_INICIAL_COMPRADOR - 1_000 ether);
    }
}
