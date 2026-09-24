// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DenyAllTransferPolicy} from "../src/policies/DenyAllTransferPolicy.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RegistroInvestidorQualificado} from "../src/registro/RegistroInvestidorQualificado.sol";
import {OfertaCaptacao} from "../src/captacao/OfertaCaptacao.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";
import {OfertaOrquestrador} from "../src/orquestracao/OfertaOrquestrador.sol";

/// @title CicloCompletoLocal
/// @notice Ensaio LOCAL do ciclo inteiro que `DeployFase2Sepolia.s.sol` +
/// `DeployFase2SepoliaExecute.s.sol` fazem de verdade em Sepolia, incluindo o passo que aqueles
/// dois scripts deliberadamente NÃO fazem (emissor/investidores nunca assinam por script em
/// Sepolia — cada um usa a própria carteira via `cast send`, ver NatSpec daqueles arquivos): aqui,
/// como é só um ensaio local, os cinco papéis (admin/agente, emissor, dois investidores) são as
/// contas de desenvolvimento padrão do Anvil (mnemonic "test test test ... junk") — endereços
/// PÚBLICOS e bem conhecidos, sem nenhuma chave privada em lugar nenhum deste arquivo. Servem
/// como assinatários porque o Anvil desbloqueia essas contas por padrão (impersonation nativa),
/// nunca porque este script conhece as chaves.
/// @dev Só funciona contra Anvil local — a guarda de `chainid` abaixo torna broadcast acidental
/// em rede real impossível (as contas dev do Anvil não têm ETH nem sentido em nenhuma outra
/// chain). `vm.warp` é usado para pular o timelock de 1h de verdade — válido SÓ em simulação
/// local/Anvil efêmero, nunca contra uma rede real recebendo transações de verdade (ver
/// CLAUDE.md, "Resultados de teste (Fase 1)").
///
/// Parâmetros da oferta (`metaMinima`/`metaMaxima`/`precoPorCota`) reaproveitam exatamente os
/// mesmos valores já validados em `test/OfertaOrquestrador.t.sol`
/// (`META_MINIMA_PADRAO`/`META_MAXIMA_PADRAO`/`PRECO_POR_COTA_PADRAO`): `metaMaxima*100 ==
/// metaMinima*125` exatamente no limite dos 25% de lote adicional da Res. CVM 88 que
/// `OfertaOrquestrador.criarOfertaCompleta` impõe — um valor arbitrário maior reverteria com
/// `LoteAdicionalExcedeLimite`. `taxaBps = 100` (1%, o teto rígido) de propósito, não `0` — o
/// objetivo deste ensaio é confirmar que o split de taxa para `PROTOCOLO` aparece corretamente
/// antes de rodar a mesma coisa de verdade em Sepolia.
///
/// Uso (dry-run, sem --broadcast): `forge script script/CicloCompletoLocal.s.sol --chain 31337`
/// Uso (contra anvil local rodando): `forge script script/CicloCompletoLocal.s.sol \
///   --rpc-url http://127.0.0.1:8545 --broadcast`
contract CicloCompletoLocal is Script {
    uint256 internal constant ANVIL_CHAIN_ID = 31337;
    uint256 internal constant TIMELOCK_DELAY = 1 hours;

    // Contas de desenvolvimento padrão do Anvil (índices 0-4 do mnemonic
    // "test test test test test test test test test test test junk") — conferidas nesta sessão
    // via `cast rpc eth_accounts` contra um `anvil` real. Públicas e conhecidas por qualquer
    // desenvolvedor Foundry; nenhuma chave privada aparece neste arquivo.
    address internal constant ADMIN = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // conta #0
    address internal constant INVESTIDOR1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // conta #1
    address internal constant INVESTIDOR2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // conta #2
    address internal constant EMISSOR = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // conta #3
    address internal constant PROTOCOLO = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65; // conta #4

    uint256 internal constant META_MINIMA = 800 ether;
    uint256 internal constant META_MAXIMA = 1_000 ether;
    uint256 internal constant PRECO_POR_COTA = 100 ether;
    uint256 internal constant TETO_POR_INVESTIDOR = 1_000 ether;
    uint256 internal constant TAXA_BPS = 100; // 1% — ver NatSpec do contrato.
    uint256 internal constant PRAZO_SEGUNDOS = 180 days;

    uint256 internal constant APORTE_INVESTIDOR1 = 600 ether;
    uint256 internal constant APORTE_INVESTIDOR2 = 400 ether;

    error RedeInvalida(uint256 chainIdAtual, uint256 chainIdEsperado);

    struct Infra {
        MockBRL moeda;
        DenyAllTransferPolicy policy;
        ParticipacaoToken tokenImplementacao;
        EmissaoGateway gateway;
        ParticipacaoTokenFactory tokenFactory;
        RegistroInvestidorQualificado registro;
        OfertaCaptacao captacaoImplementacao;
        OfertaCaptacaoFactory captacaoFactory;
        OfertaOrquestrador orquestrador;
    }

    function run() external {
        if (block.chainid != ANVIL_CHAIN_ID) revert RedeInvalida(block.chainid, ANVIL_CHAIN_ID);

        Infra memory infra = _deployEConcedePapeis();

        vm.startBroadcast(ADMIN);
        infra.orquestrador.autorizarEmissor(EMISSOR);
        infra.moeda.mint(INVESTIDOR1, APORTE_INVESTIDOR1);
        infra.moeda.mint(INVESTIDOR2, APORTE_INVESTIDOR2);
        vm.stopBroadcast();

        vm.startBroadcast(EMISSOR);
        (address token, address oferta) = infra.orquestrador.criarOfertaCompleta(
            "Oferta Ensaio Local",
            "nENS",
            "Empresa Ensaio Local Ltda",
            keccak256(abi.encode("cnpj-ensaio-local", block.timestamp)),
            "2026-ENSAIO-LOCAL",
            META_MINIMA,
            META_MAXIMA,
            PRECO_POR_COTA,
            block.timestamp + PRAZO_SEGUNDOS
        );
        vm.stopBroadcast();

        vm.startBroadcast(INVESTIDOR1);
        infra.moeda.approve(oferta, APORTE_INVESTIDOR1);
        OfertaCaptacao(oferta).aportar(APORTE_INVESTIDOR1);
        vm.stopBroadcast();

        vm.startBroadcast(INVESTIDOR2);
        infra.moeda.approve(oferta, APORTE_INVESTIDOR2);
        OfertaCaptacao(oferta).aportar(APORTE_INVESTIDOR2);
        vm.stopBroadcast();

        vm.startBroadcast(ADMIN);
        OfertaCaptacao(oferta).encerrar();
        vm.stopBroadcast();

        vm.startBroadcast(INVESTIDOR1);
        OfertaCaptacao(oferta).resgatarCotas();
        vm.stopBroadcast();

        vm.startBroadcast(INVESTIDOR2);
        OfertaCaptacao(oferta).resgatarCotas();
        vm.stopBroadcast();

        vm.startBroadcast(ADMIN);
        OfertaCaptacao(oferta).liberarParaEmissor();
        vm.stopBroadcast();

        _logResultados(infra, token, oferta);
    }

    function _deployEConcedePapeis() internal returns (Infra memory infra) {
        vm.startBroadcast(ADMIN);
        infra.moeda = new MockBRL();
        infra.policy = new DenyAllTransferPolicy();
        infra.tokenImplementacao = new ParticipacaoToken();
        infra.gateway = new EmissaoGateway(ADMIN, TIMELOCK_DELAY);
        infra.tokenFactory = new ParticipacaoTokenFactory(
            ADMIN, address(infra.tokenImplementacao), address(infra.gateway), address(infra.policy), TIMELOCK_DELAY
        );
        infra.registro = new RegistroInvestidorQualificado(ADMIN, TIMELOCK_DELAY);
        infra.captacaoImplementacao = new OfertaCaptacao();
        infra.captacaoFactory = new OfertaCaptacaoFactory(
            ADMIN,
            address(infra.captacaoImplementacao),
            address(infra.gateway),
            address(infra.registro),
            address(infra.moeda),
            TIMELOCK_DELAY
        );
        infra.orquestrador = new OfertaOrquestrador(
            ADMIN,
            address(infra.tokenFactory),
            address(infra.gateway),
            address(infra.captacaoFactory),
            PROTOCOLO,
            TAXA_BPS,
            TETO_POR_INVESTIDOR,
            TIMELOCK_DELAY
        );

        bytes32 agenteRole = infra.orquestrador.AGENTE_ROLE(); // mesmo hash nos 4 contratos
        infra.tokenFactory.proposeGrantRole(agenteRole, address(infra.orquestrador));
        infra.gateway.proposeGrantRole(agenteRole, address(infra.orquestrador));
        infra.captacaoFactory.proposeGrantRole(agenteRole, address(infra.orquestrador));
        infra.orquestrador.proposeGrantRole(agenteRole, ADMIN);

        // Só válido em simulação local/Anvil efêmero — ver NatSpec do contrato.
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        infra.tokenFactory.executeGrantRole(agenteRole, address(infra.orquestrador));
        infra.gateway.executeGrantRole(agenteRole, address(infra.orquestrador));
        infra.captacaoFactory.executeGrantRole(agenteRole, address(infra.orquestrador));
        infra.orquestrador.executeGrantRole(agenteRole, ADMIN);
        vm.stopBroadcast();
    }

    function _logResultados(Infra memory infra, address token, address oferta) internal view {
        console2.log("== CicloCompletoLocal: ciclo completo via OfertaOrquestrador ==");
        console2.log("Token (ParticipacaoToken):", token);
        console2.log("Oferta (escrow OfertaCaptacao):", oferta);
        console2.log("Estado final (1 = EncerradaSucesso):", uint256(OfertaCaptacao(oferta).estado()));
        console2.log("Total arrecadado:", OfertaCaptacao(oferta).totalArrecadado());
        console2.log("");
        console2.log("Cotas investidor 1:", ParticipacaoToken(token).balanceOf(INVESTIDOR1));
        console2.log("Cotas investidor 2:", ParticipacaoToken(token).balanceOf(INVESTIDOR2));
        console2.log("totalSupply do token:", ParticipacaoToken(token).totalSupply());
        console2.log("");
        console2.log("MockBRL no emissor apos liberacao:", infra.moeda.balanceOf(EMISSOR));
        console2.log("MockBRL no protocolo apos liberacao (taxa 1%):", infra.moeda.balanceOf(PROTOCOLO));
        console2.log("MockBRL restante no escrow (deve ser 0):", infra.moeda.balanceOf(oferta));
    }
}
