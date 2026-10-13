// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockBRL} from "../src/mocks/MockBRL.sol";
import {RestrictedTransferPolicy} from "../src/policies/RestrictedTransferPolicy.sol";
import {ParticipacaoToken} from "../src/token/ParticipacaoToken.sol";
import {EmissaoGateway} from "../src/emissao/EmissaoGateway.sol";
import {LiquidacaoSecundaria} from "../src/secundario/LiquidacaoSecundaria.sol";

/// @title DemoSecundario (secondary market demo)
/// @notice Part 3/3 (the climax) of the public secondary-market demo on Sepolia. Run only after
/// `DemoSecundarioPreparar.s.sol` and after >= 1h of REAL time has passed (the 10-minute
/// lock-up will have expired within that window). Executes the token's policy migration +
/// secondary-market opening proposed in part 2, funds the buyer in `MockBRL`, collects the two
/// allowances (seller→shares, buyer→MockBRL) and closes the assignment via
/// `LiquidacaoSecundaria.liquidarCessao`, the atomic swap.
/// @dev Before running this script, optionally run via `cast send` a
/// `ParticipacaoToken.transfer` attempt from seller to buyer (it must revert: public proof
/// that the restriction is real before opening the secondary market). It is deliberately not
/// built in here: it is a point-in-time artifact that makes more sense as a standalone command
/// documented in the demo record than as part of the programmatic flow.
contract DemoSecundario is Script {
    string internal constant OUTPUT_PATH = "./script/output/demo-secundario.json";

    uint256 internal constant PRICE_PER_SHARE = 100 ether;
    uint256 internal constant ASSIGNMENT_QUANTITY = 20 ether; // 20 shares
    uint256 internal constant ASSIGNMENT_AMOUNT = 2_000 ether; // 20 * 100

    struct Config {
        uint256 deployerPk;
        uint256 sellerPk;
        uint256 buyerPk;
        address deployer;
        address seller;
        address buyer;
        address protocolWallet;
    }

    struct Infra {
        MockBRL currency;
        RestrictedTransferPolicy restricted;
        EmissaoGateway gateway;
        LiquidacaoSecundaria settlement;
        ParticipacaoToken token;
    }

    function run() external {
        Config memory cfg = _readConfig();
        Infra memory infra = _readAddresses();

        console2.log("== DemoSecundario (climax) ==");
        console2.log("Token:", address(infra.token));
        console2.log("Seller:", cfg.seller);
        console2.log("Buyer:", cfg.buyer);

        vm.startBroadcast(cfg.deployerPk);
        _openSecondary(infra);
        infra.currency.mint(cfg.buyer, ASSIGNMENT_AMOUNT);
        vm.stopBroadcast();

        vm.startBroadcast(cfg.buyerPk);
        infra.currency.approve(address(infra.settlement), ASSIGNMENT_AMOUNT);
        vm.stopBroadcast();

        vm.startBroadcast(cfg.sellerPk);
        infra.token.approve(address(infra.settlement), ASSIGNMENT_QUANTITY);
        vm.stopBroadcast();

        vm.startBroadcast(cfg.deployerPk);
        uint256 feeCharged =
            infra.settlement.liquidarCessao(address(infra.token), cfg.seller, cfg.buyer, ASSIGNMENT_QUANTITY, PRICE_PER_SHARE);
        vm.stopBroadcast();

        _logResults(infra, cfg, feeCharged);
    }

    // ── Configuration ───────────────────────────────────────────────────────────────────

    function _readConfig() internal view returns (Config memory cfg) {
        cfg.deployerPk = vm.envUint("PRIVATE_KEY");
        cfg.sellerPk = vm.envUint("INVESTIDOR1_PRIVATE_KEY");
        cfg.buyerPk = vm.envUint("INVESTIDOR2_PRIVATE_KEY");
        cfg.deployer = vm.addr(cfg.deployerPk);
        cfg.seller = vm.addr(cfg.sellerPk);
        cfg.buyer = vm.addr(cfg.buyerPk);
        cfg.protocolWallet = vm.envAddress("PROTOCOLO_WALLET_ADDRESS");
    }

    function _readAddresses() internal returns (Infra memory infra) {
        string memory json = vm.readFile(OUTPUT_PATH);
        infra.currency = MockBRL(vm.parseJsonAddress(json, ".currency"));
        infra.restricted = RestrictedTransferPolicy(vm.parseJsonAddress(json, ".restricted"));
        infra.gateway = EmissaoGateway(vm.parseJsonAddress(json, ".gateway"));
        infra.settlement = LiquidacaoSecundaria(vm.parseJsonAddress(json, ".liquidacao"));
        infra.token = ParticipacaoToken(vm.parseJsonAddress(json, ".token"));
    }

    // ── Execution of the policy migration + opening proposed in DemoSecundarioPreparar ──

    function _openSecondary(Infra memory infra) internal {
        infra.gateway.executeSetTransferPolicy(address(infra.token), address(infra.restricted));
        infra.restricted.executeSetSecundarioLiberado(address(infra.token), true);
    }

    // ── Logs (see also the independent `cast call` reading in the demo record) ───────────

    function _logResults(Infra memory infra, Config memory cfg, uint256 feeCharged) internal view {
        console2.log("");
        console2.log("== Cessao liquidada ==");
        console2.log("Fee charged (should be 0, fee dormant):", feeCharged);
        console2.log("");
        console2.log("Seller shares (should be 30 ether = 30 shares):", infra.token.balanceOf(cfg.seller));
        console2.log("Buyer shares (should be 20 ether = 20 shares):", infra.token.balanceOf(cfg.buyer));
        console2.log("Seller MockBRL (should be 2000 ether, fee 0):", infra.currency.balanceOf(cfg.seller));
        console2.log("Buyer MockBRL (should be 0, paid everything):", infra.currency.balanceOf(cfg.buyer));
        console2.log("Protocol MockBRL (should be 0, fee dormant):", infra.currency.balanceOf(cfg.protocolWallet));
    }
}
