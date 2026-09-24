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

/// @title DeployFase2Sepolia
/// @notice Parte 1/2 do deploy real da Fase 2 (+ canal self-service `OfertaOrquestrador`) em
/// Sepolia. Único signatário: a conta resolvida por `--account` na linha de comando (ex.:
/// `niara-admin`) — SEM chave privada em variável de ambiente, nem com fallback, em lugar nenhum
/// deste arquivo. `vm.startBroadcast()` sem argumento deixa o Foundry resolver o signatário
/// sozinho; `msg.sender`, lido logo em seguida, já reflete esse endereço — conferido
/// empiricamente nesta sessão (`--account`/`--sender` fixam `msg.sender` para toda a execução do
/// script, mesmo antes do primeiro `startBroadcast`).
/// @dev Implanta a infraestrutura da Fase 2 (8 contratos) + `OfertaOrquestrador`, e PROPÕE (nunca
/// executa) `AGENTE_ROLE` em 5 relações: o `OfertaOrquestrador` nos três contratos que ele chama
/// (`ParticipacaoTokenFactory`, `EmissaoGateway`, `OfertaCaptacaoFactory`), o próprio signatário
/// no `OfertaOrquestrador` (para poder operar `autorizarEmissor` depois), e o próprio signatário
/// em `RegistroInvestidorQualificado` (para poder operar `definirQualificado` depois).
/// `RegistroInvestidorQualificado.ehQualificado` é lido, sem restrição de papel, dentro de
/// `OfertaCaptacao.aportar` — um aporte que fique dentro do `tetoPorInvestidor` funciona mesmo
/// sem nenhum investidor qualificado, mas qualificar o primeiro investidor (a única forma de
/// aportar ACIMA do teto — o próprio ponto da exceção de investidor qualificado da Resolução CVM
/// 88) depende de alguém deter `AGENTE_ROLE` ali. Agrupado nesta mesma leva de propostas porque a
/// concessão passa pelo mesmo timelock de 1h das outras quatro — pagar essa espera separadamente
/// depois custaria uma hora parada no meio do ciclo.
///
/// `forge script` simula TODO o `run()` antes de transmitir qualquer transação — se qualquer
/// chamada revertesse durante a simulação, NADA seria transmitido, nem os deploys. Como o
/// timelock real de 1h nunca decorre dentro de uma única execução contra uma rede de verdade
/// (`vm.warp` não afeta o relógio de uma chain real recebendo transações — ver CLAUDE.md), este
/// script só PROPÕE; `script/DeployFase2SepoliaExecute.s.sol`, rodado depois de >= 1h reais,
/// executa as 5 concessões pendentes e autoriza o primeiro emissor. Os 9 endereços implantados
/// são persistidos em `./script/output/fase2-sepolia.json` para o script de execução
/// reconstituir o mesmo estado sem depender de endereços digitados manualmente.
///
/// Uso:
///   PROTOCOLO_WALLET_ADDRESS=0x... TAXA_BPS_ORQUESTRADOR=100 \
///   TETO_POR_INVESTIDOR_ORQUESTRADOR=20000000000000000000000 \
///   forge script script/DeployFase2Sepolia.s.sol --rpc-url sepolia --account niara-admin \
///     --broadcast --verify
contract DeployFase2Sepolia is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 internal constant TIMELOCK_DELAY = 1 hours;
    string internal constant OUTPUT_PATH = "./script/output/fase2-sepolia.json";

    /// @notice Mesmo teto rígido de `OfertaCaptacao.TAXA_BPS_MAXIMA`/
    /// `OfertaOrquestrador.TAXA_BPS_MAXIMA` — conferido aqui antes de aceitar o valor do env, e
    /// exigido estritamente > 0: com taxa dormente, `OfertaCaptacao.liberarParaEmissor` pula a
    /// perna de transferência ao protocolo (`if (taxa > 0)`) e o split de receita nunca aparece
    /// no Etherscan, o que anularia o objetivo desta fase de provar o modelo de receita on-chain.
    uint256 internal constant TAXA_BPS_MAXIMA = 100;

    error RedeInvalida(uint256 chainIdAtual, uint256 chainIdEsperado);
    error TaxaBpsForaDoIntervalo(uint256 taxaBps);

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

    function run() external returns (Infra memory infra) {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert RedeInvalida(block.chainid, SEPOLIA_CHAIN_ID);

        address protocoloWallet = vm.envAddress("PROTOCOLO_WALLET_ADDRESS");
        uint256 taxaBpsOrquestrador = vm.envUint("TAXA_BPS_ORQUESTRADOR");
        uint256 tetoPorInvestidorOrquestrador = vm.envUint("TETO_POR_INVESTIDOR_ORQUESTRADOR");
        if (taxaBpsOrquestrador == 0 || taxaBpsOrquestrador > TAXA_BPS_MAXIMA) {
            revert TaxaBpsForaDoIntervalo(taxaBpsOrquestrador);
        }

        vm.startBroadcast();
        address admin = msg.sender;

        infra = _deployInfra(admin, protocoloWallet, taxaBpsOrquestrador, tetoPorInvestidorOrquestrador);
        _proporAgente(infra, admin);
        vm.stopBroadcast();

        _persistirEnderecos(infra);
        _logResultados(infra, admin);
    }

    function _deployInfra(
        address admin,
        address protocoloWallet,
        uint256 taxaBpsOrquestrador,
        uint256 tetoPorInvestidorOrquestrador
    ) internal returns (Infra memory infra) {
        infra.moeda = new MockBRL();
        infra.policy = new DenyAllTransferPolicy();
        infra.tokenImplementacao = new ParticipacaoToken();
        infra.gateway = new EmissaoGateway(admin, TIMELOCK_DELAY);
        infra.tokenFactory = new ParticipacaoTokenFactory(
            admin, address(infra.tokenImplementacao), address(infra.gateway), address(infra.policy), TIMELOCK_DELAY
        );
        infra.registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        infra.captacaoImplementacao = new OfertaCaptacao();
        infra.captacaoFactory = new OfertaCaptacaoFactory(
            admin,
            address(infra.captacaoImplementacao),
            address(infra.gateway),
            address(infra.registro),
            address(infra.moeda),
            TIMELOCK_DELAY
        );
        infra.orquestrador = new OfertaOrquestrador(
            admin,
            address(infra.tokenFactory),
            address(infra.gateway),
            address(infra.captacaoFactory),
            protocoloWallet,
            taxaBpsOrquestrador,
            tetoPorInvestidorOrquestrador,
            TIMELOCK_DELAY
        );
    }

    /// @dev Propõe (não executa) `AGENTE_ROLE` nas 5 relações — ver NatSpec do contrato.
    /// Contratos recém-implantados nesta mesma chamada nunca têm proposta pendente, então propor
    /// direto (sem checar `pendingActions` antes) é seguro.
    function _proporAgente(Infra memory infra, address admin) internal {
        bytes32 agenteRole = infra.orquestrador.AGENTE_ROLE();
        infra.tokenFactory.proposeGrantRole(agenteRole, address(infra.orquestrador));
        infra.gateway.proposeGrantRole(agenteRole, address(infra.orquestrador));
        infra.captacaoFactory.proposeGrantRole(agenteRole, address(infra.orquestrador));
        infra.orquestrador.proposeGrantRole(agenteRole, admin);
        infra.registro.proposeGrantRole(agenteRole, admin);
    }

    function _persistirEnderecos(Infra memory infra) internal {
        string memory objKey = "infra";
        vm.serializeAddress(objKey, "moeda", address(infra.moeda));
        vm.serializeAddress(objKey, "policy", address(infra.policy));
        vm.serializeAddress(objKey, "tokenImplementacao", address(infra.tokenImplementacao));
        vm.serializeAddress(objKey, "gateway", address(infra.gateway));
        vm.serializeAddress(objKey, "tokenFactory", address(infra.tokenFactory));
        vm.serializeAddress(objKey, "registro", address(infra.registro));
        vm.serializeAddress(objKey, "captacaoImplementacao", address(infra.captacaoImplementacao));
        vm.serializeAddress(objKey, "captacaoFactory", address(infra.captacaoFactory));
        string memory finalJson = vm.serializeAddress(objKey, "orquestrador", address(infra.orquestrador));
        vm.writeJson(finalJson, OUTPUT_PATH);
    }

    function _logResultados(Infra memory infra, address admin) internal view {
        console2.log("== DeployFase2Sepolia ==");
        console2.log("Admin/agente (--account):", admin);
        console2.log("");
        console2.log("== Enderecos implantados ==");
        console2.log("MockBRL:", address(infra.moeda));
        console2.log("DenyAllTransferPolicy:", address(infra.policy));
        console2.log("ParticipacaoToken (implementacao):", address(infra.tokenImplementacao));
        console2.log("EmissaoGateway:", address(infra.gateway));
        console2.log("ParticipacaoTokenFactory:", address(infra.tokenFactory));
        console2.log("RegistroInvestidorQualificado:", address(infra.registro));
        console2.log("OfertaCaptacao (implementacao):", address(infra.captacaoImplementacao));
        console2.log("OfertaCaptacaoFactory:", address(infra.captacaoFactory));
        console2.log("OfertaOrquestrador:", address(infra.orquestrador));
        console2.log("");
        console2.log("AGENTE_ROLE PROPOSTO (nao executado):");
        console2.log("  - orquestrador em tokenFactory, gateway e captacaoFactory");
        console2.log("  - admin no proprio orquestrador");
        console2.log("  - admin em registro (RegistroInvestidorQualificado)");
        console2.log("Enderecos salvos em:", OUTPUT_PATH);
        console2.log("");
        console2.log(">> Espere >= 1 hora de tempo REAL, entao rode DeployFase2SepoliaExecute.s.sol <<");
    }
}
