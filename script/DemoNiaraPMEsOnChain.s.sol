// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";

/// @title DemoNiaraPMEsOnChain
/// @notice Creates ONE new fundraising offering on Sepolia, fully reusing the infrastructure
/// deployed by `script/DemoSecundarioSetup.s.sol`; no new contract is deployed here. It also
/// executes (not just proposes) the pending `AGENTE_ROLE` on the 3 contracts it uses
/// (`EmissaoGateway`, `ParticipacaoTokenFactory`, `OfertaCaptacaoFactory`), replacing, only for
/// what this script needs, the original `DemoSecundarioPreparar.s.sol` (which also prepares the
/// secondary market's seller/buyer/lock-up, out of scope here). Requires `PRIVATE_KEY` to be the
/// same wallet the `AGENTE_ROLE` was PROPOSED to in `DemoSecundarioSetup.s.sol`, and the
/// timelock (1 real hour) to have passed; otherwise `executeGrantRole` reverts with
/// `TimelockNotElapsed` (expected behavior, not a bug; see CLAUDE.md, "Test results (Phase 1)").
/// @dev `criarOferta` uses the factory's current `transferPolicyPadrao` (`DenyAllTransferPolicy`,
/// confirmed at deploy): this offering's token starts with the secondary market off, with no
/// extra action here; migrating to `RestrictedTransferPolicy` remains available later via
/// `EmissaoGateway.proposeSetTransferPolicy`/`executeSetTransferPolicy`, if it ever makes sense
/// for this offering.
///
/// Parameters designed for a live demo with ONE single investor wallet
/// (`metaMinima`/`metaMaxima` are `MockBRL` amounts, the escrow currency, not share counts;
/// see `OfertaCaptacao.aportar`):
/// - precoPorCota (price per share) = 10 mBRL
/// - metaMinima (minimum target) = 100 mBRL (10 shares)
/// - metaMaxima (maximum target) = 200 mBRL (20 shares)
/// - tetoPorInvestidor (per-investor cap) = 200 mBRL, equal to the maximum target on purpose:
///   a single wallet can invest enough to close the offering alone without hitting the cap.
/// - prazo (deadline) = 180 days, a safety net. `OfertaCaptacao.encerrar()` allows early
///   closing (before the deadline) only when `totalArrecadado == metaMaxima` exactly; that is
///   the expected path in the live demo, not the deadline expiring.
///
/// Usage: fill in `.env` (deployer `PRIVATE_KEY` with `AGENTE_ROLE`, `RPC_URL`,
/// `EMISSOR_WALLET_ADDRESS`, `PROTOCOLO_WALLET_ADDRESS`) and run:
///   forge script script/DemoNiaraPMEsOnChain.s.sol --rpc-url sepolia --broadcast
contract DemoNiaraPMEsOnChain is Script {
    // Infrastructure redeployed on Sepolia (the original Phase 4 deployer key,
    // 0x101e8...871E, was lost; see script/DemoSecundarioSetup.s.sol, run again on
    // 2026-08-15 with a new wallet). Addresses checked directly against
    // script/output/demo-secundario.json and the on-chain broadcast (nonce/balance verified).
    address internal constant ISSUANCE_GATEWAY = 0x3082981ceE0068c0B9d6144edB1B0CEE14931a6E;
    address internal constant TOKEN_FACTORY = 0xD12808283E953E975f46799B1Eac0ad88BfbA697;
    address internal constant FUNDRAISING_FACTORY = 0x28BE1a83189CA6Bc8A163dC7bf659FAF09621dA7;
    address internal constant MOCK_BRL = 0xb99dda4e4d89f40324A7831970b8f37dBc35668F;

    uint256 internal constant MIN_TARGET = 100 ether;
    uint256 internal constant MAX_TARGET = 200 ether;
    uint256 internal constant PRICE_PER_SHARE = 10 ether;
    uint256 internal constant PER_INVESTOR_CAP = 200 ether;
    uint256 internal constant FEE_BPS = 0;
    uint256 internal constant DEADLINE_SECONDS = 180 days;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address emissorWallet = vm.envAddress("EMISSOR_WALLET_ADDRESS");
        address protocoloWallet = vm.envAddress("PROTOCOLO_WALLET_ADDRESS");

        vm.startBroadcast(deployerPk);
        _executeAgent(vm.addr(deployerPk));
        (address token, address oferta) = _createOfferingAndFundraising(emissorWallet, protocoloWallet);
        vm.stopBroadcast();

        console2.log("== DemoNiaraPMEsOnChain: offering created ==");
        console2.log("Token (ParticipacaoToken):", token);
        console2.log("Offering (OfertaCaptacao escrow):", oferta);
        console2.log("");
        console2.log("Copy these 3 addresses into niara-PMEs' .env.local:");
        console2.log("NEXT_PUBLIC_MOCKBRL_ADDRESS=", MOCK_BRL);
        console2.log("NEXT_PUBLIC_PARTICIPACAO_TOKEN_ADDRESS=", token);
        console2.log("NEXT_PUBLIC_OFERTA_CAPTACAO_ADDRESS=", oferta);
    }

    /// @dev Executes the AGENTE_ROLE proposed in DemoSecundarioSetup.s.sol (reverts with
    /// TimelockNotElapsed if the hour has not passed yet; expected, not a bug). Idempotent:
    /// if the role is already active (e.g. a previous run of this same script already
    /// executed it), it skips the call instead of reverting with ActionNotPending, so this
    /// script can run several times in a row to create several offerings, not just one.
    function _executeAgent(address deployer) internal {
        bytes32 role = keccak256("AGENTE_ROLE");
        address[3] memory targets = [ISSUANCE_GATEWAY, TOKEN_FACTORY, FUNDRAISING_FACTORY];
        for (uint256 i = 0; i < targets.length; i++) {
            (bool alreadyHas, bytes memory result) = targets[i].staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", role, deployer));
            if (alreadyHas && abi.decode(result, (bool))) continue;

            (bool ok,) = targets[i].call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, deployer));
            require(ok, "executeGrantRole failed (timelock not elapsed yet?)");
        }
    }

    /// @dev Operational sequence: criarOferta -> atestarCotas -> criarCaptacao -> registrarCaptacao.
    function _createOfferingAndFundraising(address emissorWallet, address protocoloWallet)
        internal
        returns (address token, address oferta)
    {
        ParticipacaoTokenFactory tokenFactory = ParticipacaoTokenFactory(TOKEN_FACTORY);
        EmissaoGateway gateway = EmissaoGateway(ISSUANCE_GATEWAY);
        OfertaCaptacaoFactory captacaoFactory = OfertaCaptacaoFactory(FUNDRAISING_FACTORY);

        token = tokenFactory.criarOferta(
            "Oferta Niara PMEs Demo",
            "nPME",
            "Empresa Demo Niara PMEs Ltda",
            keccak256(abi.encode("cnpj-demo-niara-pmes", block.timestamp)),
            "2026-DEMO-NIARA-PMES"
        );

        // metaMaxima in mBRL / precoPorCota gives the count, rescaled to the ERC-20's raw
        // 18-decimal unit (see CLAUDE.md, "Locked decisions — Phase 2").
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
