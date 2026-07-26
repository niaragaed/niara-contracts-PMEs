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

/// @notice Ator de fuzzing stateful do domínio de captação (Fase 2): expõe uma ação por função
/// pública (criar captação, aportar, avançar tempo, encerrar, definir qualificação, cancelar,
/// resgatar cotas, liberar para o emissor, reembolsar) mais tentativas deliberadas de burlar
/// guardas (`tentar*`), mesmo desenho de `test/invariant/Handler.sol` da Fase 1 (ver Linhagem
/// no CLAUDE.md): a maioria das chamadas usa parâmetros limitados a estados válidos; as
/// `tentar*` tomam de propósito o caminho inválido, sem try/catch — só viram "ghost" `true`
/// quando uma chamada que DEVERIA reverter termina sem reverter.
contract HandlerCaptacao is Test {
    OfertaCaptacaoFactory public factory;
    EmissaoGateway public gateway;
    RegistroInvestidorQualificado public registro;
    MockBRL public moeda;
    ParticipacaoToken public tokenImplementacao;
    DenyAllTransferPolicy public policy;

    address public admin;
    address public agente;
    address public emissorWallet;
    address public protocoloWallet;
    address[] public actors;

    address[] public captacoesList;

    /// @notice Soma dos reembolsos já pagos, por captação — usada para checar a contabilidade
    /// do escrow (`moeda.balanceOf(oferta) == totalArrecadado - sumReembolsado`, quando não
    /// liberado).
    mapping(address => uint256) public ghost_sumReembolsado;

    /// @notice Soma das cotas já mintadas via resgate, por captação — não pode exceder
    /// `totalArrecadado / precoPorCota`.
    mapping(address => uint256) public ghost_sumCotasMintadas;

    /// @notice `true` se algum reembolso já ocorreu naquela captação.
    mapping(address => bool) public ghost_houveReembolso;

    /// @notice `true` se algum resgate de cotas ou liberação ao emissor já ocorreu naquela
    /// captação — mutuamente exclusivo com `ghost_houveReembolso` (sucesso XOR fracasso).
    mapping(address => bool) public ghost_houveMintOuLiberacao;

    /// @notice Vira `true` se `cancelar`/`definirQualificado`/`criarCaptacao` forem
    /// bem-sucedidos chamados por alguém sem `AGENTE_ROLE`.
    bool public ghost_unauthorizedActionSucceeded;

    /// @notice Vira `true` se um segundo `resgatarCotas` do mesmo investidor for bem-sucedido.
    bool public ghost_doubleResgateSucceeded;

    /// @notice Vira `true` se um segundo `reembolsar` do mesmo investidor for bem-sucedido.
    bool public ghost_doubleReembolsoSucceeded;

    /// @notice Vira `true` se um segundo `liberarParaEmissor` for bem-sucedido.
    bool public ghost_doubleLiberacaoSucceeded;

    /// @notice Vira `true` se `aportar` suceder fora do estado `Aberta` ou após o prazo.
    bool public ghost_aportarForaDoEstadoSucceeded;

    /// @notice Vira `true` se `encerrar` suceder antes do prazo e antes da meta máxima.
    bool public ghost_encerramentoPrematuroSucceeded;

    /// @notice Vira `true` se um investidor NÃO qualificado conseguir, numa única chamada de
    /// `aportar`, ultrapassar `tetoPorInvestidor`. Testado no momento da chamada (não como
    /// snapshot retroativo) porque qualificação é uma flag mutável: um investidor pode
    /// legitimamente ficar acima do teto vigente se foi qualificado no momento do aporte e
    /// desqualificado depois — isso não é um bug, é ausência de confisco retroativo.
    bool public ghost_tetoBypassSucceeded;

    struct Config {
        OfertaCaptacaoFactory factory;
        EmissaoGateway gateway;
        RegistroInvestidorQualificado registro;
        MockBRL moeda;
        ParticipacaoToken tokenImplementacao;
        DenyAllTransferPolicy policy;
        address admin;
        address agente;
        address emissorWallet;
        address protocoloWallet;
        address[] actors;
    }

    constructor(Config memory config) {
        factory = config.factory;
        gateway = config.gateway;
        registro = config.registro;
        moeda = config.moeda;
        tokenImplementacao = config.tokenImplementacao;
        policy = config.policy;
        admin = config.admin;
        agente = config.agente;
        emissorWallet = config.emissorWallet;
        protocoloWallet = config.protocoloWallet;
        actors = config.actors;
    }

    // ── Helpers de seleção ─────────────────────────────────────────────────────────────

    function _actorAt(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _pickCaptacao(uint256 seed) internal view returns (OfertaCaptacao) {
        return OfertaCaptacao(captacoesList[seed % captacoesList.length]);
    }

    function _chaos(uint256 seed) internal pure returns (bool) {
        return seed % 5 == 0;
    }

    function _garantirFundos(address investidor, address oferta, uint256 valor) internal {
        if (moeda.balanceOf(investidor) < valor) {
            moeda.mint(investidor, valor + 1_000_000 ether);
        }
        if (moeda.allowance(investidor, oferta) < valor) {
            vm.prank(investidor);
            moeda.approve(oferta, type(uint256).max);
        }
    }

    // ── Criação de captações ────────────────────────────────────────────────────────────

    function criarCaptacaoEToken(
        uint256 metaMaximaSeed,
        uint256 metaMinimaSeed,
        uint256 precoSeed,
        uint256 prazoSeed,
        uint256 tetoSeed,
        uint256 taxaSeed,
        uint256 chaosSeed
    ) external {
        uint256[3] memory precos = [uint256(1 ether), uint256(10 ether), uint256(100 ether)];
        uint256 precoPorCota = precos[precoSeed % 3];

        uint256 metaMaxima = bound(metaMaximaSeed, precoPorCota * 10, precoPorCota * 10_000);
        uint256 metaMinima = bound(metaMinimaSeed, precoPorCota, metaMaxima);
        uint256 prazo = block.timestamp + bound(prazoSeed, 1 days, 60 days);
        uint256 tetoPorInvestidor = bound(tetoSeed, precoPorCota, metaMaxima);
        uint256 taxaBps = bound(taxaSeed, 0, 100);

        address token = Clones.clone(address(tokenImplementacao));
        ParticipacaoToken(token).initialize(
            "Oferta Captacao", "nCAP", address(gateway), address(policy), "Empresa Captacao", bytes32(0), "2026-A"
        );

        vm.prank(agente);
        gateway.atestarCotas(token, (metaMaxima / precoPorCota) * 1 ether);

        address caller = _chaos(chaosSeed) ? _actorAt(chaosSeed) : agente;

        vm.prank(caller);
        address oferta = factory.criarCaptacao(
            token, metaMinima, metaMaxima, precoPorCota, prazo, tetoPorInvestidor, taxaBps, emissorWallet, protocoloWallet
        );

        if (caller != agente) {
            ghost_unauthorizedActionSucceeded = true;
            return;
        }

        captacoesList.push(oferta);

        vm.prank(agente);
        gateway.registrarCaptacao(token, oferta);
    }

    // ── Aporte ──────────────────────────────────────────────────────────────────────────

    function aportar(uint256 capSeed, uint256 investorSeed, uint256 qtdCotasSeed) external {
        if (captacoesList.length == 0) return;
        OfertaCaptacao oferta = _pickCaptacao(capSeed);
        address investidor = _actorAt(investorSeed);

        uint256 precoPorCota = oferta.precoPorCota();
        uint256 qtdCotas = bound(qtdCotasSeed, 1, 20);
        uint256 valor = qtdCotas * precoPorCota;

        _garantirFundos(investidor, address(oferta), valor);

        vm.prank(investidor);
        try oferta.aportar(valor) {} catch {}
    }

    // ── Tempo ───────────────────────────────────────────────────────────────────────────

    function avancarTempo(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 10 days));
    }

    // ── Encerramento ────────────────────────────────────────────────────────────────────

    function encerrar(uint256 capSeed) external {
        if (captacoesList.length == 0) return;
        OfertaCaptacao oferta = _pickCaptacao(capSeed);
        try oferta.encerrar() {} catch {}
    }

    function tentarEncerrarPrematuramente(uint256 capSeed) external {
        if (captacoesList.length == 0) return;
        OfertaCaptacao oferta = _pickCaptacao(capSeed);
        if (oferta.estado() != OfertaCaptacao.Estado.Aberta) return;
        if (block.timestamp >= oferta.prazo()) return;
        if (oferta.totalArrecadado() == oferta.metaMaxima()) return;

        oferta.encerrar();
        ghost_encerramentoPrematuroSucceeded = true;
    }

    // ── Qualificação ────────────────────────────────────────────────────────────────────

    function definirQualificado(uint256 investorSeed, uint256 qualificadoSeed, uint256 chaosSeed) external {
        address investidor = _actorAt(investorSeed);
        bool qualificado = qualificadoSeed % 2 == 0;
        address caller = _chaos(chaosSeed) ? investidor : agente;

        vm.prank(caller);
        registro.definirQualificado(investidor, qualificado);

        if (caller != agente) ghost_unauthorizedActionSucceeded = true;
    }

    // ── Cancelamento ────────────────────────────────────────────────────────────────────

    function cancelar(uint256 capSeed, uint256 chaosSeed) external {
        if (captacoesList.length == 0) return;
        OfertaCaptacao oferta = _pickCaptacao(capSeed);
        address caller = _chaos(chaosSeed) ? _actorAt(chaosSeed) : agente;

        vm.prank(caller);
        try oferta.cancelar() {
            if (caller != agente) ghost_unauthorizedActionSucceeded = true;
        } catch {}
    }

    // ── Reembolso ───────────────────────────────────────────────────────────────────────

    function reembolsar(uint256 capSeed, uint256 investorSeed) external {
        if (captacoesList.length == 0) return;
        OfertaCaptacao oferta = _pickCaptacao(capSeed);
        address investidor = _actorAt(investorSeed);
        uint256 aportado = oferta.aportadoPor(investidor);

        vm.prank(investidor);
        try oferta.reembolsar() {
            ghost_sumReembolsado[address(oferta)] += aportado;
            ghost_houveReembolso[address(oferta)] = true;
        } catch {}
    }

    function tentarReembolsarDuasVezes(uint256 capSeed, uint256 investorSeed) external {
        if (captacoesList.length == 0) return;
        OfertaCaptacao oferta = _pickCaptacao(capSeed);
        address investidor = _actorAt(investorSeed);
        if (oferta.estado() != OfertaCaptacao.Estado.EncerradaFalha) return;
        if (!oferta.reembolsado(investidor)) return;

        vm.prank(investidor);
        oferta.reembolsar();
        ghost_doubleReembolsoSucceeded = true;
    }

    // ── Resgate de cotas ────────────────────────────────────────────────────────────────

    function resgatarCotas(uint256 capSeed, uint256 investorSeed) external {
        if (captacoesList.length == 0) return;
        OfertaCaptacao oferta = _pickCaptacao(capSeed);
        address investidor = _actorAt(investorSeed);
        uint256 aportado = oferta.aportadoPor(investidor);
        uint256 precoPorCota = oferta.precoPorCota();

        vm.prank(investidor);
        try oferta.resgatarCotas() {
            ghost_sumCotasMintadas[address(oferta)] += aportado / precoPorCota;
            ghost_houveMintOuLiberacao[address(oferta)] = true;
        } catch {}
    }

    function tentarResgatarDuasVezes(uint256 capSeed, uint256 investorSeed) external {
        if (captacoesList.length == 0) return;
        OfertaCaptacao oferta = _pickCaptacao(capSeed);
        address investidor = _actorAt(investorSeed);
        if (oferta.estado() != OfertaCaptacao.Estado.EncerradaSucesso) return;
        if (!oferta.cotasResgatadas(investidor)) return;

        vm.prank(investidor);
        oferta.resgatarCotas();
        ghost_doubleResgateSucceeded = true;
    }

    // ── Liberação para o emissor ────────────────────────────────────────────────────────

    function liberarParaEmissor(uint256 capSeed) external {
        if (captacoesList.length == 0) return;
        OfertaCaptacao oferta = _pickCaptacao(capSeed);

        try oferta.liberarParaEmissor() {
            ghost_houveMintOuLiberacao[address(oferta)] = true;
        } catch {}
    }

    function tentarLiberarDuasVezes(uint256 capSeed) external {
        if (captacoesList.length == 0) return;
        OfertaCaptacao oferta = _pickCaptacao(capSeed);
        if (!oferta.recursosLiberados()) return;

        oferta.liberarParaEmissor();
        ghost_doubleLiberacaoSucceeded = true;
    }

    // ── Tentativa de aportar fora do estado válido ─────────────────────────────────────

    function tentarAportarForaDoEstado(uint256 capSeed, uint256 investorSeed) external {
        if (captacoesList.length == 0) return;
        OfertaCaptacao oferta = _pickCaptacao(capSeed);
        address investidor = _actorAt(investorSeed);

        bool aberta = oferta.estado() == OfertaCaptacao.Estado.Aberta;
        bool dentroDoPrazo = block.timestamp < oferta.prazo();
        if (aberta && dentroDoPrazo) return; // nada de inválido para testar agora

        uint256 valor = oferta.precoPorCota();
        _garantirFundos(investidor, address(oferta), valor);

        vm.prank(investidor);
        oferta.aportar(valor);
        ghost_aportarForaDoEstadoSucceeded = true;
    }

    function tentarExcederTetoSemQualificacao(uint256 capSeed, uint256 investorSeed) external {
        if (captacoesList.length == 0) return;
        OfertaCaptacao oferta = _pickCaptacao(capSeed);
        address investidor = _actorAt(investorSeed);
        if (registro.ehQualificado(investidor)) return;
        if (oferta.estado() != OfertaCaptacao.Estado.Aberta) return;
        if (block.timestamp >= oferta.prazo()) return;

        uint256 teto = oferta.tetoPorInvestidor();
        uint256 jaAportado = oferta.aportadoPor(investidor);
        if (jaAportado > teto) return; // já acima do teto por desqualificação posterior — não testável aqui

        uint256 precoPorCota = oferta.precoPorCota();
        uint256 valor = ((teto - jaAportado) / precoPorCota + 1) * precoPorCota; // excede o teto em >= 1 cota
        if (oferta.totalArrecadado() + valor > oferta.metaMaxima()) return; // não confundir com o outro guard

        _garantirFundos(investidor, address(oferta), valor);

        vm.prank(investidor);
        oferta.aportar(valor);
        ghost_tetoBypassSucceeded = true;
    }

    // ── Views para o InvariantCaptacaoTest ─────────────────────────────────────────────

    function numCaptacoes() external view returns (uint256) {
        return captacoesList.length;
    }

    function numActors() external view returns (uint256) {
        return actors.length;
    }

    function captacoes(uint256 i) external view returns (address) {
        return captacoesList[i];
    }
}
