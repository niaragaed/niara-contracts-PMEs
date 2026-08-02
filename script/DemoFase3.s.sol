// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";

/// @title DemoFase3
/// @notice Script de demonstração LOCAL/DRY-RUN da Fase 3: mostra o ciclo "abrir negociação
/// após o prazo" — uma oferta nasce com `DenyAllTransferPolicy` (secundário totalmente
/// desligado, comportamento padrão desde a Fase 1), o AGENTE prepara a `RestrictedTransferPolicy`
/// (lock-up + allowlist) e a governança aponta o token para ela (ainda travado, porque
/// `secundarioLiberado` começa em `false`), e só depois de decorrido o lock-up E a governança
/// ligar a flag mestre (timelock) é que a transferência entre dois investidores elegíveis passa.
/// Prova também os dois contra-exemplos: transferir antes da liberação/lock-up continua
/// revertendo mesmo já apontando para a Restricted, e transferir para alguém fora da allowlist
/// reverte mesmo com o secundário liberado.
/// @dev NUNCA rodar com `--broadcast` contra Sepolia sem instrução explícita do usuário (ver
/// CLAUDE.md). Mesma ressalva de `DeployFase1.s.sol`/`DeployFase2.s.sol` sobre `vm.warp`: só
/// "pula" o atraso do timelock e o lock-up em simulação local (sem `--broadcast`) ou contra
/// `anvil` efêmero — contra uma rede real, o tempo precisa decorrer de verdade.
contract DemoFase3 is Script {
    uint256 internal constant TIMELOCK_DELAY = 1 hours;
    uint256 internal constant COTAS_AUTORIZADAS_DEMO = 100_000 ether;
    uint256 internal constant COTAS_INVESTIDOR1_DEMO = 1_000 ether;
    uint256 internal constant COTAS_INVESTIDOR2_DEMO = 1_000 ether;
    uint256 internal constant VALOR_TRANSFERIDO_DEMO = 100 ether;
    uint256 internal constant LOCKUP_DEMO_SEGUNDOS = 7 days;

    struct Config {
        uint256 deployerPrivateKey;
        uint256 investidor1PrivateKey;
        uint256 investidor2PrivateKey;
        address admin;
        address agente;
        address investidor1;
        address investidor2;
        address naoElegivel;
    }

    struct Infra {
        DenyAllTransferPolicy denyAll;
        RestrictedTransferPolicy restricted;
        ParticipacaoToken tokenImplementacao;
        EmissaoGateway gateway;
        ParticipacaoTokenFactory factory;
        address token;
    }

    function run() external returns (Infra memory infra) {
        Config memory cfg = _readConfig();
        _logConfig(cfg);

        vm.startBroadcast(cfg.deployerPrivateKey);
        infra = _deployInfra(cfg);
        _concederAgente(infra, cfg.agente);
        _criarOfertaEEmitir(infra, cfg);
        vm.stopBroadcast();

        console2.log("");
        console2.log("== Passo 1: secundario desligado (DenyAllTransferPolicy) ==");
        _tentarTransferir(infra, cfg.investidor1PrivateKey, cfg.investidor2, "investidor1 -> investidor2");

        vm.startBroadcast(cfg.deployerPrivateKey);
        _prepararRestricted(infra, cfg);
        _apontarParaRestricted(infra);
        vm.stopBroadcast();

        console2.log("");
        console2.log("== Passo 2: ja aponta para a Restricted, mas ainda travado (liberado=false, dentro do lock-up) ==");
        _tentarTransferir(infra, cfg.investidor1PrivateKey, cfg.investidor2, "investidor1 -> investidor2 (cedo demais)");

        vm.warp(block.timestamp + LOCKUP_DEMO_SEGUNDOS + 1);

        vm.startBroadcast(cfg.deployerPrivateKey);
        _abrirSecundario(infra);
        vm.stopBroadcast();

        console2.log("");
        console2.log("== Passo 3: liberado e apos o lock-up, mas destinatario fora da allowlist ==");
        _tentarTransferir(infra, cfg.investidor1PrivateKey, cfg.naoElegivel, "investidor1 -> naoElegivel");

        console2.log("");
        console2.log("== Passo 4: liberado, apos o lock-up, destinatario elegivel ==");
        _transferirComSucesso(infra, cfg);

        _logEstadoFinal(infra, cfg);
    }

    // ── Configuração ────────────────────────────────────────────────────────────────────

    function _readConfig() internal view returns (Config memory cfg) {
        cfg.deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(1));
        cfg.investidor1PrivateKey = vm.envOr("INVESTIDOR1_PRIVATE_KEY", uint256(2));
        cfg.investidor2PrivateKey = vm.envOr("INVESTIDOR2_PRIVATE_KEY", uint256(3));

        address deployer = vm.addr(cfg.deployerPrivateKey);
        cfg.admin = vm.envOr("ADMIN_ADDRESS", deployer);
        cfg.agente = vm.envOr("AGENTE_ADDRESS", deployer);
        cfg.investidor1 = vm.addr(cfg.investidor1PrivateKey);
        cfg.investidor2 = vm.addr(cfg.investidor2PrivateKey);
        cfg.naoElegivel = vm.envOr("NAO_ELEGIVEL_ADDRESS", vm.addr(6));
    }

    // ── Deploy da infraestrutura (Fase 1, mais a Restricted da Fase 3) ─────────────────────

    function _deployInfra(Config memory cfg) internal returns (Infra memory infra) {
        infra.denyAll = new DenyAllTransferPolicy();
        infra.restricted = new RestrictedTransferPolicy(cfg.admin, TIMELOCK_DELAY);
        infra.tokenImplementacao = new ParticipacaoToken();
        infra.gateway = new EmissaoGateway(cfg.admin, TIMELOCK_DELAY);
        infra.factory = new ParticipacaoTokenFactory(
            cfg.admin, address(infra.tokenImplementacao), address(infra.gateway), address(infra.denyAll), TIMELOCK_DELAY
        );
    }

    /// @dev Concede AGENTE_ROLE em gateway, factory e restricted, via propose→warp→execute
    /// (mesma ressalva de `DeployFase1`/`DeployFase2` sobre validade do `vm.warp`).
    function _concederAgente(Infra memory infra, address agente) internal {
        address[3] memory alvos = [address(infra.gateway), address(infra.factory), address(infra.restricted)];
        bytes32 role = keccak256("AGENTE_ROLE");

        for (uint256 i = 0; i < alvos.length; i++) {
            (bool ok,) = alvos[i].call(abi.encodeWithSignature("proposeGrantRole(bytes32,address)", role, agente));
            require(ok, "propose AGENTE_ROLE falhou");
        }

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        for (uint256 i = 0; i < alvos.length; i++) {
            (bool ok,) = alvos[i].call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, agente));
            require(ok, "execute AGENTE_ROLE falhou");
        }
    }

    // ── Passo 0: mini-ciclo de emissão (mint via gateway, passa com qualquer política) ─────

    function _criarOfertaEEmitir(Infra memory infra, Config memory cfg) internal {
        infra.token = infra.factory.criarOferta(
            "Oferta Demo Fase 3", "nDEMO3", "Empresa Demo Fase 3 Ltda", keccak256("cnpj-demo-fase3"), "2026-A"
        );

        infra.gateway.atestarCotas(infra.token, COTAS_AUTORIZADAS_DEMO);
        infra.gateway.emitir(infra.token, cfg.investidor1, COTAS_INVESTIDOR1_DEMO);
        infra.gateway.emitir(infra.token, cfg.investidor2, COTAS_INVESTIDOR2_DEMO);
    }

    // ── Passo 2: AGENTE prepara a Restricted (lock-up set-once + allowlist), governança aponta
    // o token para ela ─────────────────────────────────────────────────────────────────────

    function _prepararRestricted(Infra memory infra, Config memory cfg) internal {
        uint64 lockupAte = uint64(block.timestamp + LOCKUP_DEMO_SEGUNDOS);
        infra.restricted.definirLockup(infra.token, lockupAte);
        infra.restricted.definirElegivel(infra.token, cfg.investidor1, true);
        infra.restricted.definirElegivel(infra.token, cfg.investidor2, true);
        // cfg.naoElegivel de propósito NÃO entra na allowlist — é o contra-exemplo do Passo 3.
    }

    function _apontarParaRestricted(Infra memory infra) internal {
        infra.gateway.proposeSetTransferPolicy(infra.token, address(infra.restricted));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        infra.gateway.executeSetTransferPolicy(infra.token, address(infra.restricted));
    }

    // ── Passo 4: governança liga a flag mestre (timelock) ───────────────────────────────

    function _abrirSecundario(Infra memory infra) internal {
        infra.restricted.proposeSetSecundarioLiberado(infra.token, true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        infra.restricted.executeSetSecundarioLiberado(infra.token, true);
    }

    // ── Transferências de demonstração ──────────────────────────────────────────────────

    function _tentarTransferir(Infra memory infra, uint256 dePrivateKey, address para, string memory rotulo)
        internal
    {
        vm.startBroadcast(dePrivateKey);
        try ParticipacaoToken(infra.token).transfer(para, VALOR_TRANSFERIDO_DEMO) {
            console2.log(string.concat("[INESPERADO] transferencia passou: ", rotulo));
            revert("Fase 3: transferencia deveria ter revertido");
        } catch {
            console2.log(string.concat("[OK] transferencia revertida como esperado: ", rotulo));
        }
        vm.stopBroadcast();
    }

    function _transferirComSucesso(Infra memory infra, Config memory cfg) internal {
        vm.startBroadcast(cfg.investidor1PrivateKey);
        ParticipacaoToken(infra.token).transfer(cfg.investidor2, VALOR_TRANSFERIDO_DEMO);
        vm.stopBroadcast();
        console2.log("[OK] transferencia investidor1 -> investidor2 passou");
    }

    // ── Logs ────────────────────────────────────────────────────────────────────────────

    function _logConfig(Config memory cfg) internal pure {
        console2.log("== Configuracao ==");
        console2.log("Admin:", cfg.admin);
        console2.log("Agente:", cfg.agente);
        console2.log("Investidor 1 (elegivel):", cfg.investidor1);
        console2.log("Investidor 2 (elegivel):", cfg.investidor2);
        console2.log("Nao elegivel (contra-exemplo):", cfg.naoElegivel);
        console2.log("Timelock delay (segundos):", TIMELOCK_DELAY);
        console2.log("Lock-up (segundos):", LOCKUP_DEMO_SEGUNDOS);
    }

    function _logEstadoFinal(Infra memory infra, Config memory cfg) internal view {
        console2.log("");
        console2.log("== Enderecos implantados ==");
        console2.log("DenyAllTransferPolicy:", address(infra.denyAll));
        console2.log("RestrictedTransferPolicy:", address(infra.restricted));
        console2.log("EmissaoGateway:", address(infra.gateway));
        console2.log("ParticipacaoTokenFactory:", address(infra.factory));
        console2.log("Token (oferta demo):", infra.token);

        console2.log("");
        console2.log("== Estado final da politica (RestrictedTransferPolicy) ==");
        console2.log("secundarioLiberado:", infra.restricted.secundarioLiberado(infra.token));
        console2.log("lockupAte:", infra.restricted.lockupAte(infra.token));
        console2.log("elegivel[investidor1]:", infra.restricted.elegivel(infra.token, cfg.investidor1));
        console2.log("elegivel[investidor2]:", infra.restricted.elegivel(infra.token, cfg.investidor2));
        console2.log("elegivel[naoElegivel]:", infra.restricted.elegivel(infra.token, cfg.naoElegivel));

        console2.log("");
        console2.log("== Saldos finais ==");
        console2.log("Investidor 1:", ParticipacaoToken(infra.token).balanceOf(cfg.investidor1));
        console2.log("Investidor 2:", ParticipacaoToken(infra.token).balanceOf(cfg.investidor2));
    }
}
