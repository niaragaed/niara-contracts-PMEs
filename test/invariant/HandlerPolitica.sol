// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ParticipacaoToken} from "../../src/token/ParticipacaoToken.sol";
import {EmissaoGateway} from "../../src/emissao/EmissaoGateway.sol";
import {RestrictedTransferPolicy} from "../../src/policies/RestrictedTransferPolicy.sol";

/// @notice Ator de fuzzing stateful do domínio da política restrita (Fase 3): cria tokens já
/// apontando para `RestrictedTransferPolicy`, minta saldo inicial via `gateway.emitir`, e expõe
/// uma ação por peça da tabela-verdade de `canTransfer` (definir elegibilidade, definir
/// lock-up, abrir o secundário, tentar transferir) mais tentativas deliberadas de burlar
/// guardas (`tentar*`). Mesmo desenho de `test/invariant/Handler.sol`/`HandlerCaptacao.sol` (ver
/// Linhagem no CLAUDE.md): a maioria das chamadas usa parâmetros válidos; as `tentar*` tomam de
/// propósito o caminho inválido, sem try/catch — só viram "ghost" `true` quando uma chamada que
/// DEVERIA reverter termina sem reverter.
///
/// `ghost_*Esperado` espelham, em memória do handler, o estado que o handler mesmo escreveu na
/// política — comparados pelo InvariantPoliticaTest contra os getters reais da política a cada
/// invariante. Como cada mapping da política é keyed por `token`, essa comparação prova
/// isolamento entre tokens "de graça": se uma escrita em `tokenA` vazasse para `tokenB`, o
/// espelho de `tokenB` divergiria do real.
contract HandlerPolitica is Test {
    EmissaoGateway public gateway;
    RestrictedTransferPolicy public policy;
    ParticipacaoToken public tokenImplementacao;

    address public admin;
    address public agente;
    address[] public actors;

    address[] public tokens;

    mapping(address => bool) public ghost_secundarioLiberadoEsperado;
    mapping(address => uint64) public ghost_lockupAteEsperado;
    mapping(address => mapping(address => bool)) public ghost_elegivelEsperado;

    /// @notice Vira `true` se uma transferência titular→titular tiver um resultado
    /// (sucesso/revert) diferente do previsto pela tabela-verdade (secundarioLiberado &&
    /// !lockup && elegivel[to]) — é a prova central da Fase 3.
    bool public ghost_truthTableViolated;

    /// @notice Vira `true` se `definirElegivel`/`definirLockup` forem bem-sucedidos chamados
    /// por alguém sem `AGENTE_ROLE`.
    bool public ghost_unauthorizedOperationalCallSucceeded;

    /// @notice Vira `true` se `proposeSetSecundarioLiberado` for bem-sucedido chamado por
    /// alguém sem `DEFAULT_ADMIN_ROLE`.
    bool public ghost_unauthorizedSecundarioToggleSucceeded;

    /// @notice Vira `true` se um segundo `definirLockup` no mesmo token for bem-sucedido
    /// (violaria "set-once").
    bool public ghost_doubleLockupSucceeded;

    /// @notice Vira `true` se `gateway.emitir` (mint, dentro do teto atestado) reverter só por
    /// causa do estado da `RestrictedTransferPolicy` anexada — mint nunca deveria consultar a
    /// política (ver `ParticipacaoToken._update`, `from == address(0)`).
    bool public ghost_mintFailedUnexpectedly;

    struct Config {
        EmissaoGateway gateway;
        RestrictedTransferPolicy policy;
        ParticipacaoToken tokenImplementacao;
        address admin;
        address agente;
        address[] actors;
    }

    constructor(Config memory config) {
        gateway = config.gateway;
        policy = config.policy;
        tokenImplementacao = config.tokenImplementacao;
        admin = config.admin;
        agente = config.agente;
        actors = config.actors;
    }

    // ── Helpers de seleção ─────────────────────────────────────────────────────────────

    function _actorAt(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _pickToken(uint256 seed) internal view returns (address) {
        return tokens[seed % tokens.length];
    }

    function _chaos(uint256 seed) internal pure returns (bool) {
        return seed % 5 == 0;
    }

    // ── Criação de tokens já com a Restricted anexada ──────────────────────────────────

    function criarToken(uint256 seed) external {
        address clone = Clones.clone(address(tokenImplementacao));
        ParticipacaoToken(clone).initialize(
            "Oferta Politica", "nPOL", address(gateway), address(policy), "Empresa Politica", bytes32(0), vm.toString(seed)
        );

        vm.prank(agente);
        gateway.atestarCotas(clone, 1_000_000 ether);

        tokens.push(clone);
    }

    // ── Mint (deve sempre passar, independente do estado da política) ─────────────────

    function mintar(uint256 tokenSeed, uint256 toSeed, uint256 amountSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address to = _actorAt(toSeed);

        uint256 restante = ParticipacaoToken(token).cotasAutorizadas() - ParticipacaoToken(token).totalSupply();
        if (restante == 0) return;
        uint256 amount = bound(amountSeed, 1, restante);

        vm.prank(agente);
        try gateway.emitir(token, to, amount) {}
        catch {
            ghost_mintFailedUnexpectedly = true;
        }
    }

    // ── Elegibilidade (operacional, AGENTE) ────────────────────────────────────────────

    function definirElegivel(uint256 tokenSeed, uint256 investidorSeed, uint256 flagSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address investidor = _actorAt(investidorSeed);
        bool estaElegivel = flagSeed % 2 == 0;
        bool chaos = _chaos(chaosSeed);
        address caller = chaos ? _actorAt(chaosSeed) : agente;

        vm.prank(caller);
        try policy.definirElegivel(token, investidor, estaElegivel) {
            if (caller != agente) {
                ghost_unauthorizedOperationalCallSucceeded = true;
            } else {
                ghost_elegivelEsperado[token][investidor] = estaElegivel;
            }
        } catch {}
    }

    // ── Lock-up (operacional, AGENTE, set-once) ────────────────────────────────────────

    function definirLockup(uint256 tokenSeed, uint256 lockupSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        bool chaos = _chaos(chaosSeed);
        address caller = chaos ? _actorAt(chaosSeed) : agente;
        uint64 novoLockupAte = uint64(block.timestamp + bound(lockupSeed, 0, 60 days));

        vm.prank(caller);
        try policy.definirLockup(token, novoLockupAte) {
            if (caller != agente) {
                ghost_unauthorizedOperationalCallSucceeded = true;
            } else {
                ghost_lockupAteEsperado[token] = novoLockupAte;
            }
        } catch {}
    }

    function tentarLockupDuplicado(uint256 tokenSeed, uint256 lockupSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        if (!policy.lockupDefinido(token)) return;

        vm.prank(agente);
        policy.definirLockup(token, uint64(block.timestamp + bound(lockupSeed, 0, 60 days)));

        // Só chega aqui se NÃO reverteu — "set-once" foi violado.
        ghost_doubleLockupSucceeded = true;
    }

    // ── Flag mestre (governado por timelock — tratado como uma ação atômica do ponto de
    // vista do fuzzer, mesmo espírito de `_grantRoleOn` nos outros testes de invariante) ──

    function abrirSecundario(uint256 tokenSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        bool chaos = _chaos(chaosSeed);
        address caller = chaos ? _actorAt(chaosSeed) : admin;

        vm.prank(caller);
        try policy.proposeSetSecundarioLiberado(token, true) returns (uint256 executeAfter) {
            if (caller != admin) {
                ghost_unauthorizedSecundarioToggleSucceeded = true;
                return;
            }
            vm.warp(executeAfter);
            vm.prank(admin);
            policy.executeSetSecundarioLiberado(token, true);
            ghost_secundarioLiberadoEsperado[token] = true;
        } catch {}
    }

    // ── Tempo ───────────────────────────────────────────────────────────────────────────

    function avancarTempo(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 40 days));
    }

    // ── Tentativas de transferência: o coração da tabela-verdade ──────────────────────────

    function tentarTransferir(uint256 tokenSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        if (tokens.length == 0) return;
        address token = _pickToken(tokenSeed);
        address from = _actorAt(fromSeed);
        uint256 saldo = ParticipacaoToken(token).balanceOf(from);
        if (saldo == 0) return;
        uint256 idx = toSeed % actors.length;
        address to = actors[idx] == from ? actors[(idx + 1) % actors.length] : actors[idx];
        uint256 amount = bound(amountSeed, 1, saldo);

        bool deveriaPassar = policy.secundarioLiberado(token) && block.timestamp >= policy.lockupAte(token)
            && policy.elegivel(token, to);

        vm.prank(from);
        try ParticipacaoToken(token).transfer(to, amount) returns (bool) {
            if (!deveriaPassar) ghost_truthTableViolated = true;
        } catch {
            if (deveriaPassar) ghost_truthTableViolated = true;
        }
    }

    // ── Views para o InvariantPoliticaTest ─────────────────────────────────────────────

    function numTokens() external view returns (uint256) {
        return tokens.length;
    }

    function numActors() external view returns (uint256) {
        return actors.length;
    }
}
