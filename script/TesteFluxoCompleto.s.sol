// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {OfertaCaptacao} from "../src/captacao/OfertaCaptacao.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";

/// @title TesteFluxoCompleto
/// @notice Script de validação (descartável) — cria uma oferta SEPARADA e pequena, própria
/// para teste, reaproveitando a mesma infra da oferta real de demo (ver
/// DemoNiaraPMEsOnChain.s.sol), e roda o ciclo inteiro com a carteira do deployer:
/// mint -> approve -> aportar (2x, testando acúmulo) -> encerrar (fechamento antecipado por
/// meta máxima exata) -> resgatarCotas -> liberarParaEmissor. NÃO toca na oferta real de demo
/// (`OfertaCaptacao` em 0x8390...C57c6) — usa um token/oferta novos, criados aqui.
/// @dev Rodar só para validar a lógica ponta a ponta antes de uma demo ao vivo pela UI. Não faz
/// parte do fluxo "oficial" de demo (esse é `DemoNiaraPMEsOnChain.s.sol`).
contract TesteFluxoCompleto is Script {
    address internal constant EMISSAO_GATEWAY = 0x3082981ceE0068c0B9d6144edB1B0CEE14931a6E;
    address internal constant TOKEN_FACTORY = 0xD12808283E953E975f46799B1Eac0ad88BfbA697;
    address internal constant CAPTACAO_FACTORY = 0x28BE1a83189CA6Bc8A163dC7bf659FAF09621dA7;
    address internal constant MOCK_BRL = 0xb99dda4e4d89f40324A7831970b8f37dBc35668F;

    uint256 internal constant META_MINIMA = 10 ether;
    uint256 internal constant META_MAXIMA = 20 ether;
    uint256 internal constant PRECO_POR_COTA = 10 ether;
    uint256 internal constant TETO_POR_INVESTIDOR = 20 ether;
    uint256 internal constant APORTE_1 = 10 ether;
    uint256 internal constant APORTE_2 = 10 ether;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address emissorWallet = vm.envAddress("EMISSOR_WALLET_ADDRESS");
        address protocoloWallet = vm.envAddress("PROTOCOLO_WALLET_ADDRESS");

        MockBRL moeda = MockBRL(MOCK_BRL);

        vm.startBroadcast(deployerPk);

        (address token, address oferta) = _criarOfertaTeste(emissorWallet, protocoloWallet);

        moeda.mint(deployer, APORTE_1 + APORTE_2);
        moeda.approve(oferta, APORTE_1 + APORTE_2);

        OfertaCaptacao(oferta).aportar(APORTE_1);
        console2.log("Aporte 1 ok. totalArrecadado:", OfertaCaptacao(oferta).totalArrecadado());

        OfertaCaptacao(oferta).aportar(APORTE_2);
        console2.log("Aporte 2 ok. totalArrecadado:", OfertaCaptacao(oferta).totalArrecadado());

        OfertaCaptacao(oferta).encerrar();
        console2.log("Encerrada. estado (1=Sucesso):", uint256(OfertaCaptacao(oferta).estado()));

        OfertaCaptacao(oferta).resgatarCotas();
        console2.log("Cotas resgatadas. Saldo ParticipacaoToken:", ParticipacaoToken(token).balanceOf(deployer));

        OfertaCaptacao(oferta).liberarParaEmissor();
        console2.log("Liberado ao emissor. Saldo mBRL emissor:", moeda.balanceOf(emissorWallet));
        console2.log("Saldo mBRL residual no escrow (deve ser 0):", moeda.balanceOf(oferta));

        vm.stopBroadcast();

        console2.log("");
        console2.log("== TesteFluxoCompleto: oferta de TESTE (descartavel) ==");
        console2.log("Token teste:", token);
        console2.log("Oferta teste:", oferta);
    }

    function _criarOfertaTeste(address emissorWallet, address protocoloWallet)
        internal
        returns (address token, address oferta)
    {
        ParticipacaoTokenFactory tokenFactory = ParticipacaoTokenFactory(TOKEN_FACTORY);
        EmissaoGateway gateway = EmissaoGateway(EMISSAO_GATEWAY);
        OfertaCaptacaoFactory captacaoFactory = OfertaCaptacaoFactory(CAPTACAO_FACTORY);

        token = tokenFactory.criarOferta(
            "Teste Fluxo Completo",
            "nTST",
            "Empresa Teste Ltda",
            keccak256(abi.encode("cnpj-teste-fluxo", block.timestamp)),
            "TESTE-DESCARTAVEL"
        );

        gateway.atestarCotas(token, (META_MAXIMA / PRECO_POR_COTA) * 1 ether);

        oferta = captacaoFactory.criarCaptacao(
            token,
            META_MINIMA,
            META_MAXIMA,
            PRECO_POR_COTA,
            block.timestamp + 1 days,
            TETO_POR_INVESTIDOR,
            0,
            emissorWallet,
            protocoloWallet
        );

        gateway.registrarCaptacao(token, oferta);
    }
}
