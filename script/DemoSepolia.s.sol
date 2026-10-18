// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {ParticipacaoTokenFactory} from "../src/token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {OfertaCaptacao} from "../src/captacao/OfertaCaptacao.sol";
import {OfertaCaptacaoFactory} from "../src/captacao/OfertaCaptacaoFactory.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";

/// @title DemoSepolia
/// @notice Part 2/2 of the public Phase 2 demo on Sepolia. Run only after
/// `DemoSepolia_Setup.s.sol` and after >= 1h of REAL time has passed (see that script's
/// NatSpec on why the timelock cannot be skipped on a real network). Reads the addresses
/// deployed in `./script/output/demo-sepolia.json`, executes the pending `AGENTE_ROLE` grant,
/// and runs the full cycle of a fully subscribed fundraising: creates the offering, attests
/// shares, creates the fundraising, registers it in the gateway, the two investors invest up
/// to the maximum target (early close, without waiting for the deadline), closes it, both
/// redeem shares and the funds are released to the issuer.
/// @dev Demo offering parameters are fixed in this constant; see the demo instruction
/// (Sepolia): precoPorCota=100 mBRL, metaMinima=3000 mBRL, metaMaxima=5000 mBRL,
/// tetoPorInvestidor=20000 mBRL, taxaBps=0, investments 3000+2000=5000=metaMaxima (50 shares).
contract DemoSepolia is Script {
    string internal constant OUTPUT_PATH = "./script/output/demo-sepolia.json";

    uint256 internal constant MIN_TARGET = 3_000 ether;
    uint256 internal constant MAX_TARGET = 5_000 ether;
    uint256 internal constant PRICE_PER_SHARE = 100 ether;
    uint256 internal constant PER_INVESTOR_CAP = 20_000 ether;
    uint256 internal constant FEE_BPS = 0;
    uint256 internal constant DEADLINE_SECONDS = 1 days;

    uint256 internal constant INVESTOR1_INVESTMENT = 3_000 ether;
    uint256 internal constant INVESTOR2_INVESTMENT = 2_000 ether;

    uint256 internal constant INVESTOR_MIN_ETH_BALANCE = 0.01 ether;
    uint256 internal constant INVESTOR_ETH_TOP_UP = 0.02 ether;

    struct Config {
        uint256 deployerPk;
        uint256 investor1Pk;
        uint256 investor2Pk;
        address deployer;
        address investor1;
        address investor2;
        address issuerWallet;
        address protocolWallet;
    }

    struct Infra {
        MockBRL currency;
        EmissaoGateway gateway;
        ParticipacaoTokenFactory tokenFactory;
        OfertaCaptacaoFactory fundraisingFactory;
    }

    function run() external {
        Config memory cfg = _readConfig();
        Infra memory infra = _readAddresses();

        vm.startBroadcast(cfg.deployerPk);
        _executeAgent(infra, cfg.deployer);
        vm.stopBroadcast();

        vm.startBroadcast(cfg.deployerPk);
        (address token, address oferta) = _createOfferingAndFundraising(infra, cfg);
        infra.currency.mint(cfg.investor1, INVESTOR1_INVESTMENT);
        infra.currency.mint(cfg.investor2, INVESTOR2_INVESTMENT);
        _topUpEthIfNeeded(cfg.investor1);
        _topUpEthIfNeeded(cfg.investor2);
        vm.stopBroadcast();

        _invest(cfg.investor1Pk, infra.currency, oferta, INVESTOR1_INVESTMENT);
        _invest(cfg.investor2Pk, infra.currency, oferta, INVESTOR2_INVESTMENT);

        vm.startBroadcast(cfg.deployerPk);
        OfertaCaptacao(oferta).encerrar();
        vm.stopBroadcast();

        vm.startBroadcast(cfg.investor1Pk);
        OfertaCaptacao(oferta).resgatarCotas();
        vm.stopBroadcast();

        vm.startBroadcast(cfg.investor2Pk);
        OfertaCaptacao(oferta).resgatarCotas();
        vm.stopBroadcast();

        vm.startBroadcast(cfg.deployerPk);
        OfertaCaptacao(oferta).liberarParaEmissor();
        vm.stopBroadcast();

        _logResults(infra, cfg, token, oferta);
    }

    // ── Configuration ───────────────────────────────────────────────────────────────────

    function _readConfig() internal view returns (Config memory cfg) {
        cfg.deployerPk = vm.envUint("PRIVATE_KEY");
        cfg.investor1Pk = vm.envUint("INVESTIDOR1_PRIVATE_KEY");
        cfg.investor2Pk = vm.envUint("INVESTIDOR2_PRIVATE_KEY");
        cfg.deployer = vm.addr(cfg.deployerPk);
        cfg.investor1 = vm.addr(cfg.investor1Pk);
        cfg.investor2 = vm.addr(cfg.investor2Pk);
        cfg.issuerWallet = vm.envAddress("EMISSOR_WALLET_ADDRESS");
        cfg.protocolWallet = vm.envAddress("PROTOCOLO_WALLET_ADDRESS");
    }

    function _readAddresses() internal returns (Infra memory infra) {
        string memory json = vm.readFile(OUTPUT_PATH);
        infra.currency = MockBRL(vm.parseJsonAddress(json, ".currency"));
        infra.gateway = EmissaoGateway(vm.parseJsonAddress(json, ".gateway"));
        infra.tokenFactory = ParticipacaoTokenFactory(vm.parseJsonAddress(json, ".tokenFactory"));
        infra.fundraisingFactory = OfertaCaptacaoFactory(vm.parseJsonAddress(json, ".fundraisingFactory"));
    }

    // ── Execution of the AGENTE_ROLE proposed in DemoSepolia_Setup ─────────────────────

    function _executeAgent(Infra memory infra, address agent) internal {
        bytes32 role = keccak256("AGENTE_ROLE");
        address[3] memory targets =
            [address(infra.gateway), address(infra.tokenFactory), address(infra.fundraisingFactory)];
        for (uint256 i = 0; i < targets.length; i++) {
            (bool ok,) = targets[i].call(abi.encodeWithSignature("executeGrantRole(bytes32,address)", role, agent));
            require(ok, "executeGrantRole failed (timelock not elapsed yet?)");
        }
        // RegistroInvestidorQualificado is not used in this demo (no qualified investor
        // tested), but its AGENTE_ROLE was also proposed in DemoSepolia_Setup; it is left
        // pending on purpose, with no functional cost for this cycle.
    }

    // ── Operational sequence: criarOferta → atestarCotas → criarCaptacao → registrarCaptacao ──

    function _createOfferingAndFundraising(Infra memory infra, Config memory cfg)
        internal
        returns (address token, address oferta)
    {
        token = infra.tokenFactory
            .criarOferta(
                "Oferta Demo Sepolia",
                "nCAP",
                "Empresa Captacao Demo Ltda",
                keccak256(abi.encode("cnpj-demo-sepolia", block.timestamp)),
                "2026-DEMO-SEPOLIA"
            );
        infra.gateway.atestarCotas(token, (MAX_TARGET / PRICE_PER_SHARE) * 1 ether);

        oferta = infra.fundraisingFactory
            .criarCaptacao(
                token,
                MIN_TARGET,
                MAX_TARGET,
                PRICE_PER_SHARE,
                block.timestamp + DEADLINE_SECONDS,
                PER_INVESTOR_CAP,
                FEE_BPS,
                cfg.issuerWallet,
                cfg.protocolWallet
            );
        infra.gateway.registrarCaptacao(token, oferta);
    }

    function _topUpEthIfNeeded(address investidor) internal {
        if (investidor.balance < INVESTOR_MIN_ETH_BALANCE) {
            (bool ok,) = investidor.call{value: INVESTOR_ETH_TOP_UP}("");
            require(ok, "ETH top-up failed");
        }
    }

    function _invest(uint256 investorPk, MockBRL moeda, address oferta, uint256 valor) internal {
        vm.startBroadcast(investorPk);
        moeda.approve(oferta, valor);
        OfertaCaptacao(oferta).aportar(valor);
        vm.stopBroadcast();
    }

    // ── Logs ────────────────────────────────────────────────────────────────────────────

    function _logResults(Infra memory infra, Config memory cfg, address token, address oferta) internal view {
        console2.log("== DemoSepolia: ciclo completo ==");
        console2.log("Token (ParticipacaoToken):", token);
        console2.log("Offering (OfertaCaptacao escrow):", oferta);
        console2.log(
            "Final state (1 = EncerradaSucesso, closed with success):", uint256(OfertaCaptacao(oferta).estado())
        );
        console2.log("Total raised:", OfertaCaptacao(oferta).totalArrecadado());
        console2.log("");
        console2.log("Investor 1 shares:", ParticipacaoToken(token).balanceOf(cfg.investor1));
        console2.log("Investor 2 shares:", ParticipacaoToken(token).balanceOf(cfg.investor2));
        console2.log("Token totalSupply (should be 50 ether = 50 shares):", ParticipacaoToken(token).totalSupply());
        console2.log("");
        console2.log("Issuer MockBRL after release (should be 5000 ether):", infra.currency.balanceOf(cfg.issuerWallet));
        console2.log("Protocol MockBRL after release (fee 0):", infra.currency.balanceOf(cfg.protocolWallet));
        console2.log("MockBRL left in escrow (should be 0):", infra.currency.balanceOf(oferta));
    }
}
