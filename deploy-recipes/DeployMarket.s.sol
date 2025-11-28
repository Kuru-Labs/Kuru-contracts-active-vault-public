//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IOrderBook} from "../src/interfaces/IOrderBook.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IRouter} from "../src/interfaces/IRouter.sol";

contract DeployMarket is Script {
    IOrderBook public orderBook;
    IRouter public router;

    function run() public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deploy-recipes/config/inputs.json");
        string memory json = vm.readFile(path);
        string memory rpcUrl = vm.parseJsonString(json, ".rpc_url");
        vm.createSelectFork(rpcUrl);
        router = IRouter(vm.parseJsonAddress(json, ".router"));
        address baseToken = vm.parseJsonAddress(json, ".base_token");
        address quoteToken = vm.parseJsonAddress(json, ".quote_token");
        uint96 sizePrecision = uint96(vm.parseJsonUint(json, ".size_precision"));
        uint32 pricePrecision = uint32(vm.parseJsonUint(json, ".price_precision"));
        uint32 tickSize = uint32(vm.parseJsonUint(json, ".tick_size"));
        uint96 minSize = uint96(vm.parseJsonUint(json, ".min_size"));
        uint96 maxSize = uint96(vm.parseJsonUint(json, ".max_size"));
        uint256 takerFeeBps = vm.parseJsonUint(json, ".taker_fee_bps");
        uint256 makerFeeBps = vm.parseJsonUint(json, ".maker_fee_bps");
        uint96 kuruAmmSpread = uint96(vm.parseJsonUint(json, ".kuru_amm_spread"));
        IOrderBook.OrderBookType orderBookType;
        if (baseToken == address(0)) {
            orderBookType = IOrderBook.OrderBookType.NATIVE_IN_BASE;
        } else if (quoteToken == address(0)) {
            orderBookType = IOrderBook.OrderBookType.NATIVE_IN_QUOTE;
        } else {
            orderBookType = IOrderBook.OrderBookType.NO_NATIVE;
        }
        vm.startBroadcast();
        orderBook = IOrderBook(router.deployProxy(
            orderBookType,
            baseToken,
            quoteToken,
            sizePrecision,
            pricePrecision,
            tickSize,
            minSize,
            maxSize,
            takerFeeBps,
            makerFeeBps,
            kuruAmmSpread
        ));
        vm.stopBroadcast();

        // Write the deployed orderBook address back to inputs.json as "market"
        string memory orderBookAddress = vm.toString(address(orderBook));
        vm.writeJson(orderBookAddress, path, ".market");
        
        console.log("OrderBook deployed at:", address(orderBook));
        console.log("Updated inputs.json with market address");
    }
}