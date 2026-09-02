// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";

/// @title DemoOfertaComTaxa
/// @notice Cria UMA nova oferta de captação em Sepolia, igual a `DemoNiaraPMEsOnChain.s.sol`, mas
/// com `taxaBps` diferente de zero — as 10 ofertas PMEs existentes têm `taxaBps` gravado
/// imutavelmente em `0` na criação (sem função de alterar depois, mesma limitação já documentada
/// para `emissorWallet`), então não é possível "ligar" taxa nelas retroativamente. Esta é uma
/// oferta de TESTE dedicada só para demonstrar receita real de taxa no painel `/socios` — não faz
/// parte do catálogo de 10 PMEs (`mock/ofertasOnChain.ts` no frontend) e não deve ser adicionada
/// lá; ela aparece só no seletor genérico multi-oferta de `/investir/onchain`, como um índice a
/// mais em `NEXT_PUBLIC_OFERTAS_ONCHAIN`.
/// @dev `taxaBps = 100` (1%) — o teto rígido de `OfertaCaptacao.TAXA_BPS_MAXIMA`; não hardcodar um
/// valor maior, o `initialize()` reverteria com `TaxaExcedeMaximo`. Reaproveita por completo a
/// infraestrutura já implantada (nenhum contrato novo) e o mesmo padrão de "executar o
/// AGENTE_ROLE pendente antes de operar" de `DemoNiaraPMEsOnChain.s.sol`.
///
/// Diferente das 10 ofertas PMEs, `PROTOCOLO_WALLET_ADDRESS` aqui deve ser uma carteira DEDICADA
/// só para receber taxa — separada da carteira do deployer/agente — para o painel de sócios poder
/// mostrar de forma didática "isso é o caixa da Niara". Essa carteira só recebe MockBRL, nunca
/// assina nada, então não precisa de Sepolia ETH para gas.
///
/// Parâmetros iguais aos de `DemoNiaraPMEsOnChain.s.sol` (mesma escala/convenção, só a taxa muda):
/// - precoPorCota = 10 mBRL
/// - metaMinima = 100 mBRL (10 cotas)
/// - metaMaxima = 200 mBRL (20 cotas)
/// - tetoPorInvestidor = 200 mBRL — uma única carteira consegue fechar a oferta sozinha.
/// - prazo = 180 dias — rede de segurança; o caminho esperado é fechar antecipado ao atingir a
///   meta máxima exata, via `OfertaCaptacao.encerrar()`.
///
/// Uso: preencher `.env` (`PRIVATE_KEY` do deployer com `AGENTE_ROLE` já executado, `RPC_URL`,
/// `EMISSOR_WALLET_ADDRESS`, `PROTOCOLO_WALLET_ADDRESS` apontando para a carteira dedicada de
/// taxa) e rodar:
///   forge script script/DemoOfertaComTaxa.s.sol --rpc-url sepolia --broadcast
contract DemoOfertaComTaxa is Script {
    // Mesma infraestrutura redeployada em Sepolia usada por DemoNiaraPMEsOnChain.s.sol —
    // conferida contra script/output/demo-secundario.json antes de fixar aqui.
    address internal constant EMISSAO_GATEWAY = 0x3082981ceE0068c0B9d6144edB1B0CEE14931a6E;
    address internal constant TOKEN_FACTORY = 0xD12808283E953E975f46799B1Eac0ad88BfbA697;
    address internal constant CAPTACAO_FACTORY = 0x28BE1a83189CA6Bc8A163dC7bf659FAF09621dA7;
    address internal constant MOCK_BRL = 0xb99dda4e4d89f40324A7831970b8f37dBc35668F;

    uint256 internal constant META_MINIMA = 100 ether;
    uint256 internal constant META_MAXIMA = 200 ether;
    uint256 internal constant PRECO_POR_COTA = 10 ether;
    uint256 internal constant TETO_POR_INVESTIDOR = 200 ether;
    // Teto rígido de OfertaCaptacao.TAXA_BPS_MAXIMA — não subir sem checar aquela constante antes.
    uint256 internal constant TAXA_BPS = 100;
    uint256 internal constant PRAZO_SEGUNDOS = 180 days;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address emissorWallet = vm.envAddress("EMISSOR_WALLET_ADDRESS");
        address protocoloWallet = vm.envAddress("PROTOCOLO_WALLET_ADDRESS");

        vm.startBroadcast(deployerPk);
        _executarAgente(vm.addr(deployerPk));
        (address token, address oferta) = _criarOfertaECaptacao(emissorWallet, protocoloWallet);
        vm.stopBroadcast();

        console2.log("== DemoOfertaComTaxa: oferta de teste com taxa criada ==");
        console2.log("Token (ParticipacaoToken):", token);
        console2.log("Oferta (escrow OfertaCaptacao):", oferta);
        console2.log("taxaBps:", TAXA_BPS);
        console2.log("protocoloWallet (carteira dedicada de taxa):", protocoloWallet);
        console2.log("");
        console2.log("Adicione este par ao NEXT_PUBLIC_OFERTAS_ONCHAIN existente no .env.local do niara-PMEs,");
        console2.log("separado por ';' dos pares ja existentes (NAO substitua os 10 das PMEs):");
        console2.log("token:oferta =>");
        console2.log(token, oferta);
    }

    /// @dev Mesma lógica idempotente de DemoNiaraPMEsOnChain.s.sol — reverte com
    /// TimelockNotElapsed se a 1h de timelock do AGENTE_ROLE ainda não tiver decorrido (esperado,
    /// não é bug); pula a chamada se o papel já estiver ativo.
    function _executarAgente(address deployer) internal {
        bytes32 role = keccak256("AGENTE_ROLE");
        address[3] memory alvos = [EMISSAO_GATEWAY, TOKEN_FACTORY, CAPTACAO_FACTORY];
        for (uint256 i = 0; i < alvos.length; i++) {
            (bool jaTem, bytes memory dados) =
                alvos[i].staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", role, deployer));
            if (jaTem && abi.decode(dados, (bool))) continue;

            (bool ok,) = alvos[i].call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, deployer));
            require(ok, "executeGrantRole falhou (timelock ainda nao decorrido?)");
        }
    }

    function _criarOfertaECaptacao(address emissorWallet, address protocoloWallet)
        internal
        returns (address token, address oferta)
    {
        ParticipacaoTokenFactory tokenFactory = ParticipacaoTokenFactory(TOKEN_FACTORY);
        EmissaoGateway gateway = EmissaoGateway(EMISSAO_GATEWAY);
        OfertaCaptacaoFactory captacaoFactory = OfertaCaptacaoFactory(CAPTACAO_FACTORY);

        token = tokenFactory.criarOferta(
            "Oferta Niara PMEs Demo - Com Taxa",
            "nTAXA",
            "Empresa Demo Niara PMEs (Taxa) Ltda",
            keccak256(abi.encode("cnpj-demo-niara-pmes-taxa", block.timestamp)),
            "2026-DEMO-NIARA-PMES-TAXA"
        );

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
