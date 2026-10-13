// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {OfertaCaptacaoFactory} from "../../src/captacao/OfertaCaptacaoFactory.sol";
import {OfertaCaptacao} from "../../src/captacao/OfertaCaptacao.sol";
import {EmissaoGateway} from "../../src/emissao/EmissaoGateway.sol";
import {RegistroInvestidorQualificado} from "../../src/registro/RegistroInvestidorQualificado.sol";
import {ParticipacaoToken} from "../../src/token/ParticipacaoToken.sol";
import {DenyAllTransferPolicy} from "../../src/policies/DenyAllTransferPolicy.sol";
import {MockBRL} from "../../src/mocks/MockBRL.sol";

/// @notice Stateful fuzzing actor for the fundraising domain (Phase 2): exposes one action per
/// public function (create fundraising, invest, advance time, close, set qualification, cancel,
/// redeem shares, release to the issuer, refund) plus deliberate attempts to bypass guards
/// (`tentar*`), same design as Phase 1's `test/invariant/Handler.sol` (see Lineage in
/// CLAUDE.md): most calls use parameters bounded to valid states; the `tentar*` ones take the
/// invalid path on purpose, without try/catch, and only flip a "ghost" to `true` when a call
/// that SHOULD revert ends without reverting.
contract HandlerCaptacao is Test {
    OfertaCaptacaoFactory public factory;
    EmissaoGateway public gateway;
    RegistroInvestidorQualificado public registro;
    MockBRL public moeda;
    ParticipacaoToken public tokenImplementation;
    DenyAllTransferPolicy public policy;

    address public admin;
    address public agent;
    address public emissorWallet;
    address public protocoloWallet;
    address[] public actors;

    address[] public fundraisingList;

    /// @notice Sum of refunds already paid, per fundraising, used to check escrow accounting
    /// (`moeda.balanceOf(oferta) == totalArrecadado - sumReembolsado`, when not released).
    mapping(address => uint256) public ghost_sumRefunded;

    /// @notice Sum of shares already minted via redemption, per fundraising; it cannot exceed
    /// `totalArrecadado / precoPorCota`.
    mapping(address => uint256) public ghost_sumSharesMinted;

    /// @notice `true` if any refund has already happened in that fundraising.
    mapping(address => bool) public ghost_hadRefund;

    /// @notice `true` if any share redemption or release to the issuer has already happened in
    /// that fundraising; mutually exclusive with `ghost_hadRefund` (success XOR failure).
    mapping(address => bool) public ghost_hadMintOrRelease;

    /// @notice Becomes `true` if `cancelar`/`definirQualificado`/`criarCaptacao` succeed when
    /// called by someone without `AGENTE_ROLE`.
    bool public ghost_unauthorizedActionSucceeded;

    /// @notice Becomes `true` if a second `resgatarCotas` by the same investor succeeds.
    bool public ghost_doubleRedeemSucceeded;

    /// @notice Becomes `true` if a second `reembolsar` by the same investor succeeds.
    bool public ghost_doubleRefundSucceeded;

    /// @notice Becomes `true` if a second `liberarParaEmissor` succeeds.
    bool public ghost_doubleReleaseSucceeded;

    /// @notice Becomes `true` if `aportar` succeeds outside the `Aberta` state or after the deadline.
    bool public ghost_investOutOfStateSucceeded;

    /// @notice Becomes `true` if `encerrar` succeeds before the deadline and before the maximum target.
    bool public ghost_prematureCloseSucceeded;

    /// @notice Becomes `true` if a NON-qualified investor manages, in a single `aportar` call, to
    /// exceed `tetoPorInvestidor`. Tested at call time (not as a retroactive snapshot) because
    /// qualification is a mutable flag: an investor can legitimately be above the current cap if
    /// they were qualified at the time of investing and disqualified later. That is not a bug;
    /// it is the absence of retroactive confiscation.
    bool public ghost_capBypassSucceeded;

    struct Config {
        OfertaCaptacaoFactory factory;
        EmissaoGateway gateway;
        RegistroInvestidorQualificado registry;
        MockBRL currency;
        ParticipacaoToken tokenImplementation;
        DenyAllTransferPolicy policy;
        address admin;
        address agent;
        address issuerWallet;
        address protocolWallet;
        address[] actors;
    }

    constructor(Config memory config) {
        factory = config.factory;
        gateway = config.gateway;
        registro = config.registry;
        moeda = config.currency;
        tokenImplementation = config.tokenImplementation;
        policy = config.policy;
        admin = config.admin;
        agent = config.agent;
        emissorWallet = config.issuerWallet;
        protocoloWallet = config.protocolWallet;
        actors = config.actors;
    }

    // ── Selection helpers ──────────────────────────────────────────────────────────────

    function _actorAt(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _pickFundraising(uint256 seed) internal view returns (OfertaCaptacao) {
        return OfertaCaptacao(fundraisingList[seed % fundraisingList.length]);
    }

    function _chaos(uint256 seed) internal pure returns (bool) {
        return seed % 5 == 0;
    }

    function _ensureFunds(address investidor, address oferta, uint256 valor) internal {
        if (moeda.balanceOf(investidor) < valor) {
            moeda.mint(investidor, valor + 1_000_000 ether);
        }
        if (moeda.allowance(investidor, oferta) < valor) {
            vm.prank(investidor);
            moeda.approve(oferta, type(uint256).max);
        }
    }

    // ── Fundraising creation ────────────────────────────────────────────────────────────

    function createFundraisingAndToken(
        uint256 maxTargetSeed,
        uint256 minTargetSeed,
        uint256 priceSeed,
        uint256 deadlineSeed,
        uint256 capSeed,
        uint256 feeSeed,
        uint256 chaosSeed
    ) external {
        uint256[3] memory prices = [uint256(1 ether), uint256(10 ether), uint256(100 ether)];
        uint256 precoPorCota = prices[priceSeed % 3];

        uint256 metaMaxima = bound(maxTargetSeed, precoPorCota * 10, precoPorCota * 10_000);
        uint256 metaMinima = bound(minTargetSeed, precoPorCota, metaMaxima);
        uint256 prazo = block.timestamp + bound(deadlineSeed, 1 days, 60 days);
        uint256 tetoPorInvestidor = bound(capSeed, precoPorCota, metaMaxima);
        uint256 taxaBps = bound(feeSeed, 0, 100);

        address token = Clones.clone(address(tokenImplementation));
        ParticipacaoToken(token).initialize(
            "Oferta Captacao", "nCAP", address(gateway), address(policy), "Empresa Captacao", bytes32(0), "2026-A"
        );

        vm.prank(agent);
        gateway.atestarCotas(token, (metaMaxima / precoPorCota) * 1 ether);

        address caller = _chaos(chaosSeed) ? _actorAt(chaosSeed) : agent;

        vm.prank(caller);
        address oferta = factory.criarCaptacao(
            token, metaMinima, metaMaxima, precoPorCota, prazo, tetoPorInvestidor, taxaBps, emissorWallet, protocoloWallet
        );

        if (caller != agent) {
            ghost_unauthorizedActionSucceeded = true;
            return;
        }

        fundraisingList.push(oferta);

        vm.prank(agent);
        gateway.registrarCaptacao(token, oferta);
    }

    // ── Investment ──────────────────────────────────────────────────────────────────────

    function aportar(uint256 capSeed, uint256 investorSeed, uint256 shareCountSeed) external {
        if (fundraisingList.length == 0) return;
        OfertaCaptacao oferta = _pickFundraising(capSeed);
        address investidor = _actorAt(investorSeed);

        uint256 precoPorCota = oferta.precoPorCota();
        uint256 shareCount = bound(shareCountSeed, 1, 20);
        uint256 valor = shareCount * precoPorCota;

        _ensureFunds(investidor, address(oferta), valor);

        vm.prank(investidor);
        try oferta.aportar(valor) {} catch {}
    }

    // ── Tempo ───────────────────────────────────────────────────────────────────────────

    function advanceTime(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 10 days));
    }

    // ── Encerramento ────────────────────────────────────────────────────────────────────

    function encerrar(uint256 capSeed) external {
        if (fundraisingList.length == 0) return;
        OfertaCaptacao oferta = _pickFundraising(capSeed);
        try oferta.encerrar() {} catch {}
    }

    function tryClosePrematurely(uint256 capSeed) external {
        if (fundraisingList.length == 0) return;
        OfertaCaptacao oferta = _pickFundraising(capSeed);
        if (oferta.estado() != OfertaCaptacao.Estado.Aberta) return;
        if (block.timestamp >= oferta.prazo()) return;
        if (oferta.totalArrecadado() == oferta.metaMaxima()) return;

        oferta.encerrar();
        ghost_prematureCloseSucceeded = true;
    }

    // ── Qualification ───────────────────────────────────────────────────────────────────

    function definirQualificado(uint256 investorSeed, uint256 qualifiedSeed, uint256 chaosSeed) external {
        address investidor = _actorAt(investorSeed);
        bool qualificado = qualifiedSeed % 2 == 0;
        address caller = _chaos(chaosSeed) ? investidor : agent;

        vm.prank(caller);
        registro.definirQualificado(investidor, qualificado);

        if (caller != agent) ghost_unauthorizedActionSucceeded = true;
    }

    // ── Cancelamento ────────────────────────────────────────────────────────────────────

    function cancelar(uint256 capSeed, uint256 chaosSeed) external {
        if (fundraisingList.length == 0) return;
        OfertaCaptacao oferta = _pickFundraising(capSeed);
        address caller = _chaos(chaosSeed) ? _actorAt(chaosSeed) : agent;

        vm.prank(caller);
        try oferta.cancelar() {
            if (caller != agent) ghost_unauthorizedActionSucceeded = true;
        } catch {}
    }

    // ── Reembolso ───────────────────────────────────────────────────────────────────────

    function reembolsar(uint256 capSeed, uint256 investorSeed) external {
        if (fundraisingList.length == 0) return;
        OfertaCaptacao oferta = _pickFundraising(capSeed);
        address investidor = _actorAt(investorSeed);
        uint256 aportado = oferta.aportadoPor(investidor);

        vm.prank(investidor);
        try oferta.reembolsar() {
            ghost_sumRefunded[address(oferta)] += aportado;
            ghost_hadRefund[address(oferta)] = true;
        } catch {}
    }

    function tryRefundTwice(uint256 capSeed, uint256 investorSeed) external {
        if (fundraisingList.length == 0) return;
        OfertaCaptacao oferta = _pickFundraising(capSeed);
        address investidor = _actorAt(investorSeed);
        if (oferta.estado() != OfertaCaptacao.Estado.EncerradaFalha) return;
        if (!oferta.reembolsado(investidor)) return;

        vm.prank(investidor);
        oferta.reembolsar();
        ghost_doubleRefundSucceeded = true;
    }

    // ── Share redemption ────────────────────────────────────────────────────────────────

    function resgatarCotas(uint256 capSeed, uint256 investorSeed) external {
        if (fundraisingList.length == 0) return;
        OfertaCaptacao oferta = _pickFundraising(capSeed);
        address investidor = _actorAt(investorSeed);
        uint256 aportado = oferta.aportadoPor(investidor);
        uint256 precoPorCota = oferta.precoPorCota();

        vm.prank(investidor);
        try oferta.resgatarCotas() {
            ghost_sumSharesMinted[address(oferta)] += aportado / precoPorCota;
            ghost_hadMintOrRelease[address(oferta)] = true;
        } catch {}
    }

    function tryRedeemTwice(uint256 capSeed, uint256 investorSeed) external {
        if (fundraisingList.length == 0) return;
        OfertaCaptacao oferta = _pickFundraising(capSeed);
        address investidor = _actorAt(investorSeed);
        if (oferta.estado() != OfertaCaptacao.Estado.EncerradaSucesso) return;
        if (!oferta.cotasResgatadas(investidor)) return;

        vm.prank(investidor);
        oferta.resgatarCotas();
        ghost_doubleRedeemSucceeded = true;
    }

    // ── Release to the issuer ───────────────────────────────────────────────────────────

    function liberarParaEmissor(uint256 capSeed) external {
        if (fundraisingList.length == 0) return;
        OfertaCaptacao oferta = _pickFundraising(capSeed);

        try oferta.liberarParaEmissor() {
            ghost_hadMintOrRelease[address(oferta)] = true;
        } catch {}
    }

    function tryReleaseTwice(uint256 capSeed) external {
        if (fundraisingList.length == 0) return;
        OfertaCaptacao oferta = _pickFundraising(capSeed);
        if (!oferta.recursosLiberados()) return;

        oferta.liberarParaEmissor();
        ghost_doubleReleaseSucceeded = true;
    }

    // ── Attempt to invest outside the valid state ──────────────────────────────────────

    function tryInvestOutOfState(uint256 capSeed, uint256 investorSeed) external {
        if (fundraisingList.length == 0) return;
        OfertaCaptacao oferta = _pickFundraising(capSeed);
        address investidor = _actorAt(investorSeed);

        bool open_ = oferta.estado() == OfertaCaptacao.Estado.Aberta;
        bool withinDeadline = block.timestamp < oferta.prazo();
        if (open_ && withinDeadline) return; // nothing invalid to test right now

        uint256 valor = oferta.precoPorCota();
        _ensureFunds(investidor, address(oferta), valor);

        vm.prank(investidor);
        oferta.aportar(valor);
        ghost_investOutOfStateSucceeded = true;
    }

    function tryExceedCapWithoutQualification(uint256 capSeed, uint256 investorSeed) external {
        if (fundraisingList.length == 0) return;
        OfertaCaptacao oferta = _pickFundraising(capSeed);
        address investidor = _actorAt(investorSeed);
        if (registro.ehQualificado(investidor)) return;
        if (oferta.estado() != OfertaCaptacao.Estado.Aberta) return;
        if (block.timestamp >= oferta.prazo()) return;

        uint256 teto = oferta.tetoPorInvestidor();
        uint256 alreadyInvested = oferta.aportadoPor(investidor);
        if (alreadyInvested > teto) return; // already above the cap due to later disqualification; not testable here

        uint256 precoPorCota = oferta.precoPorCota();
        uint256 valor = ((teto - alreadyInvested) / precoPorCota + 1) * precoPorCota; // exceeds the cap by >= 1 share
        if (oferta.totalArrecadado() + valor > oferta.metaMaxima()) return; // not to be confused with the other guard

        _ensureFunds(investidor, address(oferta), valor);

        vm.prank(investidor);
        oferta.aportar(valor);
        ghost_capBypassSucceeded = true;
    }

    // ── Views for InvariantCaptacaoTest ────────────────────────────────────────────────

    function numCaptacoes() external view returns (uint256) {
        return fundraisingList.length;
    }

    function numActors() external view returns (uint256) {
        return actors.length;
    }

    function captacoes(uint256 i) external view returns (address) {
        return fundraisingList[i];
    }
}
