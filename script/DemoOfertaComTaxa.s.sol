// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";

/// @title DemoOfertaComTaxa (offering with fee)
/// @notice Creates ONE new fundraising offering on Sepolia, like `DemoNiaraPMEsOnChain.s.sol`, but
/// with a non-zero `taxaBps`. The 10 existing SME offerings have `taxaBps` written immutably
/// as `0` at creation (there is no function to change it later, the same limitation already
/// documented for `emissorWallet`), so fees cannot be "turned on" for them retroactively. This
/// is a dedicated TEST offering, only to demonstrate real fee revenue in the `/socios` panel. It
/// is not part of the catalog of 10 SMEs (`mock/ofertasOnChain.ts` in the frontend) and must not
/// be added there; it only shows up in the generic multi-offering selector of
/// `/investir/onchain`, as one more index in `NEXT_PUBLIC_OFERTAS_ONCHAIN`.
/// @dev `taxaBps = 100` (1%), the hard cap of `OfertaCaptacao.TAXA_BPS_MAXIMA`; do not hardcode a
/// larger value, `initialize()` would revert with `TaxaExcedeMaximo`. Fully reuses the
/// already-deployed infrastructure (no new contract) and the same "execute the pending
/// AGENTE_ROLE before operating" pattern as `DemoNiaraPMEsOnChain.s.sol`.
///
/// Unlike the 10 SME offerings, `PROTOCOLO_WALLET_ADDRESS` here must be a wallet DEDICATED
/// only to receiving fees, separate from the deployer/agent wallet, so the partners' panel can
/// show clearly "this is Niara's cash". That wallet only receives MockBRL and never signs
/// anything, so it does not need Sepolia ETH for gas.
///
/// Same parameters as `DemoNiaraPMEsOnChain.s.sol` (same scale/convention; only the fee changes):
/// - precoPorCota = 10 mBRL
/// - metaMinima = 100 mBRL (10 shares)
/// - metaMaxima = 200 mBRL (20 shares)
/// - tetoPorInvestidor = 200 mBRL: a single wallet can close the offering alone.
/// - prazo = 180 days, a safety net; the expected path is closing early when the exact
///   maximum target is reached, via `OfertaCaptacao.encerrar()`.
///
/// Usage: fill in `.env` (deployer `PRIVATE_KEY` with `AGENTE_ROLE` already executed, `RPC_URL`,
/// `EMISSOR_WALLET_ADDRESS`, `PROTOCOLO_WALLET_ADDRESS` pointing at the dedicated fee wallet)
/// and run:
///   forge script script/DemoOfertaComTaxa.s.sol --rpc-url sepolia --broadcast
contract DemoOfertaComTaxa is Script {
    // Same redeployed Sepolia infrastructure used by DemoNiaraPMEsOnChain.s.sol,
    // checked against script/output/demo-secundario.json before pinning it here.
    address internal constant ISSUANCE_GATEWAY = 0x3082981ceE0068c0B9d6144edB1B0CEE14931a6E;
    address internal constant TOKEN_FACTORY = 0xD12808283E953E975f46799B1Eac0ad88BfbA697;
    address internal constant FUNDRAISING_FACTORY = 0x28BE1a83189CA6Bc8A163dC7bf659FAF09621dA7;
    address internal constant MOCK_BRL = 0xb99dda4e4d89f40324A7831970b8f37dBc35668F;

    uint256 internal constant MIN_TARGET = 100 ether;
    uint256 internal constant MAX_TARGET = 200 ether;
    uint256 internal constant PRICE_PER_SHARE = 10 ether;
    uint256 internal constant PER_INVESTOR_CAP = 200 ether;
    // Hard cap of OfertaCaptacao.TAXA_BPS_MAXIMA; do not raise it without checking that constant first.
    uint256 internal constant FEE_BPS = 100;
    uint256 internal constant DEADLINE_SECONDS = 180 days;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address emissorWallet = vm.envAddress("EMISSOR_WALLET_ADDRESS");
        address protocoloWallet = vm.envAddress("PROTOCOLO_WALLET_ADDRESS");

        vm.startBroadcast(deployerPk);
        _executeAgent(vm.addr(deployerPk));
        (address token, address oferta) = _createOfferingAndFundraising(emissorWallet, protocoloWallet);
        vm.stopBroadcast();

        console2.log("== DemoOfertaComTaxa: test offering with fee created ==");
        console2.log("Token (ParticipacaoToken):", token);
        console2.log("Offering (OfertaCaptacao escrow):", oferta);
        console2.log("taxaBps:", FEE_BPS);
        console2.log("protocoloWallet (dedicated fee wallet):", protocoloWallet);
        console2.log("");
        console2.log("Add this pair to the existing NEXT_PUBLIC_OFERTAS_ONCHAIN in niara-PMEs' .env.local,");
        console2.log("separated by ';' from the existing pairs (do NOT replace the 10 SME ones):");
        console2.log("token:offering =>");
        console2.log(token, oferta);
    }

    /// @dev Same idempotent logic as DemoNiaraPMEsOnChain.s.sol: reverts with
    /// TimelockNotElapsed if the AGENTE_ROLE's 1h timelock has not passed yet (expected,
    /// not a bug); skips the call if the role is already active.
    function _executeAgent(address deployer) internal {
        bytes32 role = keccak256("AGENTE_ROLE");
        address[3] memory targets = [ISSUANCE_GATEWAY, TOKEN_FACTORY, FUNDRAISING_FACTORY];
        for (uint256 i = 0; i < targets.length; i++) {
            (bool alreadyHas, bytes memory result) =
                targets[i].staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", role, deployer));
            if (alreadyHas && abi.decode(result, (bool))) continue;

            (bool ok,) = targets[i].call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, deployer));
            require(ok, "executeGrantRole failed (timelock not elapsed yet?)");
        }
    }

    function _createOfferingAndFundraising(address emissorWallet, address protocoloWallet)
        internal
        returns (address token, address oferta)
    {
        ParticipacaoTokenFactory tokenFactory = ParticipacaoTokenFactory(TOKEN_FACTORY);
        EmissaoGateway gateway = EmissaoGateway(ISSUANCE_GATEWAY);
        OfertaCaptacaoFactory captacaoFactory = OfertaCaptacaoFactory(FUNDRAISING_FACTORY);

        token = tokenFactory.criarOferta(
            "Oferta Niara PMEs Demo - Com Taxa",
            "nTAXA",
            "Empresa Demo Niara PMEs (Taxa) Ltda",
            keccak256(abi.encode("cnpj-demo-niara-pmes-taxa", block.timestamp)),
            "2026-DEMO-NIARA-PMES-TAXA"
        );

        gateway.atestarCotas(token, (MAX_TARGET / PRICE_PER_SHARE) * 1 ether);

        oferta = captacaoFactory.criarCaptacao(
            token,
            MIN_TARGET,
            MAX_TARGET,
            PRICE_PER_SHARE,
            block.timestamp + DEADLINE_SECONDS,
            PER_INVESTOR_CAP,
            FEE_BPS,
            emissorWallet,
            protocoloWallet
        );

        gateway.registrarCaptacao(token, oferta);
    }
}
