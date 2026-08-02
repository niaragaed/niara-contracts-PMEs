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

/// @notice Prova, com a pilha completa (gateway + captação), que trocar a política de
/// `DenyAllTransferPolicy` para `RestrictedTransferPolicy` não quebra mint (`gateway.emitir`)
/// nem o fluxo de resgate de cotas da Fase 2 (`OfertaCaptacao.resgatarCotas`) — ambos passam
/// direto por `_update` com `from == address(0)`, nunca consultando `transferPolicy` (ver
/// `ParticipacaoToken._update`). Também exercita o ciclo completo de abertura do secundário:
/// transferência reverte antes, passa depois — o mesmo roteiro do `script/DemoFase3.s.sol`,
/// aqui como teste automatizado.
contract RestrictedTransferPolicyIntegrationTest is Test {
    EmissaoGateway public gateway;
    RegistroInvestidorQualificado public registro;
    MockBRL public moeda;
    ParticipacaoToken public token;
    RestrictedTransferPolicy public restricted;
    OfertaCaptacao public oferta;

    address public admin = makeAddr("admin");
    address public agente = makeAddr("agente");
    address public emissorWallet = makeAddr("emissorWallet");
    address public protocoloWallet = makeAddr("protocoloWallet");
    address public investidor1 = makeAddr("investidor1");
    address public investidor2 = makeAddr("investidor2");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    uint256 public constant META_MINIMA = 10_000 ether;
    uint256 public constant META_MAXIMA = 50_000 ether;
    uint256 public constant PRECO_POR_COTA = 100 ether;
    uint256 public constant TETO_POR_INVESTIDOR = 20_000 ether;
    uint256 public prazo;

    function setUp() public {
        gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        moeda = new MockBRL();
        restricted = new RestrictedTransferPolicy(admin, TIMELOCK_DELAY);

        _grantRole(address(gateway), gateway.AGENTE_ROLE(), agente);
        _grantRole(address(registro), registro.AGENTE_ROLE(), agente);
        _grantRole(address(restricted), restricted.AGENTE_ROLE(), agente);

        DenyAllTransferPolicy denyAll = new DenyAllTransferPolicy();
        ParticipacaoToken tokenImpl = new ParticipacaoToken();
        token = ParticipacaoToken(Clones.clone(address(tokenImpl)));
        token.initialize("Oferta X", "nX", address(gateway), address(denyAll), "Empresa X", bytes32(0), "2026-A");

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
                taxaBps: 0
            })
        );
        vm.prank(agente);
        gateway.registrarCaptacao(address(token), address(oferta));

        moeda.mint(investidor1, 1_000_000 ether);
        moeda.mint(investidor2, 1_000_000 ether);
        vm.prank(investidor1);
        moeda.approve(address(oferta), type(uint256).max);
        vm.prank(investidor2);
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

    function _apontarParaRestricted() internal {
        vm.prank(admin);
        gateway.proposeSetTransferPolicy(address(token), address(restricted));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        gateway.executeSetTransferPolicy(address(token), address(restricted));
    }

    // ── Mint continua funcionando com a Restricted anexada, independente do seu estado ────

    function test_Emitir_ContinuaFuncionandoComRestrictedAnexada() public {
        _apontarParaRestricted();
        // secundarioLiberado ainda é false (default) — mint não deveria se importar.

        vm.prank(agente);
        gateway.emitir(address(token), investidor1, 100 ether);

        assertEq(token.balanceOf(investidor1), 100 ether);
    }

    // ── resgatarCotas (Fase 2) continua funcionando com a Restricted anexada ──────────────

    function test_ResgatarCotas_ContinuaFuncionandoComRestrictedAnexada() public {
        _apontarParaRestricted();

        vm.prank(investidor1);
        oferta.aportar(META_MINIMA);

        vm.warp(prazo);
        oferta.encerrar();

        vm.prank(investidor1);
        oferta.resgatarCotas();

        assertEq(token.balanceOf(investidor1), (META_MINIMA / PRECO_POR_COTA) * 1 ether);
    }

    // ── Ciclo completo: reverte antes de abrir, passa depois ───────────────────────────────

    function test_CicloCompleto_AbrirSecundarioAposLockup() public {
        vm.prank(agente);
        gateway.emitir(address(token), investidor1, 100 ether);

        // Ainda em DenyAllTransferPolicy — reverte.
        vm.prank(investidor1);
        vm.expectRevert(ParticipacaoToken.TransferenciaNaoPermitida.selector);
        token.transfer(investidor2, 10 ether);

        _apontarParaRestricted();

        // Apontar cedo é seguro: secundarioLiberado ainda false, então continua revertendo.
        vm.prank(investidor1);
        vm.expectRevert(ParticipacaoToken.TransferenciaNaoPermitida.selector);
        token.transfer(investidor2, 10 ether);

        uint64 lockupAte = uint64(block.timestamp + 30 days);
        vm.prank(agente);
        restricted.definirLockup(address(token), lockupAte);
        vm.prank(agente);
        restricted.definirElegivel(address(token), investidor2, true);

        vm.prank(admin);
        restricted.proposeSetSecundarioLiberado(address(token), true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        restricted.executeSetSecundarioLiberado(address(token), true);

        // Liberado, mas ainda dentro do lock-up — reverte.
        vm.prank(investidor1);
        vm.expectRevert(ParticipacaoToken.TransferenciaNaoPermitida.selector);
        token.transfer(investidor2, 10 ether);

        vm.warp(lockupAte);

        // Contra-exemplo: destinatário não elegível — reverte.
        address naoElegivel = makeAddr("naoElegivel");
        vm.prank(investidor1);
        vm.expectRevert(ParticipacaoToken.TransferenciaNaoPermitida.selector);
        token.transfer(naoElegivel, 10 ether);

        // Liberado, após lock-up, destinatário elegível — passa.
        vm.prank(investidor1);
        token.transfer(investidor2, 10 ether);
        assertEq(token.balanceOf(investidor2), 10 ether);
        assertEq(token.balanceOf(investidor1), 90 ether);
    }
}
