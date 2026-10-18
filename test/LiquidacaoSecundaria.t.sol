// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
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
    LiquidacaoSecundaria public settlement;
    ParticipacaoToken public token;

    address public admin = makeAddr("admin");
    address public agent = makeAddr("agente");
    address public stranger = makeAddr("estranho");
    address public protocoloWallet = makeAddr("protocoloWallet");
    address public vendedor = makeAddr("vendedor");
    address public comprador = makeAddr("comprador");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public agentRole;

    uint256 public constant PRICE_PER_SHARE = 100 ether; // 100 MockBRL per whole share
    uint256 public constant SELLER_INITIAL_SHARES = 50 ether; // 50 shares

    function setUp() public {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        policy = new RestrictedTransferPolicy(admin, TIMELOCK_DELAY);
        moeda = new MockBRL();

        ParticipacaoToken tokenImpl = new ParticipacaoToken();
        factory =
            new ParticipacaoTokenFactory(admin, address(tokenImpl), address(gateway), address(policy), TIMELOCK_DELAY);

        settlement = new LiquidacaoSecundaria(admin, address(moeda), address(factory), protocoloWallet, TIMELOCK_DELAY);
        agentRole = settlement.AGENTE_ROLE();

        _grantRole(address(gateway), gateway.AGENTE_ROLE(), agent);
        _grantRole(address(factory), factory.AGENTE_ROLE(), agent);
        _grantRole(address(policy), policy.AGENTE_ROLE(), agent);
        _grantRole(address(settlement), settlement.AGENTE_ROLE(), agent);

        vm.prank(agent);
        address tokenAddr = factory.criarOferta("Oferta X", "nX", "Empresa X", bytes32(0), "2026-A");
        token = ParticipacaoToken(tokenAddr);

        vm.prank(agent);
        gateway.atestarCotas(address(token), 1_000_000 ether);
        vm.prank(agent);
        gateway.emitir(address(token), vendedor, SELLER_INITIAL_SHARES);

        moeda.mint(comprador, 1_000_000 ether);

        vm.prank(vendedor);
        token.approve(address(settlement), type(uint256).max);
        vm.prank(comprador);
        moeda.approve(address(settlement), type(uint256).max);
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

    function _openSecondaryForBuyer() internal {
        vm.prank(agent);
        policy.definirLockup(address(token), uint64(block.timestamp));
        vm.prank(agent);
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

    function test_LiquidarCessao_OnlyAgent() public {
        _openSecondaryForBuyer();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agentRole)
        );
        settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);
    }

    function test_LiquidarCessao_RevertsForUnknownToken() public {
        address unknownToken = makeAddr("tokenDesconhecido");
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(LiquidacaoSecundaria.TokenDesconhecido.selector, unknownToken));
        settlement.liquidarCessao(unknownToken, vendedor, comprador, 10 ether, PRICE_PER_SHARE);
    }

    function test_LiquidarCessao_RevertsForZeroQuantidade() public {
        _openSecondaryForBuyer();
        vm.prank(agent);
        vm.expectRevert(LiquidacaoSecundaria.QuantidadeInvalida.selector);
        settlement.liquidarCessao(address(token), vendedor, comprador, 0, PRICE_PER_SHARE);
    }

    function test_LiquidarCessao_RevertsForZeroPreco() public {
        _openSecondaryForBuyer();
        vm.prank(agent);
        vm.expectRevert(LiquidacaoSecundaria.PrecoInvalido.selector);
        settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, 0);
    }

    function test_LiquidarCessao_RevertsForZeroAmountAfterRounding() public {
        _openSecondaryForBuyer();
        // quantidade and precoPorCota != 0, but the derived amount (quantidade * precoPorCota /
        // UNIDADE_COTA) rounds to zero; it must be blocked separately from QuantidadeInvalida/
        // PrecoInvalido, which only cover the raw parameters, not the derived amount.
        vm.prank(agent);
        vm.expectRevert(LiquidacaoSecundaria.ValorInvalido.selector);
        settlement.liquidarCessao(address(token), vendedor, comprador, 1, 1);
    }

    // ── Anti-evasion by splitting (fee active, amount too small for the fee not to
    // truncate to zero) ──────────────────────────────────────────────────────────────────

    function test_LiquidarCessao_RevertsWhenFeeTruncatesToZero() public {
        _openSecondaryForBuyer();
        _setFee(1); // 0.01%

        // valor = (1 ether * 1) / 1 ether = 1 wei of MockBRL: not zero (passes ValorInvalido),
        // but taxa = (1 * 1) / 10_000 = 0 by integer-division truncation, with the fee ACTIVE.
        vm.prank(agent);
        vm.expectRevert(LiquidacaoSecundaria.ValorInsuficienteParaPrecisaoDaTaxa.selector);
        settlement.liquidarCessao(address(token), vendedor, comprador, 1 ether, 1);
    }

    function test_LiquidarCessao_SucceedsWhenAmountSufficientForFeePrecision() public {
        _openSecondaryForBuyer();
        _setFee(1); // 0.01%, same rate as the test above

        // valor = 1,000 ether, taxa = 1,000 ether * 1 / 10_000 = 0.1 ether: does not truncate to zero.
        vm.prank(agent);
        uint256 feeCharged = settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);

        assertEq(feeCharged, 0.1 ether);
        assertEq(token.balanceOf(comprador), 10 ether);
    }

    function test_LiquidarCessao_DormantFeeNeverTriggersTruncationGuard() public {
        // taxaSecundarioBps == 0 (default): the guard must not fire even with a tiny amount,
        // since the condition requires taxaSecundarioBps > 0.
        _openSecondaryForBuyer();

        vm.prank(agent);
        settlement.liquidarCessao(address(token), vendedor, comprador, 1 ether, 1);

        assertEq(token.balanceOf(comprador), 1 ether);
    }

    function test_LiquidarCessao_RevertsForSellerEqualsBuyer() public {
        vm.prank(agent);
        vm.expectRevert(LiquidacaoSecundaria.VendedorIgualComprador.selector);
        settlement.liquidarCessao(address(token), vendedor, vendedor, 10 ether, PRICE_PER_SHARE);
    }

    function test_LiquidarCessao_RevertsForZeroToken() public {
        vm.prank(agent);
        vm.expectRevert(LiquidacaoSecundaria.ZeroAddress.selector);
        settlement.liquidarCessao(address(0), vendedor, comprador, 10 ether, PRICE_PER_SHARE);
    }

    function test_LiquidarCessao_RevertsForZeroSeller() public {
        vm.prank(agent);
        vm.expectRevert(LiquidacaoSecundaria.ZeroAddress.selector);
        settlement.liquidarCessao(address(token), address(0), comprador, 10 ether, PRICE_PER_SHARE);
    }

    function test_LiquidarCessao_RevertsForZeroBuyer() public {
        vm.prank(agent);
        vm.expectRevert(LiquidacaoSecundaria.ZeroAddress.selector);
        settlement.liquidarCessao(address(token), vendedor, address(0), 10 ether, PRICE_PER_SHARE);
    }

    // ── Fee charged return value (feeCharged) ───────────────────────────────────────────

    function test_LiquidarCessao_ReturnsTaxaCobrada() public {
        _openSecondaryForBuyer();
        _setFee(50);

        vm.prank(agent);
        uint256 returnedFee = settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);

        assertEq(returnedFee, 5 ether); // 0.5% de 1.000 ether
    }

    function test_LiquidarCessao_ReturnsZeroWhenFeeDormant() public {
        _openSecondaryForBuyer();

        vm.prank(agent);
        uint256 returnedFee = settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);

        assertEq(returnedFee, 0);
    }

    // ── Emergency pause ─────────────────────────────────────────────────────────────────

    function test_Pause_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agentRole)
        );
        settlement.pause();
    }

    function test_Unpause_OnlyAgent() public {
        vm.prank(agent);
        settlement.pause();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agentRole)
        );
        settlement.unpause();
    }

    function test_LiquidarCessao_RevertsWhenPaused() public {
        _openSecondaryForBuyer();
        vm.prank(agent);
        settlement.pause();

        vm.prank(agent);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);
    }

    function test_LiquidarCessao_SucceedsAfterUnpause() public {
        _openSecondaryForBuyer();
        vm.prank(agent);
        settlement.pause();
        vm.prank(agent);
        settlement.unpause();

        vm.prank(agent);
        settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);

        assertEq(token.balanceOf(comprador), 10 ether);
    }

    // ── Policy gate (ties Phase 3 ↔ Phase 4) ─────────────────────────────────────────────

    function test_LiquidarCessao_RevertsWhenSecondaryOff() public {
        // Policy not even configured: secundarioLiberado defaults to false.
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidacaoSecundaria.CessaoNaoPermitidaPelaPolitica.selector,
                address(token),
                vendedor,
                comprador,
                10 ether
            )
        );
        settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);
    }

    function test_LiquidarCessao_RevertsDuringLockup() public {
        vm.prank(agent);
        policy.definirLockup(address(token), uint64(block.timestamp + 30 days));
        vm.prank(agent);
        policy.definirElegivel(address(token), comprador, true);
        vm.prank(admin);
        policy.proposeSetSecundarioLiberado(address(token), true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        policy.executeSetSecundarioLiberado(address(token), true);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidacaoSecundaria.CessaoNaoPermitidaPelaPolitica.selector,
                address(token),
                vendedor,
                comprador,
                10 ether
            )
        );
        settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);
    }

    function test_LiquidarCessao_RevertsForNonEligibleBuyer() public {
        vm.prank(agent);
        policy.definirLockup(address(token), uint64(block.timestamp));
        // the buyer is deliberately NOT added to the allowlist.
        vm.prank(admin);
        policy.proposeSetSecundarioLiberado(address(token), true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        policy.executeSetSecundarioLiberado(address(token), true);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidacaoSecundaria.CessaoNaoPermitidaPelaPolitica.selector,
                address(token),
                vendedor,
                comprador,
                10 ether
            )
        );
        settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);
    }

    // ── Success: conservation of assets ──────────────────────────────────────────────────

    function test_LiquidarCessao_MovesSharesAndCurrency_NoFee() public {
        _openSecondaryForBuyer();

        vm.prank(agent);
        settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);

        assertEq(token.balanceOf(vendedor), SELLER_INITIAL_SHARES - 10 ether);
        assertEq(token.balanceOf(comprador), 10 ether);

        uint256 expectedAmount = 1_000 ether; // 10 shares * 100 MockBRL
        assertEq(moeda.balanceOf(vendedor), expectedAmount);
        assertEq(moeda.balanceOf(comprador), 1_000_000 ether - expectedAmount);
        assertEq(moeda.balanceOf(protocoloWallet), 0);
    }

    function test_LiquidarCessao_MovesSharesAndCurrency_WithFee() public {
        _openSecondaryForBuyer();
        _setFee(50); // 0.5%

        vm.prank(agent);
        settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);

        uint256 valor = 1_000 ether;
        uint256 expectedFee = (valor * 50) / 10_000; // 5 ether
        assertEq(moeda.balanceOf(protocoloWallet), expectedFee);
        assertEq(moeda.balanceOf(vendedor), valor - expectedFee);
        assertEq(moeda.balanceOf(comprador), 1_000_000 ether - valor);
        assertEq(token.balanceOf(comprador), 10 ether);
    }

    function test_LiquidarCessao_EmitsEvent() public {
        _openSecondaryForBuyer();
        _setFee(50);

        uint256 valor = 1_000 ether;
        uint256 taxa = 5 ether;

        vm.expectEmit(true, true, true, true, address(settlement));
        emit LiquidacaoSecundaria.CessaoLiquidada(address(token), vendedor, comprador, 10 ether, valor, taxa);
        vm.prank(agent);
        settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);
    }

    // ── Clean failures: insufficient allowance/balance ──────────────────────────────────

    function test_LiquidarCessao_RevertsWithoutBuyerAllowance() public {
        _openSecondaryForBuyer();
        vm.prank(comprador);
        moeda.approve(address(settlement), 0);

        vm.prank(agent);
        vm.expectRevert();
        settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);

        assertEq(token.balanceOf(vendedor), SELLER_INITIAL_SHARES);
        assertEq(token.balanceOf(comprador), 0);
    }

    function test_LiquidarCessao_RevertsWithoutSellerAllowance() public {
        _openSecondaryForBuyer();
        vm.prank(vendedor);
        token.approve(address(settlement), 0);

        vm.prank(agent);
        vm.expectRevert();
        settlement.liquidarCessao(address(token), vendedor, comprador, 10 ether, PRICE_PER_SHARE);

        // No MockBRL should have moved. Atomicity: the token leg reverted last, and the revert
        // undoes the MockBRL legs already executed before it.
        assertEq(moeda.balanceOf(vendedor), 0);
        assertEq(moeda.balanceOf(comprador), 1_000_000 ether);
    }

    function test_LiquidarCessao_RevertsWhenSellerBalanceInsufficient() public {
        _openSecondaryForBuyer();
        vm.prank(agent);
        vm.expectRevert();
        settlement.liquidarCessao(address(token), vendedor, comprador, SELLER_INITIAL_SHARES + 1 ether, PRICE_PER_SHARE);
    }

    // ── setProtocoloWallet (timelock) ──────────────────────────────────────────────────

    function test_SetProtocoloWallet_RequiresTimelock() public {
        address novaWallet = makeAddr("novaWallet");
        vm.prank(admin);
        settlement.proposeSetProtocoloWallet(novaWallet);

        vm.prank(admin);
        vm.expectRevert();
        settlement.executeSetProtocoloWallet(novaWallet);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        settlement.executeSetProtocoloWallet(novaWallet);

        assertEq(settlement.protocoloWallet(), novaWallet);
    }

    function test_SetProtocoloWallet_OnlyAdminCanPropose() public {
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, DEFAULT_ADMIN_ROLE)
        );
        settlement.proposeSetProtocoloWallet(makeAddr("novaWallet"));
    }

    function test_SetProtocoloWallet_RevertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LiquidacaoSecundaria.ZeroAddress.selector);
        settlement.proposeSetProtocoloWallet(address(0));
    }

    // ── setTaxaSecundarioBps (timelock, hard cap) ──────────────────────────────────────

    function test_SetTaxaSecundarioBps_RequiresTimelock() public {
        vm.prank(admin);
        settlement.proposeSetTaxaSecundarioBps(75);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        settlement.executeSetTaxaSecundarioBps(75);

        assertEq(settlement.taxaSecundarioBps(), 75);
    }

    function test_SetTaxaSecundarioBps_RevertsAboveMaximo() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LiquidacaoSecundaria.TaxaExcedeMaximo.selector, 101, 100));
        settlement.proposeSetTaxaSecundarioBps(101);
    }

    /// @notice Defensive guard: `executeSetTaxaSecundarioBps` also rejects values above the cap,
    /// even without a prior proposal. Defense in depth, unreachable through the normal flow (there is
    /// never a pending proposal for a value `propose` would already have rejected), but covered.
    function test_ExecuteSetTaxaSecundarioBps_RevertsAboveMax_EvenWithoutPropose() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LiquidacaoSecundaria.TaxaExcedeMaximo.selector, 101, 100));
        settlement.executeSetTaxaSecundarioBps(101);
    }

    function test_SetTaxaSecundarioBps_OnlyAdminCanPropose() public {
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, agent, DEFAULT_ADMIN_ROLE)
        );
        settlement.proposeSetTaxaSecundarioBps(50);
    }

    function test_SetTaxaSecundarioBps_DefaultIsZero() public view {
        assertEq(settlement.taxaSecundarioBps(), 0);
    }

    // ── Helper ──────────────────────────────────────────────────────────────────────────

    function _setFee(uint256 novaTaxa) internal {
        vm.prank(admin);
        settlement.proposeSetTaxaSecundarioBps(novaTaxa);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        settlement.executeSetTaxaSecundarioBps(novaTaxa);
    }
}
