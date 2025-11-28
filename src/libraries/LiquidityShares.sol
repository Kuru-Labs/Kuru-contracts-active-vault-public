// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

abstract contract LiquidityShares is ERC20 {
    uint8 internal constant PRECISION = 18;
    uint256 public unlockInterval;
    mapping(address user => uint256 timestamp) public lastDepositTime;

    error Locked();

    event Deposit(address indexed user, uint256 baseAmount, uint256 quoteAmount, uint256 sharesMinted);

    event Withdraw(address indexed user, uint256 baseAmount, uint256 quoteAmount, uint256 sharesBurned);

    function name() public pure override returns (string memory) {
        return "Kuru Vault";
    }

    function symbol() public pure override returns (string memory) {
        return "KURU-VAULT";
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        if (lastDepositTime[msg.sender] + unlockInterval > block.timestamp) {
            revert Locked();
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        if (lastDepositTime[from] + unlockInterval > block.timestamp) {
            revert Locked();
        }
        return super.transferFrom(from, to, amount);
    }

    function _calculateSharesToMint(
        uint256 _baseAmountToDeposit,
        uint256 _baseAmountNotional,
        uint256 _quoteAmountToDeposit,
        uint256 _quoteAmountNotional
    ) internal view returns (uint256, uint256, uint256) {
        uint256 _totalSupply = totalSupply();
        uint256 _sharesWithBase = _toShares(_baseAmountToDeposit, _totalSupply, _baseAmountNotional, false);
        uint256 _sharesWithQuote = _toShares(_quoteAmountToDeposit, _totalSupply, _quoteAmountNotional, false);
        uint256 _effectiveOutShares = FixedPointMathLib.min(_sharesWithBase, _sharesWithQuote);
        if (_totalSupply == 0) {
            return (_effectiveOutShares, _baseAmountToDeposit, _quoteAmountToDeposit);
        }
        if (_effectiveOutShares == _sharesWithBase) {
            // testing mode
            _quoteAmountToDeposit = _toAmount(_sharesWithBase, _totalSupply, _quoteAmountNotional, true);
            _effectiveOutShares = FixedPointMathLib.min(
                _toShares(_baseAmountToDeposit, _totalSupply, _baseAmountNotional, false),
                _toShares(_quoteAmountToDeposit, _totalSupply, _quoteAmountNotional, false)
            );
            return (_effectiveOutShares, _baseAmountToDeposit, _quoteAmountToDeposit);
        } else {
            // testing mode
            _baseAmountToDeposit = _toAmount(_effectiveOutShares, _totalSupply, _baseAmountNotional, true);
            _effectiveOutShares = FixedPointMathLib.min(
                _toShares(_baseAmountToDeposit, _totalSupply, _baseAmountNotional, false),
                _toShares(_quoteAmountToDeposit, _totalSupply, _quoteAmountNotional, false)
            );
            return (_effectiveOutShares, _baseAmountToDeposit, _quoteAmountToDeposit);
        }
    }

    function _calculateSharesToBurn(
        uint256 _baseAmountToWithdraw,
        uint256 _baseAmountNotional,
        uint256 _quoteAmountToWithdraw,
        uint256 _quoteAmountNotional
    ) internal view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        return FixedPointMathLib.min(
            _toShares(_baseAmountToWithdraw, _totalSupply, _baseAmountNotional, true),
            _toShares(_quoteAmountToWithdraw, _totalSupply, _quoteAmountNotional, true)
        );
    }

    function _calculateAmountForShares(
        uint256 _shares,
        uint256 _totalSupply,
        uint256 _baseNotional,
        uint256 _quoteNotional,
        bool _isDeposit
    ) internal pure returns (uint256, uint256) {
        uint256 _baseAmount = _toAmount(_shares, _totalSupply, _baseNotional, _isDeposit);
        uint256 _quoteAmount = _toAmount(_shares, _totalSupply, _quoteNotional, _isDeposit);
        return (_baseAmount, _quoteAmount);
    }

    /// @notice Calculates the base value in relationship to `elastic` and `total`.
    function _toShares(uint256 amount, uint256 totalShares_, uint256 totalAmount, bool roundUp)
        internal
        pure
        returns (uint256 share)
    {
        // To prevent reseting the ratio due to withdrawal of all shares, we start with
        // 1 amount/1e8 shares already burned. This also starts with a 1 : 1e8 ratio which
        // functions like 8 decimal fixed point math. This prevents ratio attacks or inaccuracy
        // due to 'gifting' or rebasing tokens. (Up to a certain degree)
        totalAmount++;
        totalShares_ += 1e8;

        // Calculte the shares using te current amount to share ratio
        share = (amount * totalShares_) / totalAmount;

        // Default is to round down (Solidity), round up if required
        if (roundUp && (share * totalAmount) / totalShares_ < amount) {
            share++;
        }
    }

    /// @notice Calculates the elastic value in relationship to `base` and `total`.
    function _toAmount(uint256 share, uint256 totalShares_, uint256 totalAmount, bool roundUp)
        internal
        pure
        returns (uint256 amount)
    {
        // To prevent reseting the ratio due to withdrawal of all shares, we start with
        // 1 amount/1e8 shares already burned. This also starts with a 1 : 1e8 ratio which
        // functions like 8 decimal fixed point math. This prevents ratio attacks or inaccuracy
        // due to 'gifting' or rebasing tokens. (Up to a certain degree)
        totalAmount++;
        totalShares_ += 1e8;

        // Calculte the amount using te current amount to share ratio
        amount = (share * totalAmount) / totalShares_;

        // Default is to round down (Solidity), round up if required
        if (roundUp && (amount * totalShares_) / totalAmount < share) {
            amount++;
        }
    }
}
