// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OfertaOrquestrador} from "../../src/orquestracao/OfertaOrquestrador.sol";
import {ParticipacaoTokenFactory} from "../../src/token/ParticipacaoTokenFactory.sol";
import {OfertaCaptacaoFactory} from "../../src/captacao/OfertaCaptacaoFactory.sol";
import {OfertaCaptacao} from "../../src/captacao/OfertaCaptacao.sol";
import {MockBRL} from "../../src/mocks/MockBRL.sol";

/// @notice Ator de fuzzing stateful do domínio do `OfertaOrquestrador`: expõe uma ação por
/// função pública (autorizar/revogar emissor, pausar/despausar, criar oferta completa, fechar
/// a última oferta de um emissor por falha ou por sucesso) para que o motor de invariantes do
/// Foundry explore sequências aleatórias desses passos.
/// @dev Mesmo desenho de `test/invariant/Handler.sol`/`HandlerCaptacao.sol` (ver Linhagem no
/// CLAUDE.md): a maior parte das chamadas de criação usa parâmetros limitados (`bound`) a
/// combinações válidas dentro dos limites da Res. CVM 88; uma fração (`_chaos`, ~1 em 5) toma
/// deliberadamente um caminho inválido. Chamadas externas não são envolvidas em try/catch —
/// com `fail_on_revert = false` (ver foundry.toml), um revert genuíno é tolerado pelo runner e
/// desfaz atomicamente qualquer efeito colateral desta chamada, inclusive as variáveis "ghost"
/// abaixo.
contract HandlerOrquestrador is Test {
    OfertaOrquestrador public orq;
    ParticipacaoTokenFactory public tokenFactory;
    OfertaCaptacaoFactory public captacaoFactory;
    MockBRL public moeda;

    address public admin;
    address public agenteOrq;
    address public agenteGateway;
    address[] public actors;
    address public investidorFuzz;

    address[] public tokens;
    address[] public ofertas;

    mapping(address => bool) internal _emissorRastreadoSet;
    address[] public emissoresRastreados;

    /// @notice Timestamp de criação de cada oferta rastreada — usado para verificar o limite
    /// de 180 dias contra o `prazo` gravado (que é um timestamp absoluto).
    mapping(address => uint256) public ghost_criadoEm;

    /// @notice `true` se o emissor estava em `emissoresAutorizados` NO MOMENTO em que aquela
    /// oferta foi criada (lido antes da chamada, gravado só se a chamada teve sucesso) — prova
    /// que nenhuma oferta rastreada nasceu de um emissor não autorizado.
    mapping(address => bool) public ghost_autorizadoNaCriacao;

    /// @notice Vira `true` se `autorizarEmissor`/`revogarEmissor`/`pause`/`unpause` forem
    /// bem-sucedidos chamados por alguém sem `AGENTE_ROLE` do orquestrador.
    bool public ghost_unauthorizedAdminActionSucceeded;

    struct Config {
        OfertaOrquestrador orq;
        ParticipacaoTokenFactory tokenFactory;
        OfertaCaptacaoFactory captacaoFactory;
        MockBRL moeda;
        address admin;
        address agenteOrq;
        address agenteGateway;
        address[] actors;
        address investidorFuzz;
    }

    constructor(Config memory config) {
        orq = config.orq;
        tokenFactory = config.tokenFactory;
        captacaoFactory = config.captacaoFactory;
        moeda = config.moeda;
        admin = config.admin;
        agenteOrq = config.agenteOrq;
        agenteGateway = config.agenteGateway;
        actors = config.actors;
        investidorFuzz = config.investidorFuzz;
    }

    // ── Helpers de seleção ─────────────────────────────────────────────────────────────

    function _actorAt(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev ~1 em 5 chamadas toma o caminho "caótico" (inválido de propósito).
    function _chaos(uint256 seed) internal pure returns (bool) {
        return seed % 5 == 0;
    }

    function _trackEmissor(address emissor) internal {
        if (!_emissorRastreadoSet[emissor]) {
            _emissorRastreadoSet[emissor] = true;
            emissoresRastreados.push(emissor);
        }
    }

    // ── Allowlist ──────────────────────────────────────────────────────────────────────

    function autorizarEmissor(uint256 actorSeed, uint256 chaosSeed) external {
        address emissor = _actorAt(actorSeed);
        bool chaos = _chaos(chaosSeed);
        address caller = chaos ? emissor : agenteOrq;

        vm.prank(caller);
        orq.autorizarEmissor(emissor);

        _trackEmissor(emissor);
        if (caller != agenteOrq) ghost_unauthorizedAdminActionSucceeded = true;
    }

    function revogarEmissor(uint256 actorSeed, uint256 chaosSeed) external {
        address emissor = _actorAt(actorSeed);
        bool chaos = _chaos(chaosSeed);
        address caller = chaos ? emissor : agenteOrq;

        vm.prank(caller);
        orq.revogarEmissor(emissor);

        if (caller != agenteOrq) ghost_unauthorizedAdminActionSucceeded = true;
    }

    // ── Pausa ──────────────────────────────────────────────────────────────────────────

    function pausarOuDespausar(uint256 actorSeed, uint256 chaosSeed) external {
        bool estaPausado = orq.paused();
        bool chaos = _chaos(chaosSeed);
        address caller = chaos ? _actorAt(actorSeed) : agenteOrq;

        vm.prank(caller);
        if (estaPausado) {
            orq.unpause();
        } else {
            orq.pause();
        }

        if (caller != agenteOrq) ghost_unauthorizedAdminActionSucceeded = true;
    }

    // ── Criação atômica ────────────────────────────────────────────────────────────────

    function criarOfertaCompleta(
        uint256 actorSeed,
        uint256 metaMaximaSeed,
        uint256 metaMinimaSeed,
        uint256 precoSeed,
        uint256 prazoSeed,
        uint256 chaosSeed
    ) external {
        address emissor = _actorAt(actorSeed);
        ParametrosOferta memory p = _gerarParametros(metaMaximaSeed, metaMinimaSeed, precoSeed, prazoSeed, chaosSeed);
        if (p.precoPorCota == 0) return; // `_gerarParametros` sinaliza "pular esta chamada"

        bytes32 cnpjRef = keccak256(abi.encode("cnpj-fuzz", metaMaximaSeed, actorSeed));
        _executarCriacao(emissor, p, cnpjRef);
    }

    /// @dev Parâmetros agrupados em struct (memória), não soltos como retorno múltiplo —
    /// mesmo remédio já usado em `IOfertaCaptacao.InitParams` neste repositório para "stack
    /// too deep" com `via_ir` desligado (ver `foundry.toml`): passar um único ponteiro de
    /// memória entre funções custa uma unidade de pilha, não uma por campo.
    struct ParametrosOferta {
        uint256 metaMinima;
        uint256 metaMaxima;
        uint256 precoPorCota;
        uint256 prazo;
    }

    /// @dev `precoPorCota == 0` no retorno sinaliza "pule esta chamada" (o caso raro em que
    /// `precoSeed` amostrou um preço maior que o próprio teto de oferta, tornando
    /// `maxCotas == 0`).
    function _gerarParametros(
        uint256 metaMaximaSeed,
        uint256 metaMinimaSeed,
        uint256 precoSeed,
        uint256 prazoSeed,
        uint256 chaosSeed
    ) internal view returns (ParametrosOferta memory p) {
        uint256 teto = orq.TETO_OFERTA();
        p.precoPorCota = bound(precoSeed, 1, 1_000 ether);
        uint256 maxCotas = teto / p.precoPorCota;
        if (maxCotas == 0) {
            p.precoPorCota = 0;
            return p;
        }

        uint256 cotas = bound(metaMaximaSeed, 1, maxCotas);
        p.metaMaxima = cotas * p.precoPorCota;

        uint256 metaMinimaMin = (p.metaMaxima * orq.LOTE_ADICIONAL_DENOMINADOR()) / orq.LOTE_ADICIONAL_NUMERADOR();
        if (metaMinimaMin == 0) metaMinimaMin = 1;
        p.metaMinima = bound(metaMinimaSeed, metaMinimaMin, p.metaMaxima);

        p.prazo = block.timestamp + bound(prazoSeed, 1, orq.PRAZO_MAXIMO());

        if (_chaos(chaosSeed)) {
            _aplicarChaos(p, chaosSeed, metaMaximaSeed, prazoSeed, teto);
        }
    }

    /// @dev Recebe `p` por referência (struct `memory`) e muta no lugar — o chamador vê o
    /// resultado sem precisar de retorno.
    function _aplicarChaos(ParametrosOferta memory p, uint256 chaosSeed, uint256 metaMaximaSeed, uint256 prazoSeed, uint256 teto)
        internal
        view
    {
        uint256 modo = chaosSeed % 4;
        if (modo == 0) {
            p.prazo = block.timestamp + orq.PRAZO_MAXIMO() + 1 + (prazoSeed % 365 days);
        } else if (modo == 1) {
            p.metaMaxima = teto + 1 + (metaMaximaSeed % 1_000_000 ether);
        } else if (modo == 2 && p.metaMinima > 1) {
            p.metaMinima = p.metaMinima / 2; // tende a violar o lote adicional de 25%
        } else if (p.precoPorCota > 1) {
            p.metaMaxima = p.metaMaxima + 1; // quebra o múltiplo exato de precoPorCota
        }
    }

    function _executarCriacao(address emissor, ParametrosOferta memory p, bytes32 cnpjRef) internal {
        bool autorizadoAntes = orq.emissoresAutorizados(emissor);

        vm.prank(emissor);
        (address token, address oferta) = orq.criarOfertaCompleta(
            "Oferta Fuzz", "nFZ", "Empresa Fuzz", cnpjRef, "2026-FZ", p.metaMinima, p.metaMaxima, p.precoPorCota, p.prazo
        );

        // Só chega aqui se NÃO reverteu.
        tokens.push(token);
        ofertas.push(oferta);
        ghost_criadoEm[oferta] = block.timestamp;
        ghost_autorizadoNaCriacao[oferta] = autorizadoAntes;
        _trackEmissor(emissor);
    }

    // ── Fechamento de ofertas (permite uma segunda criação pelo mesmo emissor) ──────────

    function fecharUltimaOfertaComFalha(uint256 actorSeed) external {
        address emissor = _actorAt(actorSeed);
        address ofertaAddr = orq.ultimaOfertaDoEmissor(emissor);
        if (ofertaAddr == address(0)) return;
        if (OfertaCaptacao(ofertaAddr).estado() != OfertaCaptacao.Estado.Aberta) return;

        vm.prank(agenteGateway);
        OfertaCaptacao(ofertaAddr).cancelar();
    }

    function fecharUltimaOfertaComSucesso(uint256 actorSeed) external {
        address emissor = _actorAt(actorSeed);
        address ofertaAddr = orq.ultimaOfertaDoEmissor(emissor);
        if (ofertaAddr == address(0)) return;
        OfertaCaptacao oferta = OfertaCaptacao(ofertaAddr);
        if (oferta.estado() != OfertaCaptacao.Estado.Aberta) return;

        uint256 faltante = oferta.metaMaxima() - oferta.totalArrecadado();
        if (faltante > 0) {
            moeda.mint(investidorFuzz, faltante);
            vm.prank(investidorFuzz);
            moeda.approve(ofertaAddr, faltante);
            vm.prank(investidorFuzz);
            oferta.aportar(faltante);
        }
        oferta.encerrar();
    }

    // ── Views para o InvariantOrquestradorTest ──────────────────────────────────────────

    function numTokens() external view returns (uint256) {
        return tokens.length;
    }

    function numOfertas() external view returns (uint256) {
        return ofertas.length;
    }

    function numEmissoresRastreados() external view returns (uint256) {
        return emissoresRastreados.length;
    }
}
