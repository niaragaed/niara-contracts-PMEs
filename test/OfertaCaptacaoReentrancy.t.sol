// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {OfertaCaptacao} from "../src/captacao/OfertaCaptacao.sol";
import {IOfertaCaptacao} from "../src/interfaces/IOfertaCaptacao.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RegistroInvestidorQualificado} from "../src/registro/RegistroInvestidorQualificado.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {ReentrantMockBRL} from "./mocks/ReentrantMockBRL.sol";

/// @notice Dedicated proof that `nonReentrant` (+ CEI) blocks re-entry into the three
/// `OfertaCaptacao` functions that move currency: `aportar` (incoming transferFrom),
/// `reembolsar` and `liberarParaEmissor` (outgoing transfer). Uses `ReentrantMockBRL`, a
/// malicious currency that tries to re-enter the configured target on every
/// `transfer`/`transferFrom`, simulating a real BRL stablecoin with a hook, since the benign
/// `MockBRL` would not exercise this protection.
contract OfertaCaptacaoReentrancyTest is Test {
    OfertaCaptacao public oferta;
    EmissaoGateway public gateway;
    RegistroInvestidorQualificado public registro;
    ReentrantMockBRL public moeda;
    ParticipacaoToken public token;

    address public admin = makeAddr("admin");
    address public agent = makeAddr("agente");
    address public emissorWallet = makeAddr("emissorWallet");
    address public protocoloWallet = makeAddr("protocoloWallet");
    address public investor1 = makeAddr("investidor1");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    uint256 public constant MIN_TARGET = 10_000 ether;
    uint256 public constant MAX_TARGET = 50_000 ether;
    uint256 public constant PRICE_PER_SHARE = 100 ether;
    uint256 public constant PER_INVESTOR_CAP = 20_000 ether;
    uint256 public constant FEE_BPS = 50;
    uint256 public constant INITIAL_BALANCE = 1_000_000 ether;
    uint256 public prazo;

    function setUp() public {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        moeda = new ReentrantMockBRL();

        bytes32 agentRole = gateway.AGENTE_ROLE();
        vm.prank(admin);
        gateway.proposeGrantRole(agentRole, agent);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        gateway.executeGrantRole(agentRole, agent);

        DenyAllTransferPolicy policy = new DenyAllTransferPolicy();
        ParticipacaoToken tokenImpl = new ParticipacaoToken();
        token = ParticipacaoToken(Clones.clone(address(tokenImpl)));
        token.initialize("Oferta X", "nX", address(gateway), address(policy), "Empresa X", bytes32(0), "2026-A");

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
                taxaBps: FEE_BPS
            })
        );

        vm.prank(agent);
        gateway.registrarCaptacao(address(token), address(oferta));

        moeda.mint(investor1, INITIAL_BALANCE);
        vm.prank(investor1);
        moeda.approve(address(oferta), type(uint256).max);
    }

    // ── aportar: reentrada via transferFrom (entrada de fundos) ──────────────────────────

    function test_Aportar_BlockedByReentrancyGuard() public {
        moeda.armAttack(address(oferta), abi.encodeWithSelector(OfertaCaptacao.aportar.selector, PRICE_PER_SHARE));

        vm.prank(investor1);
        oferta.aportar(1_000 ether);

        assertTrue(moeda.reentryBlocked());
        assertEq(oferta.totalArrecadado(), 1_000 ether);
        assertEq(oferta.aportadoPor(investor1), 1_000 ether);
    }

    // ── reembolsar: re-entry via transfer (funds outflow, failure) ───────────────────────

    function test_Reembolsar_BlockedByReentrancyGuard() public {
        vm.prank(investor1);
        oferta.aportar(1_000 ether);
        vm.warp(prazo);
        oferta.encerrar();
        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.EncerradaFalha));

        moeda.armAttack(address(oferta), abi.encodeWithSelector(OfertaCaptacao.reembolsar.selector));

        vm.prank(investor1);
        oferta.reembolsar();

        assertTrue(moeda.reentryBlocked());
        assertTrue(oferta.reembolsado(investor1));
        assertEq(moeda.balanceOf(investor1), INITIAL_BALANCE); // refunded exactly once
    }

    // ── liberarParaEmissor: re-entry via transfer (funds outflow, success) ───────────────

    function test_LiberarParaEmissor_BlockedByReentrancyGuard() public {
        vm.prank(investor1);
        oferta.aportar(MIN_TARGET);
        vm.warp(prazo);
        oferta.encerrar();
        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.EncerradaSucesso));

        moeda.armAttack(address(oferta), abi.encodeWithSelector(OfertaCaptacao.liberarParaEmissor.selector));

        oferta.liberarParaEmissor();

        assertTrue(moeda.reentryBlocked());
        assertTrue(oferta.recursosLiberados());

        uint256 expectedFee = (MIN_TARGET * FEE_BPS) / 10_000;
        assertEq(moeda.balanceOf(protocoloWallet), expectedFee);
        assertEq(moeda.balanceOf(emissorWallet), MIN_TARGET - expectedFee);
        assertEq(moeda.balanceOf(address(oferta)), 0);
    }
}
