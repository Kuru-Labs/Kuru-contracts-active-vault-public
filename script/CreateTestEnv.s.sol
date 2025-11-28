//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MockERC20} from "lib/solady/test/utils/mocks/MockERC20.sol";
import {IRouter} from "../src/interfaces/IRouter.sol";
import {IOrderBook} from "../src/interfaces/IOrderBook.sol";
import {USDC} from "../src/test/USDC.sol";
import {WBTC} from "../src/test/WBTC.sol";
import {Vault} from "../src/Vault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MonadEnvironmentDeployer is Script {
    function run() public {
        address masterDeployer = vm.rememberKey(vm.envUint("MASTER_KEY"));
        address mintAndBurnAuth = vm.rememberKey(vm.envUint("MINT_AND_BURN_AUTH"));
        address operator = vm.envAddress("OPERATOR");
        address gasCrank = vm.envAddress("GAS_CRANK");
        uint256 unlockInterval = 1 days;
        uint256 gasCrankCooldown = 1 weeks;
        uint256 gasFeeOutMax = 10;

        address marginAccount = vm.envAddress("MARGIN_ACCOUNT");
        address[] memory operators = new address[](1);
        operators[0] = operator;
        IRouter router = IRouter(vm.envAddress("ROUTER"));
        vm.createSelectFork(vm.envString("RPC_URL"));
        vm.startBroadcast(masterDeployer);
        USDC usdc = new USDC(mintAndBurnAuth, mintAndBurnAuth);
        console.log("USDC deployed at: ", address(usdc));
        WBTC wbtc = new WBTC(mintAndBurnAuth, mintAndBurnAuth);
        console.log("WBTC deployed at: ", address(wbtc));
        address market = router.deployProxy(
            IOrderBook.OrderBookType.NO_NATIVE,
            address(wbtc),
            address(usdc),
            10 ** 8,
            1000,
            100,
            1000,
            1000 * 10 ** 8,
            0,
            0,
            100
        );
        console.log("Market deployed at: ", market);
        vm.stopBroadcast();
        vm.startBroadcast(mintAndBurnAuth);
        usdc.mint(mintAndBurnAuth, 100_000_000 * 10 ** 6);
        wbtc.mint(mintAndBurnAuth, 21_000_000 * 10 ** 8);
        vm.stopBroadcast();
        vm.startBroadcast(masterDeployer);
        Vault impl = new Vault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Vault bot = Vault(payable(address(proxy)));
        bot.initialize(
            mintAndBurnAuth, operator, gasCrank, market, marginAccount, unlockInterval, gasFeeOutMax, gasCrankCooldown
        );
        console.log("Bot deployed at: ", address(bot));
        vm.stopBroadcast();
        vm.startBroadcast(mintAndBurnAuth);
        usdc.approve(address(bot), 22_600_000 * 10 ** 6);
        wbtc.approve(address(bot), 200 * 10 ** 8);
        bot.deposit(200 * 10 ** 8, 22_600_000 * 10 ** 6);
        vm.stopBroadcast();
        (bool isOperator) = bot.operator() == operator;
        vm.assertEq(isOperator, true);
    }
}
