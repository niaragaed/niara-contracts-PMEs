// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";

/// @title DeployFase1
/// @notice Script de demonstração LOCAL/DRY-RUN da Fase 1. Implanta a política padrão
/// (`DenyAllTransferPolicy`), a implementação-template do token, o `EmissaoGateway` e a
/// `ParticipacaoTokenFactory`; concede `AGENTE_ROLE` ao agente de demonstração; cria uma
/// oferta, atesta cotas e emite um lote para um investidor de teste. Imprime todos os
/// endereços implantados ao final.
/// @dev NUNCA rodar com `--broadcast` contra Sepolia sem instrução explícita do usuário (ver
/// CLAUDE.md, regra "Sem deploy em Sepolia sem instrução explícita"). Este script usa
/// `vm.warp` para "pular" o atraso do timelock entre `propose` e `execute` — isso só reflete
/// a realidade em simulação local (sem `--broadcast`) ou contra um `anvil` efêmero. Contra
/// uma rede real, o tempo precisa decorrer de verdade entre as duas chamadas (mesma ressalva
/// documentada em `niara-contracts/script/Deploy.s.sol`, que por isso separa deploy e fiação
/// em duas transmissões distintas — aqui optamos por um único `run()` pensado para demo
/// local, onde `vm.warp` é válido).
contract DeployFase1 is Script {
    uint256 internal constant TIMELOCK_DELAY = 1 hours;
    uint256 internal constant COTAS_AUTORIZADAS_DEMO = 100_000 ether;
    uint256 internal constant COTAS_EMITIDAS_DEMO = 10_000 ether;

    struct Config {
        uint256 deployerPrivateKey;
        address admin;
        address agente;
        address investidorDemo;
    }

    function run()
        external
        returns (
            DenyAllTransferPolicy policy,
            ParticipacaoToken implementacao,
            EmissaoGateway gateway,
            ParticipacaoTokenFactory factory,
            address ofertaDemo
        )
    {
        Config memory cfg = _readConfig();
        _logConfig(cfg);

        vm.startBroadcast(cfg.deployerPrivateKey);

        (policy, implementacao, gateway, factory) = _deployAll(cfg);
        _concederAgente(gateway, factory, cfg.agente);
        ofertaDemo = _criarAtestarEmitir(gateway, factory, cfg.investidorDemo);

        vm.stopBroadcast();

        _logDeployedAddresses(policy, implementacao, gateway, factory, ofertaDemo);
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────────────

    function _readConfig() internal view returns (Config memory cfg) {
        cfg.deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(1));
        address deployer = vm.addr(cfg.deployerPrivateKey);
        cfg.admin = vm.envOr("ADMIN_ADDRESS", deployer);
        cfg.agente = vm.envOr("AGENTE_ADDRESS", deployer);
        cfg.investidorDemo = vm.envOr("INVESTIDOR_DEMO_ADDRESS", deployer);
    }

    function _deployAll(Config memory cfg)
        internal
        returns (
            DenyAllTransferPolicy policy,
            ParticipacaoToken implementacao,
            EmissaoGateway gateway,
            ParticipacaoTokenFactory factory
        )
    {
        policy = new DenyAllTransferPolicy();
        implementacao = new ParticipacaoToken();
        gateway = new EmissaoGateway(cfg.admin, TIMELOCK_DELAY);
        factory = new ParticipacaoTokenFactory(
            cfg.admin, address(implementacao), address(gateway), address(policy), TIMELOCK_DELAY
        );
    }

    /// @dev Concede AGENTE_ROLE em gateway e factory ao agente de demonstração, via
    /// propose→warp→execute (ver ressalva no NatSpec do contrato sobre validade do `vm.warp`).
    function _concederAgente(EmissaoGateway gateway, ParticipacaoTokenFactory factory, address agente) internal {
        bytes32 agenteRoleGateway = gateway.AGENTE_ROLE();
        bytes32 agenteRoleFactory = factory.AGENTE_ROLE();

        gateway.proposeGrantRole(agenteRoleGateway, agente);
        factory.proposeGrantRole(agenteRoleFactory, agente);

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        gateway.executeGrantRole(agenteRoleGateway, agente);
        factory.executeGrantRole(agenteRoleFactory, agente);
    }

    function _criarAtestarEmitir(EmissaoGateway gateway, ParticipacaoTokenFactory factory, address investidorDemo)
        internal
        returns (address token)
    {
        token = factory.criarOferta(
            "Oferta Demo Fase 1", "nDEMO", "Empresa Demo Ltda", keccak256("cnpj-demo"), "2026-A"
        );

        gateway.atestarCotas(token, COTAS_AUTORIZADAS_DEMO);
        gateway.emitir(token, investidorDemo, COTAS_EMITIDAS_DEMO);
    }

    // ── Logs ────────────────────────────────────────────────────────────────────────────

    function _logConfig(Config memory cfg) internal pure {
        console2.log("== Configuracao ==");
        console2.log("Admin:", cfg.admin);
        console2.log("Agente:", cfg.agente);
        console2.log("Investidor demo:", cfg.investidorDemo);
        console2.log("Timelock delay (segundos):", TIMELOCK_DELAY);
    }

    function _logDeployedAddresses(
        DenyAllTransferPolicy policy,
        ParticipacaoToken implementacao,
        EmissaoGateway gateway,
        ParticipacaoTokenFactory factory,
        address ofertaDemo
    ) internal pure {
        console2.log("");
        console2.log("== Enderecos implantados ==");
        console2.log("DenyAllTransferPolicy:", address(policy));
        console2.log("ParticipacaoToken (implementacao/template):", address(implementacao));
        console2.log("EmissaoGateway:", address(gateway));
        console2.log("ParticipacaoTokenFactory:", address(factory));
        console2.log("Oferta demo (clone):", ofertaDemo);
        console2.log("");
        console2.log("Cotas autorizadas na oferta demo:", COTAS_AUTORIZADAS_DEMO);
        console2.log("Cotas emitidas ao investidor demo:", COTAS_EMITIDAS_DEMO);
    }
}
