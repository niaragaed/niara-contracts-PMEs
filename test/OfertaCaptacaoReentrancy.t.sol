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

/// @notice Prova dedicada de que `nonReentrant` (+ CEI) barra reentrada nas três funções de
/// `OfertaCaptacao` que movem moeda: `aportar` (transferFrom de entrada), `reembolsar` e
/// `liberarParaEmissor` (transfer de saída). Usa `ReentrantMockBRL`, uma moeda maliciosa que
/// tenta reentrar o alvo configurado a cada `transfer`/`transferFrom` — simula uma stablecoin
/// de BRL real com hook, já que `MockBRL` (benigna) não exercitaria essa proteção.
contract OfertaCaptacaoReentrancyTest is Test {
    OfertaCaptacao public oferta;
    EmissaoGateway public gateway;
    RegistroInvestidorQualificado public registro;
    ReentrantMockBRL public moeda;
    ParticipacaoToken public token;

    address public admin = makeAddr("admin");
    address public agente = makeAddr("agente");
    address public emissorWallet = makeAddr("emissorWallet");
    address public protocoloWallet = makeAddr("protocoloWallet");
    address public investidor1 = makeAddr("investidor1");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    uint256 public constant META_MINIMA = 10_000 ether;
    uint256 public constant META_MAXIMA = 50_000 ether;
    uint256 public constant PRECO_POR_COTA = 100 ether;
    uint256 public constant TETO_POR_INVESTIDOR = 20_000 ether;
    uint256 public constant TAXA_BPS = 50;
    uint256 public constant SALDO_INICIAL = 1_000_000 ether;
    uint256 public prazo;

    function setUp() public {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        moeda = new ReentrantMockBRL();

        bytes32 agenteRole = gateway.AGENTE_ROLE();
        vm.prank(admin);
        gateway.proposeGrantRole(agenteRole, agente);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        gateway.executeGrantRole(agenteRole, agente);

        DenyAllTransferPolicy policy = new DenyAllTransferPolicy();
        ParticipacaoToken tokenImpl = new ParticipacaoToken();
        token = ParticipacaoToken(Clones.clone(address(tokenImpl)));
        token.initialize("Oferta X", "nX", address(gateway), address(policy), "Empresa X", bytes32(0), "2026-A");

        vm.prank(agente);
        gateway.atestarCotas(address(token), (META_MAXIMA / PRECO_POR_COTA) * 1 ether);

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
                metaMinima: META_MINIMA,
                metaMaxima: META_MAXIMA,
                precoPorCota: PRECO_POR_COTA,
                prazo: prazo,
                tetoPorInvestidor: TETO_POR_INVESTIDOR,
                taxaBps: TAXA_BPS
            })
        );

        vm.prank(agente);
        gateway.registrarCaptacao(address(token), address(oferta));

        moeda.mint(investidor1, SALDO_INICIAL);
        vm.prank(investidor1);
        moeda.approve(address(oferta), type(uint256).max);
    }

    // ── aportar: reentrada via transferFrom (entrada de fundos) ──────────────────────────

    function test_Aportar_BlockedByReentrancyGuard() public {
        moeda.configurarAtaque(
            address(oferta), abi.encodeWithSelector(OfertaCaptacao.aportar.selector, PRECO_POR_COTA)
        );

        vm.prank(investidor1);
        oferta.aportar(1_000 ether);

        assertTrue(moeda.reentradaBloqueada());
        assertEq(oferta.totalArrecadado(), 1_000 ether);
        assertEq(oferta.aportadoPor(investidor1), 1_000 ether);
    }

    // ── reembolsar: reentrada via transfer (saída de fundos, fracasso) ───────────────────

    function test_Reembolsar_BlockedByReentrancyGuard() public {
        vm.prank(investidor1);
        oferta.aportar(1_000 ether);
        vm.warp(prazo);
        oferta.encerrar();
        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.EncerradaFalha));

        moeda.configurarAtaque(address(oferta), abi.encodeWithSelector(OfertaCaptacao.reembolsar.selector));

        vm.prank(investidor1);
        oferta.reembolsar();

        assertTrue(moeda.reentradaBloqueada());
        assertTrue(oferta.reembolsado(investidor1));
        assertEq(moeda.balanceOf(investidor1), SALDO_INICIAL); // reembolsado exatamente uma vez
    }

    // ── liberarParaEmissor: reentrada via transfer (saída de fundos, sucesso) ────────────

    function test_LiberarParaEmissor_BlockedByReentrancyGuard() public {
        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);
        vm.warp(prazo);
        oferta.encerrar();
        assertEq(uint256(oferta.estado()), uint256(OfertaCaptacao.Estado.EncerradaSucesso));

        moeda.configurarAtaque(address(oferta), abi.encodeWithSelector(OfertaCaptacao.liberarParaEmissor.selector));

        oferta.liberarParaEmissor();

        assertTrue(moeda.reentradaBloqueada());
        assertTrue(oferta.recursosLiberados());

        uint256 taxaEsperada = (META_MINIMA * TAXA_BPS) / 10_000;
        assertEq(moeda.balanceOf(protocoloWallet), taxaEsperada);
        assertEq(moeda.balanceOf(emissorWallet), META_MINIMA - taxaEsperada);
        assertEq(moeda.balanceOf(address(oferta)), 0);
    }
}
