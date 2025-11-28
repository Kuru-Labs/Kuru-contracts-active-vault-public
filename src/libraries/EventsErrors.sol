// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

library Errors {
    error InvalidLength();
    error InvalidInput();
    error SwapFailed();
    error NativeAssetMismatch();
    error NativeAssetInsufficient();
    error SharesMintedZero();
    error SharesBurnedZero();
    error NativeTransferFailed();
    error WithdrawalExceedsRestingBalance();
    error WithdrawSwapMinOutNotMet();
    error GasCrankCooldown();
    error GasCrankWithdrawExceedsMax();
    error Uint96Overflow();
}

library Events {
    event ActiveVaultDeposit(address user, uint256 baseAmount, uint256 quoteAmount, uint256 sharesMinted);
    event ActiveVaultWithdraw(address user, uint256 baseAmount, uint256 quoteAmount, uint256 sharesBurned);
    event GasCrankWithdraw(address gasCrank, uint256 baseAmount, uint256 quoteAmount);
}
