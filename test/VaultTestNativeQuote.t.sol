//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vault} from "../src/Vault.sol";
import {IRouter} from "../src/interfaces/IRouter.sol";
import {IMarginAccount} from "../src/interfaces/IMarginAccount.sol";
import {IOrderBook} from "../src/interfaces/IOrderBook.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WBTC} from "../src/test/WBTC.sol";
import {Errors} from "../src/libraries/EventsErrors.sol";

contract VaultTest is Test {
    Vault public vault;
    IMarginAccount public marginAccount;
    IRouter public router;
    IOrderBook public orderBook;
    WBTC public wbtc;
    address public usdc = address(0);

    error Locked();

    address sourceOfFunds;
    address mintAndBurnAuth;
    address operator;
    address gasCrank;
    uint256 baseMultiplier;
    uint256 quoteMultiplier;

    uint32 pricePrecision = 10 ** 4;
    uint96 sizePrecision = 10 ** 8;
    uint32 tickSize = 10 ** 4;
    uint96 minSize = 10 ** 4;
    uint96 maxSize = 100 * 10 ** 8;
    uint256 takerFeeBps = 0;
    uint256 makerFeeBps = 0;
    uint96 kuruAmmSpread = 100;
    uint256 unlockInterval = 1 days;
    uint256 gasFeeOutMax = 10;
    uint256 gasCrankCooldown = 1 weeks;
    uint256 seed;

    address user = makeAddr("USER");

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"));
        sourceOfFunds = makeAddr("SOURCE_OF_FUNDS");
        mintAndBurnAuth = makeAddr("MINT_AND_BURN_AUTH");
        operator = makeAddr("OPERATOR");
        gasCrank = makeAddr("GAS_CRANK");
        mintAndBurnAuth = sourceOfFunds;
        operator = sourceOfFunds;
        gasCrank = sourceOfFunds;
        marginAccount = IMarginAccount(vm.envAddress("MARGIN_ACCOUNT"));
        router = IRouter(vm.envAddress("ROUTER"));
        vm.deal(mintAndBurnAuth, 100 ether);
        vm.deal(operator, 100 ether);
        //make base token
        wbtc = new WBTC(mintAndBurnAuth, mintAndBurnAuth);

        //make order book
        orderBook = IOrderBook(
            router.deployProxy(
                IOrderBook.OrderBookType.NATIVE_IN_QUOTE,
                address(wbtc),
                address(usdc),
                sizePrecision,
                pricePrecision,
                tickSize,
                minSize,
                maxSize,
                takerFeeBps,
                makerFeeBps,
                kuruAmmSpread
            )
        );
        Vault implementation = new Vault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        console.log("proxy", address(proxy));
        vault = Vault(payable(address(proxy)));
        vault.initialize(
            sourceOfFunds,
            operator,
            gasCrank,
            address(orderBook),
            address(marginAccount),
            unlockInterval,
            gasFeeOutMax,
            gasCrankCooldown
        );
        baseMultiplier = 10 ** wbtc.decimals();
        quoteMultiplier = 10 ** 18;
    }

    function _mintBaseToAddress(address to, uint256 amount) internal {
        vm.prank(mintAndBurnAuth);
        wbtc.mint(to, amount);
    }

    function _mintQuoteToAddress(address to, uint256 amount) internal {
        vm.deal(to, amount);
    }

    function testDepositOnce() public {
        uint256 _price = 100000 * pricePrecision;
        uint256 baseAmount = 1000 * baseMultiplier;
        uint256 quoteAmount = _price * baseAmount * quoteMultiplier / (pricePrecision * baseMultiplier);
        _mintBaseToAddress(operator, baseAmount);
        _mintQuoteToAddress(operator, quoteAmount);
        vm.startPrank(operator);
        wbtc.approve(address(vault), baseAmount);
        vault.deposit{value: quoteAmount}(baseAmount, quoteAmount);
        vm.stopPrank();
    }

    function testDepositWithShares() public {
        testDepositOnce();
        // check deposit rates for 1 share
        (uint256 baseAmount, uint256 quoteAmount) = vault.previewDepositInAmounts(1 * 10 ** 18);
        address operator2 = vm.addr(uint256(keccak256("OPERATOR2")));
        _mintBaseToAddress(operator2, baseAmount);
        _mintQuoteToAddress(operator2, quoteAmount);
        vm.startPrank(operator2);
        wbtc.approve(address(vault), baseAmount);
        vault.deposit{value: quoteAmount}(baseAmount, quoteAmount);
        vm.stopPrank();
        assertEq(vault.balanceOf(operator2), 1 * 10 ** 18);
    }

    function testWithdraw() public {
        testDepositWithShares();
        uint256 _toWithdraw = vault.balanceOf(operator);
        skip(1 days + 1 minutes);
        vm.prank(operator);
        vault.withdraw(_toWithdraw);
        assertEq(vault.balanceOf(operator), 0);
        address operator2 = vm.addr(uint256(keccak256("OPERATOR2")));
        vm.prank(operator2);
        vault.withdraw(1 * 10 ** 18);
    }

    function testWithdrawRevertWithdrawalExceedsRestingBalance() public {
        testPlaceOrder();
        uint256 _toWithdraw = vault.balanceOf(operator);
        vm.warp(block.timestamp + 1 days + 1 minutes);
        vm.prank(operator);
        vm.expectRevert(Errors.WithdrawalExceedsRestingBalance.selector);
        vault.withdraw(_toWithdraw);
    }

    function testWithdrawRevert() public {
        testDepositOnce();
        uint256 _toWithdraw = vault.balanceOf(operator);
        vm.prank(operator);
        vm.expectRevert(Locked.selector);
        vault.withdraw(_toWithdraw);
    }

    function testPlaceOrder() public {
        testDepositOnce();
        vm.prank(operator);
        uint32[] memory buyPrices = new uint32[](1);
        uint32[] memory sellPrices = new uint32[](1);
        uint96[] memory buySizes = new uint96[](1);
        uint96[] memory sellSizes = new uint96[](1);
        uint32 initialPrice = 100_000 * pricePrecision;
        buyPrices[0] = initialPrice;
        sellPrices[0] = initialPrice + tickSize;
        buySizes[0] = 10 * sizePrecision;
        sellSizes[0] = 10 * sizePrecision;
        vault.cancelAllReplace(buyPrices, sellPrices, buySizes, sellSizes);
        buyPrices[0] = initialPrice + tickSize;
        sellPrices[0] = initialPrice + 2 * tickSize;
        buySizes[0] = 10 * sizePrecision;
        sellSizes[0] = 10 * sizePrecision;
        vm.prank(operator);
        vault.cancelAllReplace(buyPrices, sellPrices, buySizes, sellSizes);
    }

    function testReplaceOrders() public {
        testDepositOnce();
        uint32[] memory buyPrices = new uint32[](4);
        uint32[] memory sellPrices = new uint32[](4);
        uint96[] memory buySizes = new uint96[](4);
        uint96[] memory sellSizes = new uint96[](4);
        uint32 basePrice = 100000 * pricePrecision;
        uint256 _expectedBasePosted;
        uint256 _expectedQuotePosted;
        for (uint32 i = 0; i < 4; i++) {
            buyPrices[i] = basePrice - (i + 1) * tickSize;
            sellPrices[i] = basePrice + (i + 1) * tickSize;
            buySizes[i] = 1 * sizePrecision;
            sellSizes[i] = 1 * sizePrecision;
            _expectedBasePosted += sellSizes[i] * baseMultiplier / sizePrecision;
            _expectedQuotePosted += (buyPrices[i] * buySizes[i] / sizePrecision) * quoteMultiplier / pricePrecision;
        }
        vm.prank(operator);
        vault.cancelAllReplace(buyPrices, sellPrices, buySizes, sellSizes);
        (uint256 _basePosted, uint256 _quotePosted) = vault.getPostedBalances();
        assertEq(_basePosted, _expectedBasePosted);
        assertEq(_quotePosted, _expectedQuotePosted);
        _expectedBasePosted = 0;
        _expectedQuotePosted = 0;
        basePrice = 101000 * pricePrecision;
        for (uint32 i = 0; i < 4; i++) {
            buyPrices[i] = basePrice - (i + 1) * tickSize;
            sellPrices[i] = basePrice + (i + 1) * tickSize;
            buySizes[i] = 1 * sizePrecision;
            sellSizes[i] = 1 * sizePrecision;
            _expectedBasePosted += sellSizes[i] * baseMultiplier / sizePrecision;
            _expectedQuotePosted += (buyPrices[i] * buySizes[i] / sizePrecision) * quoteMultiplier / pricePrecision;
        }
        vm.prank(operator);
        vault.cancelAllReplace(buyPrices, sellPrices, buySizes, sellSizes);
        (_basePosted, _quotePosted) = vault.getPostedBalances();
        assertEq(_basePosted, _expectedBasePosted);
        assertEq(_quotePosted, _expectedQuotePosted);
    }

    function testPostonlyRevertReplaceOrders() public {
        testDepositOnce();
        uint32[] memory _buyPrices = new uint32[](4);
        uint32[] memory _sellPrices = new uint32[](4);
        uint96[] memory _buySizes = new uint96[](4);
        uint96[] memory _sellSizes = new uint96[](4);
        uint32 _basePrice = 100000 * pricePrecision;
        for (uint32 i = 0; i < 4; i++) {
            _buyPrices[i] = _basePrice - (i + 1) * tickSize;
            _sellPrices[i] = _basePrice + (i + 1) * tickSize;
            _buySizes[i] = 1 * sizePrecision;
            _sellSizes[i] = 1 * sizePrecision;
        }
        vm.prank(operator);
        vault.cancelAllReplace(_buyPrices, _sellPrices, _buySizes, _sellSizes);
        address _maker = vm.addr(uint256(keccak256("MAKER")));
        _mintBaseToAddress(_maker, 1 * baseMultiplier);
        vm.startPrank(_maker);
        wbtc.approve(address(marginAccount), 1 * baseMultiplier);
        marginAccount.deposit(_maker, address(wbtc), 1 * baseMultiplier);
        orderBook.addSellOrder(_basePrice, 1 * sizePrecision, true);
        vm.stopPrank();
        _basePrice = 100100 * pricePrecision;
        for (uint32 i = 0; i < 4; i++) {
            _buyPrices[i] = _basePrice - (i + 1) * tickSize;
            _sellPrices[i] = _basePrice + (i + 1) * tickSize;
            _buySizes[i] = 1 * sizePrecision;
            _sellSizes[i] = 1 * sizePrecision;
        }
        vm.prank(operator);
        vault.cancelAllReplace(_buyPrices, _sellPrices, _buySizes, _sellSizes);
        (uint256 _basePosted, uint256 _quotePosted) = vault.getPostedBalances();
        assertEq(_basePosted + _quotePosted, 0);
    }

    function testDepositSingleSide() public {
        testDepositOnce();
        testPlaceOrder();
        _mintBaseToAddress(user, baseMultiplier / 10);
        vm.startPrank(user);
        wbtc.approve(address(vault), baseMultiplier / 10);
        vault.depositSingleSide(baseMultiplier / 10, baseMultiplier / 20, 0, true);
        vm.stopPrank();
        uint256 _shares = vault.balanceOf(user);
        assert(_shares > 0);
    }

    function testRevertDepositSingleSideMinOutNotSatisfied() public {
        testDepositOnce();
        testPlaceOrder();
        _mintBaseToAddress(user, baseMultiplier / 10);
        vm.startPrank(user);
        wbtc.approve(address(vault), baseMultiplier / 10);
        vm.expectRevert();
        vault.depositSingleSide(baseMultiplier / 10, baseMultiplier / 20, 5000050000000000000001, true);
        vm.stopPrank();
    }

    function testWithdrawSingleSide() public {
        testDepositSingleSide();
        uint256 _shares = vault.balanceOf(user);
        vm.warp(block.timestamp + 1 days + 1 minutes);
        vm.startPrank(user);
        vault.withdrawSingleSide(_shares, false, 0);
        vm.stopPrank();
    }

    function testRevertWithdrawSingleSideInvalidShares() public {
        testDepositSingleSide();
        uint256 _shares = vault.balanceOf(user);
        vm.warp(block.timestamp + 1 days + 1 minutes);
        vm.startPrank(user);
        vm.expectRevert();
        vault.withdrawSingleSide(_shares + 1, false, 0);
        vm.stopPrank();
    }

    function testRevertWithdrawMinOutNotSatisfied() public {
        testDepositSingleSide();
        uint256 _shares = vault.balanceOf(user);
        vm.warp(block.timestamp + 1 days + 1 minutes);
        vm.startPrank(user);
        vm.expectRevert(Errors.WithdrawSwapMinOutNotMet.selector);
        vault.withdrawSingleSide(_shares, false, 9999650);
        vm.stopPrank();
    }
}
