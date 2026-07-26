// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ParticipacaoTokenFactory} from "../../src/token/ParticipacaoTokenFactory.sol";
import {ParticipacaoToken} from "../../src/token/ParticipacaoToken.sol";
import {EmissaoGateway} from "../../src/emissao/EmissaoGateway.sol";

/// @notice Ator de fuzzing stateful: expõe uma ação por função pública (criar oferta, atestar,
/// emitir, tentar transferir, tentar burlar `onlyGateway`/`AGENTE_ROLE`/inicialização dupla,
/// pausas) para que o motor de invariantes do Foundry explore sequências aleatórias desses
/// passos.
/// @dev Espelha o desenho de `niara-contracts/test/invariant/Handler.sol` (ver Linhagem no
/// CLAUDE.md): a maior parte das chamadas usa parâmetros limitados (`bound`) a estados
/// válidos; uma fração (`_chaos`, ~1 em 5) toma deliberadamente o caminho inválido. Chamadas
/// externas não são envolvidas em try/catch — com `fail_on_revert = false` (ver
/// foundry.toml), um revert genuíno é tolerado pelo runner e desfaz atomicamente qualquer
/// efeito colateral desta chamada, inclusive as variáveis "ghost" abaixo. Um "ghost" só vira
/// `true` quando uma chamada que DEVERIA reverter (violação de acesso, dupla inicialização,
/// transferência proibida) termina sem reverter — ou seja, quando a invariante correspondente
/// foi de fato quebrada.
contract Handler is Test {
    ParticipacaoTokenFactory public factory;
    EmissaoGateway public gateway;

    address public admin;
    address public agente;
    address[] public actors;

    address[] public tokens;

    /// @notice Vira `true` se `mint`/`setCotasAutorizadas`/`pause`/`unpause` do token forem
    /// chamados com sucesso por alguém diferente do `gateway` configurado.
    bool public ghost_unauthorizedTokenCallSucceeded;

    /// @notice Vira `true` se `atestarCotas`/`emitir`/`pausarToken`/`despausarToken` do
    /// gateway, ou `criarOferta` da factory, forem chamados com sucesso por alguém sem
    /// `AGENTE_ROLE`.
    bool public ghost_unauthorizedRoleCallSucceeded;

    /// @notice Vira `true` se alguma transferência titular→titular (`transfer`/`transferFrom`)
    /// for bem-sucedida — a política `DenyAllTransferPolicy` deveria negar sempre.
    bool public ghost_transferSucceeded;

    /// @notice Vira `true` se `initialize` puder ser chamado uma segunda vez em um clone já
    /// inicializado.
    bool public ghost_reinitializeSucceeded;

    struct Config {
        ParticipacaoTokenFactory factory;
        EmissaoGateway gateway;
        address admin;
        address agente;
        address[] actors;
    }

    constructor(Config memory config) {
        factory = config.factory;
        gateway = config.gateway;
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
        if (candidate == other) {
            candidate = actors[(idx + 1) % actors.length];
        }
        return candidate;
    }

    function _pickToken(uint256 seed) internal view returns (ParticipacaoToken) {
        return ParticipacaoToken(tokens[seed % tokens.length]);
    }

    /// @dev ~1 em 5 chamadas toma o caminho "caótico" (inválido de propósito).
    function _chaos(uint256 seed) internal pure returns (bool) {
        return seed % 5 == 0;
    }

    // ── Criação de ofertas ──────────────────────────────────────────────────────────────

    function criarOferta(uint256 seed, uint256 chaosSeed) external {
        address caller = _chaos(chaosSeed) ? _actorAt(chaosSeed) : agente;

        string memory nome = string(abi.encodePacked("Oferta ", vm.toString(seed)));
        string memory simbolo = string(abi.encodePacked("nOF", vm.toString(seed % 1000)));
        string memory empresa = string(abi.encodePacked("Empresa ", vm.toString(seed)));
        bytes32 cnpjRef = keccak256(abi.encode("cnpj", seed));
        string memory serie = vm.toString(seed % 100);

        vm.prank(caller);
        address token = factory.criarOferta(nome, simbolo, empresa, cnpjRef, serie);
        tokens.push(token);

        if (caller != agente) ghost_unauthorizedRoleCallSucceeded = true;
    }

    // ── Atestação e emissão ─────────────────────────────────────────────────────────────

    function atestarCotas(uint256 tokenSeed, uint256 novoTetoSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        ParticipacaoToken token = _pickToken(tokenSeed);
        uint256 atual = token.cotasAutorizadas();

        bool chaos = _chaos(chaosSeed);
        uint256 novoTeto = chaos ? novoTetoSeed % (atual == 0 ? 1 : atual) : bound(novoTetoSeed, atual, atual + 1_000_000 ether);
        address caller = chaos && chaosSeed % 2 == 0 ? _actorAt(chaosSeed) : agente;

        vm.prank(caller);
        gateway.atestarCotas(address(token), novoTeto);

        if (caller != agente) ghost_unauthorizedRoleCallSucceeded = true;
    }

    function emitir(uint256 tokenSeed, uint256 toSeed, uint256 amountSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        ParticipacaoToken token = _pickToken(tokenSeed);
        address to = _actorAt(toSeed);

        uint256 restante = token.cotasAutorizadas() - token.totalSupply();
        bool chaos = _chaos(chaosSeed);

        uint256 amount;
        if (chaos) {
            amount = amountSeed % (2 * (restante == 0 ? 1 ether : restante) + 1); // pode exceder o restante, incl. zero.
        } else {
            if (restante == 0) return;
            amount = bound(amountSeed, 1, restante);
        }

        address caller = chaos && chaosSeed % 2 == 0 ? _actorAt(chaosSeed) : agente;

        vm.prank(caller);
        gateway.emitir(address(token), to, amount);

        if (caller != agente) ghost_unauthorizedRoleCallSucceeded = true;
    }

    // ── Pausas ──────────────────────────────────────────────────────────────────────────

    function pausarOuDespausarToken(uint256 tokenSeed, uint256 chaosSeed) external {
        if (tokens.length == 0) return;
        ParticipacaoToken token = _pickToken(tokenSeed);
        bool estaPausado = token.paused();
        address caller = _chaos(chaosSeed) ? _actorAt(chaosSeed) : agente;

        vm.prank(caller);
        if (estaPausado) {
            gateway.despausarToken(address(token));
        } else {
            gateway.pausarToken(address(token));
        }

        if (caller != agente) ghost_unauthorizedRoleCallSucceeded = true;
    }

    function pausarOuDespausarFactory(uint256 chaosSeed) external {
        bool estaPausado = factory.paused();
        address caller = _chaos(chaosSeed) ? _actorAt(chaosSeed) : agente;

        vm.prank(caller);
        if (estaPausado) {
            factory.unpause();
        } else {
            factory.pause();
        }

        if (caller != agente) ghost_unauthorizedRoleCallSucceeded = true;
    }

    // ── Tentativas de transferência titular→titular (deveriam sempre reverter) ────────────

    function tentarTransferir(uint256 tokenSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        if (tokens.length == 0) return;
        ParticipacaoToken token = _pickToken(tokenSeed);
        address from = _actorAt(fromSeed);
        address to = _distinctActor(toSeed, from);

        uint256 saldo = token.balanceOf(from);
        if (saldo == 0) return;
        uint256 amount = bound(amountSeed, 1, saldo);

        vm.prank(from);
        token.transfer(to, amount);

        // Só chega aqui se NÃO reverteu — a política nega-tudo foi violada.
        ghost_transferSucceeded = true;
    }

    function tentarTransferirFrom(uint256 tokenSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        if (tokens.length == 0) return;
        ParticipacaoToken token = _pickToken(tokenSeed);
        address from = _actorAt(fromSeed);
        address to = _distinctActor(toSeed, from);

        uint256 saldo = token.balanceOf(from);
        if (saldo == 0) return;
        uint256 amount = bound(amountSeed, 1, saldo);

        vm.prank(from);
        token.approve(to, amount);

        vm.prank(to);
        token.transferFrom(from, to, amount);

        ghost_transferSucceeded = true;
    }

    // ── Tentativas de burlar onlyGateway direto no token ───────────────────────────────

    function tentarChamarRestritaNoToken(uint256 tokenSeed, uint256 actorSeed, uint256 acaoSeed) external {
        if (tokens.length == 0) return;
        ParticipacaoToken token = _pickToken(tokenSeed);
        address ator = _actorAt(actorSeed);
        uint256 acao = acaoSeed % 4;

        vm.prank(ator);
        if (acao == 0) {
            token.mint(ator, 1);
        } else if (acao == 1) {
            token.setCotasAutorizadas(token.cotasAutorizadas() + 1);
        } else if (acao == 2) {
            token.pause();
        } else {
            token.unpause();
        }

        // Só chega aqui se NÃO reverteu — `onlyGateway` foi burlado.
        ghost_unauthorizedTokenCallSucceeded = true;
    }

    // ── Tentativa de reinicializar um clone já inicializado ────────────────────────────

    function tentarReinicializar(uint256 tokenSeed) external {
        if (tokens.length == 0) return;
        ParticipacaoToken token = _pickToken(tokenSeed);

        token.initialize("X", "X", address(gateway), address(gateway), "X", bytes32(0), "X");

        // Só chega aqui se NÃO reverteu — inicialização dupla foi permitida.
        ghost_reinitializeSucceeded = true;
    }

    // ── Views para o InvariantTest ──────────────────────────────────────────────────────

    function numTokens() external view returns (uint256) {
        return tokens.length;
    }

    function numActors() external view returns (uint256) {
        return actors.length;
    }
}
