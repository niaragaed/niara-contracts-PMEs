// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParticipacaoToken} from "../../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../../src/emissao/EmissaoGateway.sol";
import {RestrictedTransferPolicy} from "../../src/policies/RestrictedTransferPolicy.sol";
import {LiquidacaoSecundaria} from "../../src/secundario/LiquidacaoSecundaria.sol";
import {MockBRL} from "../../src/mocks/MockBRL.sol";

/// @notice Ator de fuzzing stateful do domínio da liquidação secundária (Fase 4): cria tokens
/// (a factory já aponta, por padrão, para a `RestrictedTransferPolicy` compartilhada — ver
/// `InvariantSecundarioTest.setUp`), minta cotas e `MockBRL`, gerencia elegibilidade/lock-up/
/// flag mestre da política (mesmo desenho de `HandlerPolitica` da Fase 3), gerencia allowances,
/// e submete cessões com partes/quantidades/preços aleatórios. Mesmo espírito de
/// `Handler`/`HandlerCaptacao`/`HandlerPolitica`: a maioria das chamadas usa parâmetros válidos;
/// as `tentar*` tomam de propósito o caminho inválido.
///
/// A prova central desta fase é o espelho `ghost_moedaEsperada`/`ghost_cotasEsperadas`: toda
/// via de entrada de saldo (mint de cotas via gateway, mint de `MockBRL`) e toda liquidação
/// bem-sucedida atualizam o espelho com a MESMA aritmética que o contrato real deveria aplicar.
/// Se `LiquidacaoSecundaria` tivesse um bug de conservação (perder poeira, duplicar uma perna,
/// aplicar a taxa errada) ou uma cessão bloqueada pela política de alguma forma movesse fundos
/// mesmo assim, o saldo real divergiria do espelho — não há caminho de saldo fora dessas duas
/// vias mirroradas.
contract HandlerSecundario is Test {
    ParticipacaoTokenFactory public factory;
    EmissaoGateway public gateway;
    RestrictedTransferPolicy public policy;
    MockBRL public moeda;
    LiquidacaoSecundaria public liquidacao;

    address public admin;
    address public agente;
    address[] public actors;

    address[] public tokens;

    mapping(address => uint256) public ghost_moedaEsperada;
    mapping(address => mapping(address => uint256)) public ghost_cotasEsperadas;

    /// @notice Vira `true` se uma `liquidarCessao` bem-sucedida tiver ocorrido com
    /// `policy.canTransfer(token, vendedor, comprador, quantidade) == false` no momento da
    /// chamada — a prova de que o gate Fase 3 ↔ Fase 4 nunca é contornado.
    bool public ghost_policyGateBypassSucceeded;

    /// @notice Vira `true` se `liquidarCessao` for bem-sucedida chamada por alguém sem
    /// `AGENTE_ROLE`.
    bool public ghost_unauthorizedLiquidarSucceeded;

    /// @notice Vira `true` se `proposeSetTaxaSecundarioBps`/`proposeSetProtocoloWallet` forem
    /// bem-sucedidos chamados por alguém sem `DEFAULT_ADMIN_ROLE`.
    bool public ghost_unauthorizedGovernanceCallSucceeded;

    /// @notice Vira `true` se `taxaSecundarioBps` ultrapassar o teto rígido em algum momento.
    bool public ghost_taxaExcedeuTetoSucceeded;

    struct Config {
        ParticipacaoTokenFactory factory;
        EmissaoGateway gateway;
        RestrictedTransferPolicy policy;
        MockBRL moeda;
        LiquidacaoSecundaria liquidacao;
        address admin;
        address agente;
        address[] actors;
    }

    constructor(Config memory config) {
        factory = config.factory;
        gateway = config.gateway;
        policy = config.policy;
        moeda = config.moeda;
        liquidacao = config.liquidacao;
        admin = config.admin;
        agente = config.agente;
        actors = config.actors;
    }

    // ── Helpers de seleção ─────────────────────────────────────────────────────────────

    function _actorAt(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _distinctActor(uint256 seed, address other) internal view returns (address) {
        uint256 idx = seed % actors.length;
        address candidate = actors[idx];
        if (candidate == other) candidate = actors[(idx + 1) % actors.length];
        return candidate;
    }

    function _pickToken(uint256 seed) internal view returns (address) {
        return tokens[seed % tokens.length];
    }

    function _chaos(uint256 seed) internal pure returns (bool) {
        return seed % 5 == 0;
    }

    // ── Criação de tokens (já apontam para a Restricted compartilhada, ver setUp) ────────

    function criarToken(uint256 seed) external {
        vm.prank(agente);
        address token = factory.criarOferta(
            "Oferta Secundario", "nSEC", "Empresa Secundario", bytes32(0), vm.toString(seed)
        );

        vm.prank(agente);
        gateway.atestarCotas(token, 1_000_000 ether);

        tokens.push(token);
    }

    // ── Entradas de saldo (mirroradas) ─────────────────────────────────────────────────

    function mintarCotas(uint256 tokenSeed, uint256 toSeed, uint256 amountSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address to = _actorAt(toSeed);

        uint256 restante = ParticipacaoToken(token).cotasAutorizadas() - ParticipacaoToken(token).totalSupply();
        if (restante == 0) return;
        uint256 amount = bound(amountSeed, 1, restante);

        vm.prank(agente);
        gateway.emitir(token, to, amount);
        ghost_cotasEsperadas[token][to] += amount;
    }

    function mintarMoeda(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actorAt(actorSeed);
        uint256 amount = bound(amountSeed, 1, 1_000_000 ether);

        moeda.mint(actor, amount);
        ghost_moedaEsperada[actor] += amount;
    }

    // ── Allowances ──────────────────────────────────────────────────────────────────────

    function aprovarCotas(uint256 tokenSeed, uint256 actorSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address actor = _actorAt(actorSeed);

        vm.prank(actor);
        ParticipacaoToken(token).approve(address(liquidacao), type(uint256).max);
    }

    function aprovarMoeda(uint256 actorSeed) external {
        address actor = _actorAt(actorSeed);
        vm.prank(actor);
        moeda.approve(address(liquidacao), type(uint256).max);
    }

    // ── Política (mesmo desenho de HandlerPolitica, Fase 3) ───────────────────────────────

    function definirElegivel(uint256 tokenSeed, uint256 investidorSeed, uint256 flagSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address investidor = _actorAt(investidorSeed);
        bool estaElegivel = flagSeed % 2 == 0;
        address caller = _chaos(chaosSeed) ? _actorAt(chaosSeed) : agente;

        vm.prank(caller);
        try policy.definirElegivel(token, investidor, estaElegivel) {} catch {}
    }

    function definirLockup(uint256 tokenSeed, uint256 lockupSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        uint64 novoLockupAte = uint64(block.timestamp + bound(lockupSeed, 0, 30 days));

        vm.prank(agente);
        try policy.definirLockup(token, novoLockupAte) {} catch {}
    }

    function abrirSecundario(uint256 tokenSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address caller = _chaos(chaosSeed) ? _actorAt(chaosSeed) : admin;

        vm.prank(caller);
        try policy.proposeSetSecundarioLiberado(token, true) returns (uint256 executeAfter) {
            if (caller != admin) {
                // Defesa em profundidade: RestrictedTransferPolicy já é coberta por
                // InvariantPoliticaTest (Fase 3); aqui só marcamos para não esconder uma
                // regressão silenciosamente caso o guard dela quebre.
                ghost_unauthorizedGovernanceCallSucceeded = true;
                return;
            }
            vm.warp(executeAfter);
            vm.prank(admin);
            policy.executeSetSecundarioLiberado(token, true);
        } catch {}
    }

    function avancarTempo(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 20 days));
    }

    // ── A ação central: submeter uma cessão ────────────────────────────────────────────

    function tentarLiquidarCessao(
        uint256 tokenSeed,
        uint256 vendedorSeed,
        uint256 compradorSeed,
        uint256 quantidadeSeed,
        uint256 precoSeed,
        uint256 chaosSeed
    ) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address vendedor = _actorAt(vendedorSeed);
        address comprador = _distinctActor(compradorSeed, vendedor);

        uint256 saldoVendedor = ParticipacaoToken(token).balanceOf(vendedor);
        bool chaos = _chaos(chaosSeed);

        uint256 quantidade;
        if (chaos) {
            quantidade = quantidadeSeed % (2 * (saldoVendedor == 0 ? 1 ether : saldoVendedor) + 1);
        } else {
            if (saldoVendedor == 0) return;
            quantidade = bound(quantidadeSeed, 1, saldoVendedor);
        }
        uint256 precoPorCota = bound(precoSeed, 1 ether, 1_000 ether);

        address caller = chaos && chaosSeed % 3 == 0 ? _actorAt(chaosSeed) : agente;

        bool policyGate = quantidade > 0 && policy.canTransfer(token, vendedor, comprador, quantidade);

        uint256 valor = (quantidade * precoPorCota) / 1 ether;
        uint256 taxa = (valor * liquidacao.taxaSecundarioBps()) / 10_000;

        vm.prank(caller);
        try liquidacao.liquidarCessao(token, vendedor, comprador, quantidade, precoPorCota) {
            if (caller != agente) {
                ghost_unauthorizedLiquidarSucceeded = true;
                return;
            }
            if (!policyGate) {
                ghost_policyGateBypassSucceeded = true;
                return;
            }

            ghost_cotasEsperadas[token][vendedor] -= quantidade;
            ghost_cotasEsperadas[token][comprador] += quantidade;
            ghost_moedaEsperada[comprador] -= valor;
            ghost_moedaEsperada[vendedor] += valor - taxa;
            ghost_moedaEsperada[liquidacao.protocoloWallet()] += taxa;
        } catch {}
    }

    // ── Governança (taxa / protocoloWallet) ────────────────────────────────────────────

    function ajustarTaxa(uint256 novaTaxaSeed, uint256 chaosSeed) external {
        bool chaos = _chaos(chaosSeed);
        uint256 novaTaxa = chaos ? bound(novaTaxaSeed, 101, 10_000) : bound(novaTaxaSeed, 0, 100);
        address caller = chaos && chaosSeed % 2 == 0 ? _actorAt(chaosSeed) : admin;

        vm.prank(caller);
        try liquidacao.proposeSetTaxaSecundarioBps(novaTaxa) returns (uint256 executeAfter) {
            if (caller != admin) {
                ghost_unauthorizedGovernanceCallSucceeded = true;
                return;
            }
            if (novaTaxa > liquidacao.TAXA_BPS_MAXIMA()) {
                ghost_taxaExcedeuTetoSucceeded = true;
                return;
            }
            vm.warp(executeAfter);
            vm.prank(admin);
            liquidacao.executeSetTaxaSecundarioBps(novaTaxa);
            if (liquidacao.taxaSecundarioBps() > liquidacao.TAXA_BPS_MAXIMA()) {
                ghost_taxaExcedeuTetoSucceeded = true;
            }
        } catch {}
    }

    // ── Views para o InvariantSecundarioTest ───────────────────────────────────────────

    function numTokens() external view returns (uint256) {
        return tokens.length;
    }

    function numActors() external view returns (uint256) {
        return actors.length;
    }
}
