// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";

/// @title DemoNiaraPMEsOnChain
/// @notice Cria UMA nova oferta de captação em Sepolia, reaproveitando por completo a
/// infraestrutura implantada por `script/DemoSecundarioSetup.s.sol` — nenhum contrato novo é
/// implantado aqui. Também executa (não só propõe) o `AGENTE_ROLE` pendente nos 3 contratos que
/// usa (`EmissaoGateway`, `ParticipacaoTokenFactory`, `OfertaCaptacaoFactory`) — substituindo,
/// só para o que este script precisa, o `DemoSecundarioPreparar.s.sol` original (que também
/// prepara vendedor/comprador/lockup do mercado secundário, fora de escopo aqui). Exige que
/// `PRIVATE_KEY` seja a mesma carteira para a qual o `AGENTE_ROLE` foi PROPOSTO em
/// `DemoSecundarioSetup.s.sol`, e que o timelock (1h real) já tenha decorrido — do contrário
/// `executeGrantRole` reverte com `TimelockNotElapsed` (comportamento esperado, não é bug; ver
/// CLAUDE.md, "Resultados de teste (Fase 1)").
/// @dev `criarOferta` usa a `transferPolicyPadrao` vigente na factory (`DenyAllTransferPolicy`,
/// confirmado no deploy) — o token desta oferta nasce com secundário desligado, sem nenhuma
/// ação extra aqui; migrar para `RestrictedTransferPolicy` fica disponível depois via
/// `EmissaoGateway.proposeSetTransferPolicy`/`executeSetTransferPolicy`, se um dia fizer sentido
/// para esta oferta.
///
/// Parâmetros pensados para uma demonstração ao vivo com UMA única carteira de investidor
/// (`metaMinima`/`metaMaxima` são valores de `MockBRL`, a moeda do escrow — não contagem de
/// cotas, ver `OfertaCaptacao.aportar`):
/// - precoPorCota = 10 mBRL
/// - metaMinima = 100 mBRL (10 cotas)
/// - metaMaxima = 200 mBRL (20 cotas)
/// - tetoPorInvestidor = 200 mBRL — igual à meta máxima, de propósito: uma única carteira
///   consegue aportar o suficiente para fechar a oferta sozinha, sem esbarrar no teto.
/// - prazo = 180 dias — rede de segurança. `OfertaCaptacao.encerrar()` permite fechamento
///   antecipado (antes do prazo) só quando `totalArrecadado == metaMaxima` exatamente; é esse o
///   caminho esperado na demo ao vivo, não a expiração do prazo.
///
/// Uso: preencher `.env` (`PRIVATE_KEY` do deployer com `AGENTE_ROLE`, `RPC_URL`,
/// `EMISSOR_WALLET_ADDRESS`, `PROTOCOLO_WALLET_ADDRESS`) e rodar:
///   forge script script/DemoNiaraPMEsOnChain.s.sol --rpc-url sepolia --broadcast
contract DemoNiaraPMEsOnChain is Script {
    // Infraestrutura redeployada em Sepolia (chave original do deployer da Fase 4,
    // 0x101e8...871E, foi perdida — ver script/DemoSecundarioSetup.s.sol, rodado de novo em
    // 2026-08-15 com uma carteira nova). Endereços conferidos diretamente contra
    // script/output/demo-secundario.json e o broadcast on-chain (nonce/saldo verificados).
    address internal constant EMISSAO_GATEWAY = 0x3082981ceE0068c0B9d6144edB1B0CEE14931a6E;
    address internal constant TOKEN_FACTORY = 0xD12808283E953E975f46799B1Eac0ad88BfbA697;
    address internal constant CAPTACAO_FACTORY = 0x28BE1a83189CA6Bc8A163dC7bf659FAF09621dA7;
    address internal constant MOCK_BRL = 0xb99dda4e4d89f40324A7831970b8f37dBc35668F;

    uint256 internal constant META_MINIMA = 100 ether;
    uint256 internal constant META_MAXIMA = 200 ether;
    uint256 internal constant PRECO_POR_COTA = 10 ether;
    uint256 internal constant TETO_POR_INVESTIDOR = 200 ether;
    uint256 internal constant TAXA_BPS = 0;
    uint256 internal constant PRAZO_SEGUNDOS = 180 days;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address emissorWallet = vm.envAddress("EMISSOR_WALLET_ADDRESS");
        address protocoloWallet = vm.envAddress("PROTOCOLO_WALLET_ADDRESS");

        vm.startBroadcast(deployerPk);
        _executarAgente(vm.addr(deployerPk));
        (address token, address oferta) = _criarOfertaECaptacao(emissorWallet, protocoloWallet);
        vm.stopBroadcast();

        console2.log("== DemoNiaraPMEsOnChain: oferta criada ==");
        console2.log("Token (ParticipacaoToken):", token);
        console2.log("Oferta (escrow OfertaCaptacao):", oferta);
        console2.log("");
        console2.log("Copie estes 3 enderecos para o .env.local do niara-PMEs:");
        console2.log("NEXT_PUBLIC_MOCKBRL_ADDRESS=", MOCK_BRL);
        console2.log("NEXT_PUBLIC_PARTICIPACAO_TOKEN_ADDRESS=", token);
        console2.log("NEXT_PUBLIC_OFERTA_CAPTACAO_ADDRESS=", oferta);
    }

    /// @dev Executa o AGENTE_ROLE proposto em DemoSecundarioSetup.s.sol (reverte com
    /// TimelockNotElapsed se a 1h ainda não tiver decorrido — esperado, não é bug). Idempotente:
    /// se o papel já estiver ativo (ex.: uma execução anterior deste mesmo script já o
    /// executou), pula a chamada em vez de reverter com ActionNotPending — permite rodar este
    /// script várias vezes seguidas para criar várias ofertas, não só uma.
    function _executarAgente(address deployer) internal {
        bytes32 role = keccak256("AGENTE_ROLE");
        address[3] memory alvos = [EMISSAO_GATEWAY, TOKEN_FACTORY, CAPTACAO_FACTORY];
        for (uint256 i = 0; i < alvos.length; i++) {
            (bool jaTem, bytes memory dados) = alvos[i].staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", role, deployer));
            if (jaTem && abi.decode(dados, (bool))) continue;

            (bool ok,) = alvos[i].call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, deployer));
            require(ok, "executeGrantRole falhou (timelock ainda nao decorrido?)");
        }
    }

    /// @dev Sequência operacional: criarOferta -> atestarCotas -> criarCaptacao -> registrarCaptacao.
    function _criarOfertaECaptacao(address emissorWallet, address protocoloWallet)
        internal
        returns (address token, address oferta)
    {
        ParticipacaoTokenFactory tokenFactory = ParticipacaoTokenFactory(TOKEN_FACTORY);
        EmissaoGateway gateway = EmissaoGateway(EMISSAO_GATEWAY);
        OfertaCaptacaoFactory captacaoFactory = OfertaCaptacaoFactory(CAPTACAO_FACTORY);

        token = tokenFactory.criarOferta(
            "Oferta Niara PMEs Demo",
            "nPME",
            "Empresa Demo Niara PMEs Ltda",
            keccak256(abi.encode("cnpj-demo-niara-pmes", block.timestamp)),
            "2026-DEMO-NIARA-PMES"
        );

        // metaMaxima em mBRL / precoPorCota da contagem, reescalado para a unidade bruta de 18
        // casas do ERC-20 (ver CLAUDE.md, "Decisoes travadas — Fase 2").
        gateway.atestarCotas(token, (META_MAXIMA / PRECO_POR_COTA) * 1 ether);

        oferta = captacaoFactory.criarCaptacao(
            token,
            META_MINIMA,
            META_MAXIMA,
            PRECO_POR_COTA,
            block.timestamp + PRAZO_SEGUNDOS,
            TETO_POR_INVESTIDOR,
            TAXA_BPS,
            emissorWallet,
            protocoloWallet
        );

        gateway.registrarCaptacao(token, oferta);
    }
}
