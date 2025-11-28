//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

interface IKuruFlowEntrypoint {
    struct SwapIntent {
        address tokenUserBuys;
        uint256 minAmountUserBuys;
        address tokenUserSells;
        uint256 amountUserSells;
    }

    struct FeeCollection {
        address feeCollectorAddress;
        uint256 feeBps;
        address referrerAddress;
        uint256 referrerFeeBps;
        bool isInTokenFee;
    }

    function executeSwap(SwapIntent calldata swapIntent, FeeCollection calldata feeCollection, bytes calldata program)
        external
        payable
        returns (uint256 amountOut);
}
