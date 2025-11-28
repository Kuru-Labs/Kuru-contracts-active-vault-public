// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ============ External Imports ============
import {IOrderBook} from "./IOrderBook.sol";

interface IVault {
    struct MarketParams {
        IOrderBook book;
        uint32 pricePrecision;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        address base;
        uint96 sizePrecision;
        address quote;
        uint40 head;
        uint40 tail;
    }

    struct Order {
        uint40 prev;
        uint40 next;
    }
}
