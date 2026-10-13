// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {OfertaCaptacao} from "../src/captacao/OfertaCaptacao.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";

/// @title TesteFluxoCompleto (full flow test)
/// @notice Validation script (throwaway): creates a SEPARATE, small offering, just for
/// testing, reusing the same infra as the real demo offering (see
/// DemoNiaraPMEsOnChain.s.sol), and runs the whole cycle with the deployer's wallet:
/// mint -> approve -> aportar (2x, testing accumulation) -> encerrar (early close at the
/// exact maximum target) -> resgatarCotas -> liberarParaEmissor. It does NOT touch the real
/// demo offering (`OfertaCaptacao` at 0x8390...C57c6); it uses a new token/offering created here.
/// @dev Run only to validate the logic end to end before a live demo through the UI. It is not
/// part of the "official" demo flow (that is `DemoNiaraPMEsOnChain.s.sol`).
contract TesteFluxoCompleto is Script {
    address internal constant ISSUANCE_GATEWAY = 0x3082981ceE0068c0B9d6144edB1B0CEE14931a6E;
    address internal constant TOKEN_FACTORY = 0xD12808283E953E975f46799B1Eac0ad88BfbA697;
    address internal constant FUNDRAISING_FACTORY = 0x28BE1a83189CA6Bc8A163dC7bf659FAF09621dA7;
    address internal constant MOCK_BRL = 0xb99dda4e4d89f40324A7831970b8f37dBc35668F;

    uint256 internal constant MIN_TARGET = 10 ether;
    uint256 internal constant MAX_TARGET = 20 ether;
    uint256 internal constant PRICE_PER_SHARE = 10 ether;
    uint256 internal constant PER_INVESTOR_CAP = 20 ether;
    uint256 internal constant INVESTMENT_1 = 10 ether;
    uint256 internal constant INVESTMENT_2 = 10 ether;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address emissorWallet = vm.envAddress("EMISSOR_WALLET_ADDRESS");
        address protocoloWallet = vm.envAddress("PROTOCOLO_WALLET_ADDRESS");

        MockBRL moeda = MockBRL(MOCK_BRL);

        vm.startBroadcast(deployerPk);

        (address token, address oferta) = _createTestOffering(emissorWallet, protocoloWallet);

        moeda.mint(deployer, INVESTMENT_1 + INVESTMENT_2);
        moeda.approve(oferta, INVESTMENT_1 + INVESTMENT_2);

        OfertaCaptacao(oferta).aportar(INVESTMENT_1);
        console2.log("Aporte 1 ok. totalArrecadado:", OfertaCaptacao(oferta).totalArrecadado());

        OfertaCaptacao(oferta).aportar(INVESTMENT_2);
        console2.log("Aporte 2 ok. totalArrecadado:", OfertaCaptacao(oferta).totalArrecadado());

        OfertaCaptacao(oferta).encerrar();
        console2.log("Encerrada. estado (1=Sucesso):", uint256(OfertaCaptacao(oferta).estado()));

        OfertaCaptacao(oferta).resgatarCotas();
        console2.log("Shares redeemed. ParticipacaoToken balance:", ParticipacaoToken(token).balanceOf(deployer));

        OfertaCaptacao(oferta).liberarParaEmissor();
        console2.log("Released to the issuer. Issuer mBRL balance:", moeda.balanceOf(emissorWallet));
        console2.log("Residual mBRL in escrow (should be 0):", moeda.balanceOf(oferta));

        vm.stopBroadcast();

        console2.log("");
        console2.log("== TesteFluxoCompleto: TEST offering (throwaway) ==");
        console2.log("Test token:", token);
        console2.log("Test offering:", oferta);
    }

    function _createTestOffering(address emissorWallet, address protocoloWallet)
        internal
        returns (address token, address oferta)
    {
        ParticipacaoTokenFactory tokenFactory = ParticipacaoTokenFactory(TOKEN_FACTORY);
        EmissaoGateway gateway = EmissaoGateway(ISSUANCE_GATEWAY);
        OfertaCaptacaoFactory captacaoFactory = OfertaCaptacaoFactory(FUNDRAISING_FACTORY);

        token = tokenFactory.criarOferta(
            "Teste Fluxo Completo",
            "nTST",
            "Empresa Teste Ltda",
            keccak256(abi.encode("cnpj-teste-fluxo", block.timestamp)),
            "TESTE-DESCARTAVEL"
        );

        gateway.atestarCotas(token, (MAX_TARGET / PRICE_PER_SHARE) * 1 ether);

        oferta = captacaoFactory.criarCaptacao(
            token,
            MIN_TARGET,
            MAX_TARGET,
            PRICE_PER_SHARE,
            block.timestamp + 1 days,
            PER_INVESTOR_CAP,
            0,
            emissorWallet,
            protocoloWallet
        );

        gateway.registrarCaptacao(token, oferta);
    }
}
