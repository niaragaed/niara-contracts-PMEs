// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";
import {OfertaCaptacao} from "../src/captacao/OfertaCaptacao.sol";
import {IOfertaCaptacao} from "../src/interfaces/IOfertaCaptacao.sol";
import {RegistroInvestidorQualificado} from "../src/registro/RegistroInvestidorQualificado.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";

/// @notice Proves, with the full stack (gateway + fundraising), that switching the policy from
/// `DenyAllTransferPolicy` to `RestrictedTransferPolicy` breaks neither mint (`gateway.emitir`)
/// nor Phase 2's share redemption flow (`OfertaCaptacao.resgatarCotas`): both go straight
/// through `_update` with `from == address(0)`, never reading `transferPolicy` (see
/// `ParticipacaoToken._update`). It also exercises the full secondary-market opening cycle:
/// the transfer reverts before and passes after, the same script as `script/DemoFase3.s.sol`,
/// here as an automated test.
contract RestrictedTransferPolicyIntegrationTest is Test {
    EmissaoGateway public gateway;
    RegistroInvestidorQualificado public registro;
    MockBRL public moeda;
    ParticipacaoToken public token;
    RestrictedTransferPolicy public restricted;
    OfertaCaptacao public oferta;

    address public admin = makeAddr("admin");
    address public agent = makeAddr("agente");
    address public emissorWallet = makeAddr("emissorWallet");
    address public protocoloWallet = makeAddr("protocoloWallet");
    address public investor1 = makeAddr("investidor1");
    address public investor2 = makeAddr("investidor2");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    uint256 public constant MIN_TARGET = 10_000 ether;
    uint256 public constant MAX_TARGET = 50_000 ether;
    uint256 public constant PRICE_PER_SHARE = 100 ether;
    uint256 public constant PER_INVESTOR_CAP = 20_000 ether;
    uint256 public prazo;

    function setUp() public {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        moeda = new MockBRL();
        restricted = new RestrictedTransferPolicy(admin, TIMELOCK_DELAY);

        _grantRole(address(gateway), gateway.AGENTE_ROLE(), agent);
        _grantRole(address(registro), registro.AGENTE_ROLE(), agent);
        _grantRole(address(restricted), restricted.AGENTE_ROLE(), agent);

        DenyAllTransferPolicy denyAll = new DenyAllTransferPolicy();
        ParticipacaoToken tokenImpl = new ParticipacaoToken();
        token = ParticipacaoToken(Clones.clone(address(tokenImpl)));
        token.initialize("Oferta X", "nX", address(gateway), address(denyAll), "Empresa X", bytes32(0), "2026-A");

        vm.prank(agent);
        gateway.atestarCotas(address(token), (MAX_TARGET / PRICE_PER_SHARE) * 1 ether);

        prazo = block.timestamp + 30 days;
        OfertaCaptacao impl = new OfertaCaptacao();
        oferta = OfertaCaptacao(Clones.clone(address(impl)));
        oferta.initialize(
            IOfertaCaptacao.InitParams({
                token: address(token),
                gateway: address(gateway),
                registro: address(registro),
                moeda: address(moeda),
                emissorWallet: emissorWallet,
                protocoloWallet: protocoloWallet,
                metaMinima: MIN_TARGET,
                metaMaxima: MAX_TARGET,
                precoPorCota: PRICE_PER_SHARE,
                prazo: prazo,
                tetoPorInvestidor: PER_INVESTOR_CAP,
                taxaBps: 0
            })
        );
        vm.prank(agent);
        gateway.registrarCaptacao(address(token), address(oferta));

        moeda.mint(investor1, 1_000_000 ether);
        moeda.mint(investor2, 1_000_000 ether);
        vm.prank(investor1);
        moeda.approve(address(oferta), type(uint256).max);
        vm.prank(investor2);
        moeda.approve(address(oferta), type(uint256).max);
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

    function _pointToRestricted() internal {
        vm.prank(admin);
        gateway.proposeSetTransferPolicy(address(token), address(restricted));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        gateway.executeSetTransferPolicy(address(token), address(restricted));
    }

    // ── Mint keeps working with the Restricted policy attached, regardless of its state ───

    function test_Emitir_KeepsWorkingWithRestrictedAttached() public {
        _pointToRestricted();
        // secundarioLiberado is still false (default); mint should not care.

        vm.prank(agent);
        gateway.emitir(address(token), investor1, 100 ether);

        assertEq(token.balanceOf(investor1), 100 ether);
    }

    // ── resgatarCotas (Fase 2) continua funcionando com a Restricted anexada ──────────────

    function test_ResgatarCotas_KeepsWorkingWithRestrictedAttached() public {
        _pointToRestricted();

        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);

        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(investor1);
        oferta.resgatarCotas();

        assertEq(token.balanceOf(investor1), (MIN_TARGET / PRICE_PER_SHARE) * 1 ether);
    }

    // ── Full cycle: reverts before opening, passes after ───────────────────────────────────

    function test_FullCycle_OpenSecondaryAfterLockup() public {
        vm.prank(agent);
        gateway.emitir(address(token), investor1, 100 ether);

        // Still on DenyAllTransferPolicy, so it reverts.
        vm.prank(investor1);
        vm.expectRevert(ParticipacaoToken.TransferenciaNaoPermitida.selector);
        token.transfer(investor2, 10 ether);

        _pointToRestricted();

        // Pointing early is safe: secundarioLiberado is still false, so it keeps reverting.
        vm.prank(investor1);
        vm.expectRevert(ParticipacaoToken.TransferenciaNaoPermitida.selector);
        token.transfer(investor2, 10 ether);

        uint64 lockupAte = uint64(block.timestamp + 30 days);
        vm.prank(agent);
        restricted.definirLockup(address(token), lockupAte);
        vm.prank(agent);
        restricted.definirElegivel(address(token), investor2, true);

        vm.prank(admin);
        restricted.proposeSetSecundarioLiberado(address(token), true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        restricted.executeSetSecundarioLiberado(address(token), true);

        // Opened, but still within the lock-up, so it reverts.
        vm.prank(investor1);
        vm.expectRevert(ParticipacaoToken.TransferenciaNaoPermitida.selector);
        token.transfer(investor2, 10 ether);

        vm.warp(lockupAte);

        // Counterexample: non-eligible recipient, so it reverts.
        address notEligible = makeAddr("naoElegivel");
        vm.prank(investor1);
        vm.expectRevert(ParticipacaoToken.TransferenciaNaoPermitida.selector);
        token.transfer(notEligible, 10 ether);

        // Opened, after the lock-up, eligible recipient: it passes.
        vm.prank(investor1);
        token.transfer(investor2, 10 ether);
        assertEq(token.balanceOf(investor2), 10 ether);
        assertEq(token.balanceOf(investor1), 90 ether);
    }
}
