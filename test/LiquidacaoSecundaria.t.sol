// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";
import {LiquidacaoSecundaria} from "../src/secundario/LiquidacaoSecundaria.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";

contract LiquidacaoSecundariaTest is Test {
    EmissaoGateway public gateway;
    ParticipacaoTokenFactory public factory;
    RestrictedTransferPolicy public policy;
    MockBRL public moeda;
    LiquidacaoSecundaria public liquidacao;
    ParticipacaoToken public token;

    address public admin = makeAddr("admin");
    address public agente = makeAddr("agente");
    address public estranho = makeAddr("estranho");
    address public protocoloWallet = makeAddr("protocoloWallet");
    address public vendedor = makeAddr("vendedor");
    address public comprador = makeAddr("comprador");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public agenteRole;

    uint256 public constant PRECO_POR_COTA = 100 ether; // 100 MockBRL por cota inteira
    uint256 public constant COTAS_INICIAIS_VENDEDOR = 50 ether; // 50 cotas

    function setUp() public {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        policy = new RestrictedTransferPolicy(admin, TIMELOCK_DELAY);
        moeda = new MockBRL();

        ParticipacaoToken tokenImpl = new ParticipacaoToken();
        factory = new ParticipacaoTokenFactory(admin, address(tokenImpl), address(gateway), address(policy), TIMELOCK_DELAY);

        liquidacao = new LiquidacaoSecundaria(admin, address(moeda), address(factory), protocoloWallet, TIMELOCK_DELAY);
        agenteRole = liquidacao.AGENTE_ROLE();

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

        moeda.mint(comprador, 1_000_000 ether);

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

    function _abrirSecundarioParaComprador() internal {
        vm.prank(agente);
        policy.definirLockup(address(token), uint64(block.timestamp));
        vm.prank(agente);
        policy.definirElegivel(address(token), comprador, true);

        vm.prank(admin);
        policy.proposeSetSecundarioLiberado(address(token), true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        policy.executeSetSecundarioLiberado(address(token), true);
    }

    // ── Construtor ──────────────────────────────────────────────────────────────────────

    function test_Constructor_RevertsForZeroAdmin() public {
        vm.expectRevert(LiquidacaoSecundaria.ZeroAddress.selector);
        new LiquidacaoSecundaria(address(0), address(moeda), address(factory), protocoloWallet, TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForZeroMoeda() public {
        vm.expectRevert(LiquidacaoSecundaria.ZeroAddress.selector);
        new LiquidacaoSecundaria(admin, address(0), address(factory), protocoloWallet, TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForZeroFactory() public {
        vm.expectRevert(LiquidacaoSecundaria.ZeroAddress.selector);
        new LiquidacaoSecundaria(admin, address(moeda), address(0), protocoloWallet, TIMELOCK_DELAY);
    }

    function test_Constructor_RevertsForZeroProtocoloWallet() public {
        vm.expectRevert(LiquidacaoSecundaria.ZeroAddress.selector);
        new LiquidacaoSecundaria(admin, address(moeda), address(factory), address(0), TIMELOCK_DELAY);
    }

    // ── liquidarCessao: guardas de entrada ─────────────────────────────────────────────

    function test_LiquidarCessao_OnlyAgente() public {
        _abrirSecundarioParaComprador();
        vm.prank(estranho);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, estranho, agenteRole)
        );
        liquidacao.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRECO_POR_COTA);
    }

    function test_LiquidarCessao_RevertsForUnknownToken() public {
        address tokenDesconhecido = makeAddr("tokenDesconhecido");
        vm.prank(agente);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidacaoSecundaria.TokenDesconhecido.selector, tokenDesconhecido)
        );
        liquidacao.liquidarCessao(tokenDesconhecido, vendedor, comprador, 10 ether, PRECO_POR_COTA);
    }

    function test_LiquidarCessao_RevertsForZeroQuantidade() public {
        _abrirSecundarioParaComprador();
        vm.prank(agente);
        vm.expectRevert(LiquidacaoSecundaria.QuantidadeInvalida.selector);
        liquidacao.liquidarCessao(address(token), vendedor, comprador, 0, PRECO_POR_COTA);
    }

    function test_LiquidarCessao_RevertsForZeroPreco() public {
        _abrirSecundarioParaComprador();
        vm.prank(agente);
        vm.expectRevert(LiquidacaoSecundaria.PrecoInvalido.selector);
        liquidacao.liquidarCessao(address(token), vendedor, comprador, 10 ether, 0);
    }

    // ── Gate da política (amarra Fase 3 ↔ Fase 4) ──────────────────────────────────────

    function test_LiquidarCessao_RevertsWhenSecundarioDesligado() public {
        // Política nem sequer configurada — secundarioLiberado default false.
        vm.prank(agente);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidacaoSecundaria.CessaoNaoPermitidaPelaPolitica.selector, address(token), vendedor, comprador, 10 ether
            )
        );
        liquidacao.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRECO_POR_COTA);
    }

    function test_LiquidarCessao_RevertsDuringLockup() public {
        vm.prank(agente);
        policy.definirLockup(address(token), uint64(block.timestamp + 30 days));
        vm.prank(agente);
        policy.definirElegivel(address(token), comprador, true);
        vm.prank(admin);
        policy.proposeSetSecundarioLiberado(address(token), true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        policy.executeSetSecundarioLiberado(address(token), true);

        vm.prank(agente);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidacaoSecundaria.CessaoNaoPermitidaPelaPolitica.selector, address(token), vendedor, comprador, 10 ether
            )
        );
        liquidacao.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRECO_POR_COTA);
    }

    function test_LiquidarCessao_RevertsForNonEligibleComprador() public {
        vm.prank(agente);
        policy.definirLockup(address(token), uint64(block.timestamp));
        // comprador NÃO entra na allowlist de propósito.
        vm.prank(admin);
        policy.proposeSetSecundarioLiberado(address(token), true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        policy.executeSetSecundarioLiberado(address(token), true);

        vm.prank(agente);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidacaoSecundaria.CessaoNaoPermitidaPelaPolitica.selector, address(token), vendedor, comprador, 10 ether
            )
        );
        liquidacao.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRECO_POR_COTA);
    }

    // ── Sucesso: conservação de ativos ───────────────────────────────────────────────────

    function test_LiquidarCessao_MovesCotasAndMoeda_SemTaxa() public {
        _abrirSecundarioParaComprador();

        vm.prank(agente);
        liquidacao.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRECO_POR_COTA);

        assertEq(token.balanceOf(vendedor), COTAS_INICIAIS_VENDEDOR - 10 ether);
        assertEq(token.balanceOf(comprador), 10 ether);

        uint256 valorEsperado = 1_000 ether; // 10 cotas * 100 MockBRL
        assertEq(moeda.balanceOf(vendedor), valorEsperado);
        assertEq(moeda.balanceOf(comprador), 1_000_000 ether - valorEsperado);
        assertEq(moeda.balanceOf(protocoloWallet), 0);
    }

    function test_LiquidarCessao_MovesCotasAndMoeda_ComTaxa() public {
        _abrirSecundarioParaComprador();
        _setTaxa(50); // 0.5%

        vm.prank(agente);
        liquidacao.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRECO_POR_COTA);

        uint256 valor = 1_000 ether;
        uint256 taxaEsperada = (valor * 50) / 10_000; // 5 ether
        assertEq(moeda.balanceOf(protocoloWallet), taxaEsperada);
        assertEq(moeda.balanceOf(vendedor), valor - taxaEsperada);
        assertEq(moeda.balanceOf(comprador), 1_000_000 ether - valor);
        assertEq(token.balanceOf(comprador), 10 ether);
    }

    function test_LiquidarCessao_EmitsEvent() public {
        _abrirSecundarioParaComprador();
        _setTaxa(50);

        uint256 valor = 1_000 ether;
        uint256 taxa = 5 ether;

        vm.expectEmit(true, true, true, true, address(liquidacao));
        emit LiquidacaoSecundaria.CessaoLiquidada(address(token), vendedor, comprador, 10 ether, valor, taxa);
        vm.prank(agente);
        liquidacao.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRECO_POR_COTA);
    }

    // ── Falhas limpas: allowance/saldo insuficiente ─────────────────────────────────────

    function test_LiquidarCessao_RevertsWithoutCompradorAllowance() public {
        _abrirSecundarioParaComprador();
        vm.prank(comprador);
        moeda.approve(address(liquidacao), 0);

        vm.prank(agente);
        vm.expectRevert();
        liquidacao.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRECO_POR_COTA);

        assertEq(token.balanceOf(vendedor), COTAS_INICIAIS_VENDEDOR);
        assertEq(token.balanceOf(comprador), 0);
    }

    function test_LiquidarCessao_RevertsWithoutVendedorAllowance() public {
        _abrirSecundarioParaComprador();
        vm.prank(vendedor);
        token.approve(address(liquidacao), 0);

        vm.prank(agente);
        vm.expectRevert();
        liquidacao.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRECO_POR_COTA);

        // Nenhum MockBRL deve ter se movido — atomicidade: a perna do token reverteu por
        // último, e o revert desfaz as pernas de MockBRL já executadas antes dela.
        assertEq(moeda.balanceOf(vendedor), 0);
        assertEq(moeda.balanceOf(comprador), 1_000_000 ether);
    }

    function test_LiquidarCessao_RevertsWhenVendedorSaldoInsuficiente() public {
        _abrirSecundarioParaComprador();
        vm.prank(agente);
        vm.expectRevert();
        liquidacao.liquidarCessao(address(token), vendedor, comprador, COTAS_INICIAIS_VENDEDOR + 1 ether, PRECO_POR_COTA);
    }

    // ── setProtocoloWallet (timelock) ──────────────────────────────────────────────────

    function test_SetProtocoloWallet_RequiresTimelock() public {
        address novaWallet = makeAddr("novaWallet");
        vm.prank(admin);
        liquidacao.proposeSetProtocoloWallet(novaWallet);

        vm.prank(admin);
        vm.expectRevert();
        liquidacao.executeSetProtocoloWallet(novaWallet);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        liquidacao.executeSetProtocoloWallet(novaWallet);

        assertEq(liquidacao.protocoloWallet(), novaWallet);
    }

    function test_SetProtocoloWallet_OnlyAdminCanPropose() public {
        vm.prank(agente);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agente, DEFAULT_ADMIN_ROLE)
        );
        liquidacao.proposeSetProtocoloWallet(makeAddr("novaWallet"));
    }

    function test_SetProtocoloWallet_RevertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LiquidacaoSecundaria.ZeroAddress.selector);
        liquidacao.proposeSetProtocoloWallet(address(0));
    }

    // ── setTaxaSecundarioBps (timelock, teto rígido) ───────────────────────────────────

    function test_SetTaxaSecundarioBps_RequiresTimelock() public {
        vm.prank(admin);
        liquidacao.proposeSetTaxaSecundarioBps(75);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        liquidacao.executeSetTaxaSecundarioBps(75);

        assertEq(liquidacao.taxaSecundarioBps(), 75);
    }

    function test_SetTaxaSecundarioBps_RevertsAboveMaximo() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidacaoSecundaria.TaxaExcedeMaximo.selector, 101, 100)
        );
        liquidacao.proposeSetTaxaSecundarioBps(101);
    }

    function test_SetTaxaSecundarioBps_OnlyAdminCanPropose() public {
        vm.prank(agente);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agente, DEFAULT_ADMIN_ROLE)
        );
        liquidacao.proposeSetTaxaSecundarioBps(50);
    }

    function test_SetTaxaSecundarioBps_DefaultIsZero() public view {
        assertEq(liquidacao.taxaSecundarioBps(), 0);
    }

    // ── Helper ──────────────────────────────────────────────────────────────────────────

    function _setTaxa(uint256 novaTaxa) internal {
        vm.prank(admin);
        liquidacao.proposeSetTaxaSecundarioBps(novaTaxa);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        liquidacao.executeSetTaxaSecundarioBps(novaTaxa);
    }
}
