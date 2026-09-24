// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockedAccessControl} from "../src/governance/TimelockedAccessControl.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {RegistroInvestidorQualificado} from "../src/registro/RegistroInvestidorQualificado.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";
import {OfertaOrquestrador} from "../src/orquestracao/OfertaOrquestrador.sol";

/// @title DeployFase2SepoliaExecute
/// @notice Parte 2/2 — rodar só depois de `DeployFase2Sepolia.s.sol` e de >= 1h de tempo REAL
/// terem decorrido (ver NatSpec daquele script sobre por que o timelock não pode ser pulado em
/// rede real). Lê os 9 endereços implantados em `./script/output/fase2-sepolia.json` — nunca
/// recebidos por variável de ambiente digitada à mão (nove endereços é convite a erro de
/// digitação; um errado aponta a execução para o contrato errado). Executa as 5 concessões de
/// `AGENTE_ROLE` propostas (incluindo `RegistroInvestidorQualificado`, pré-requisito de
/// `definirQualificado` para qualquer investidor que precise aportar acima do
/// `tetoPorInvestidor` de uma oferta — ver NatSpec de `DeployFase2Sepolia.s.sol`) e autoriza o
/// primeiro emissor a operar o canal self-service.
/// @dev Único signatário: a conta resolvida por `--account` (a mesma usada no deploy — precisa
/// deter `DEFAULT_ADMIN_ROLE` nos cinco contratos, concedido a ela mesma no script anterior).
/// Idempotente: cada `executeGrantRole` checa `hasRole` antes e pula se já concedido — rodar
/// este script mais de uma vez não quebra (`autorizarEmissor` também é naturalmente idempotente:
/// gravar `true` de novo não tem efeito colateral).
///
/// Uso:
///   EMISSOR_WALLET_ADDRESS=0x... \
///   forge script script/DeployFase2SepoliaExecute.s.sol --rpc-url sepolia --account niara-admin \
///     --broadcast
contract DeployFase2SepoliaExecute is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    string internal constant OUTPUT_PATH = "./script/output/fase2-sepolia.json";

    error RedeInvalida(uint256 chainIdAtual, uint256 chainIdEsperado);
    error ArquivoDeEnderecosNaoEncontrado(string caminho);

    struct Infra {
        ParticipacaoTokenFactory tokenFactory;
        EmissaoGateway gateway;
        RegistroInvestidorQualificado registro;
        OfertaCaptacaoFactory captacaoFactory;
        OfertaOrquestrador orquestrador;
    }

    function run() external {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert RedeInvalida(block.chainid, SEPOLIA_CHAIN_ID);
        if (!vm.isFile(OUTPUT_PATH)) revert ArquivoDeEnderecosNaoEncontrado(OUTPUT_PATH);

        Infra memory infra = _lerEnderecos();
        address emissorWallet = vm.envAddress("EMISSOR_WALLET_ADDRESS");

        vm.startBroadcast();
        address admin = msg.sender;

        _executarAgentePendente(infra, admin);
        infra.orquestrador.autorizarEmissor(emissorWallet);
        vm.stopBroadcast();

        _logResultados(infra, admin, emissorWallet);
    }

    function _lerEnderecos() internal returns (Infra memory infra) {
        string memory json = vm.readFile(OUTPUT_PATH);
        infra.tokenFactory = ParticipacaoTokenFactory(vm.parseJsonAddress(json, ".tokenFactory"));
        infra.gateway = EmissaoGateway(vm.parseJsonAddress(json, ".gateway"));
        infra.registro = RegistroInvestidorQualificado(vm.parseJsonAddress(json, ".registro"));
        infra.captacaoFactory = OfertaCaptacaoFactory(vm.parseJsonAddress(json, ".captacaoFactory"));
        infra.orquestrador = OfertaOrquestrador(vm.parseJsonAddress(json, ".orquestrador"));
    }

    /// @dev Idempotente: confere `hasRole` antes de cada `executeGrantRole` e pula se já
    /// concedido, em vez de deixar `_consumeAction` reverter com `ActionNotPending` numa segunda
    /// chamada. Se o timelock ainda não tiver decorrido, `executeGrantRole` reverte com
    /// `TimelockNotElapsed` (esperado, não é bug — ver CLAUDE.md).
    function _executarAgentePendente(Infra memory infra, address admin) internal {
        bytes32 agenteRole = infra.orquestrador.AGENTE_ROLE();

        _executarSeNecessario(infra.tokenFactory, agenteRole, address(infra.orquestrador));
        _executarSeNecessario(infra.gateway, agenteRole, address(infra.orquestrador));
        _executarSeNecessario(infra.captacaoFactory, agenteRole, address(infra.orquestrador));
        _executarSeNecessario(infra.orquestrador, agenteRole, admin);
        _executarSeNecessario(infra.registro, agenteRole, admin);
    }

    function _executarSeNecessario(TimelockedAccessControl alvo, bytes32 role, address account) internal {
        if (alvo.hasRole(role, account)) {
            console2.log("Ja concedido, pulando:", address(alvo));
            return;
        }
        alvo.executeGrantRole(role, account);
    }

    function _logResultados(Infra memory infra, address admin, address emissorWallet) internal view {
        console2.log("== DeployFase2SepoliaExecute ==");
        console2.log("Admin/agente (--account):", admin);
        console2.log("");
        console2.log("AGENTE_ROLE confirmado:");
        console2.log("  orquestrador em tokenFactory:", infra.tokenFactory.hasRole(infra.orquestrador.AGENTE_ROLE(), address(infra.orquestrador)));
        console2.log("  orquestrador em gateway:", infra.gateway.hasRole(infra.orquestrador.AGENTE_ROLE(), address(infra.orquestrador)));
        console2.log("  orquestrador em captacaoFactory:", infra.captacaoFactory.hasRole(infra.orquestrador.AGENTE_ROLE(), address(infra.orquestrador)));
        console2.log("  admin no orquestrador:", infra.orquestrador.hasRole(infra.orquestrador.AGENTE_ROLE(), admin));
        console2.log("  admin no registro (RegistroInvestidorQualificado):", infra.registro.hasRole(infra.orquestrador.AGENTE_ROLE(), admin));
        console2.log("");
        console2.log("Emissor autorizado (emissoresAutorizados == true esperado):", emissorWallet);
        console2.log("");
        console2.log(">> O emissor agora cria a propria oferta chamando criarOfertaCompleta em");
        console2.log(">> OfertaOrquestrador, da PROPRIA carteira (cast send --account <nome do emissor>).");
    }
}
