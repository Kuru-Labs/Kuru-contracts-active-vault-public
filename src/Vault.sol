// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

// ============ Internal Imports ============
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {Events, Errors} from "./libraries/EventsErrors.sol";
import {LiquidityShares} from "./libraries/LiquidityShares.sol";
import {IKuruFlowEntrypoint} from "./interfaces/IKuruFlowEntrypoint.sol";

// ============ External Imports ============
import {Ownable} from "solady/auth/Ownable.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract Vault is Initializable, Ownable, UUPSUpgradeable, ReentrancyGuardTransient, IVault, LiquidityShares {
    MarketParams public ctx;
    address public operator;
    address public gasCrank;
    uint256 public gasFeeOutMax;
    uint256 public gasCrankCooldown;
    uint256 public lastCrankTime;
    IMarginAccount public marginAccount;

    using SafeTransferLib for address;

    // ============ AUTH ==================
    function _guardInitializeOwner() internal pure override returns (bool guard) {
        guard = true;
    }

    /**
     * @dev Makes sure owner is the one upgrading contract
     */
    function _authorizeUpgrade(address) internal view override {
        _checkOwner();
    }

    function _verifyOperator() internal view {
        require(msg.sender == operator, "Vault: not operator");
    }

    function _verifyGasCrank() internal view {
        require(msg.sender == gasCrank, "Vault: not gas crank");
    }

    // ============ Initializer ============

    function initialize(
        address _owner,
        address _operator,
        address _gasCrank,
        address _targetMarket,
        address _marginAccount,
        uint256 _unlockInterval,
        uint256 _gasFeeOutMax,
        uint256 _gasCrankCooldown
    ) public initializer {
        require(_operator != address(0), Errors.InvalidInput());
        require(_gasCrank != address(0), Errors.InvalidInput());
        require(_targetMarket != address(0), Errors.InvalidInput());
        require(_marginAccount != address(0), Errors.InvalidInput());
        require(_unlockInterval > 0, Errors.InvalidInput());
        require(_gasFeeOutMax > 0 && _gasFeeOutMax <= 10000, Errors.InvalidInput());
        require(_gasCrankCooldown > 0, Errors.InvalidInput());
        _initializeOwner(_owner);
        _populateCtx(_targetMarket);
        operator = _operator;
        gasCrank = _gasCrank;
        marginAccount = IMarginAccount(_marginAccount);
        unlockInterval = _unlockInterval;
        gasFeeOutMax = _gasFeeOutMax;
        gasCrankCooldown = _gasCrankCooldown;
        if (ctx.base != address(0)) {
            IERC20Metadata(ctx.base).approve(address(marginAccount), type(uint256).max);
        }
        if (ctx.quote != address(0)) {
            IERC20Metadata(ctx.quote).approve(address(marginAccount), type(uint256).max);
        }
    }

    // ============ Admin operations ===================
    function setUnlockInterval(uint256 _unlockInterval) external onlyOwner {
        unlockInterval = _unlockInterval;
    }

    function setGasParams(address _gasCrank, uint256 _gasFeeOutMax, uint256 _gasCrankCooldown) external onlyOwner {
        if (_gasCrank != address(0)) {
            gasCrank = _gasCrank;
        }
        if (_gasFeeOutMax != 0) {
            gasFeeOutMax = _gasFeeOutMax;
        }
        if (_gasCrankCooldown != 0) {
            gasCrankCooldown = _gasCrankCooldown;
        }
    }

    // ============ User Operations ====================

    function previewDepositInShares(uint256 _baseAmount, uint256 _quoteAmount) external view returns (uint256) {
        (uint256 _baseAmountNotional, uint256 _quoteAmountNotional) = calculateNotionalValue();
        (uint256 _shares,,) =
            _calculateSharesToMint(_baseAmount, _baseAmountNotional, _quoteAmount, _quoteAmountNotional);
        return _shares;
    }

    function previewDepositInAmounts(uint256 _shares) external view returns (uint256, uint256) {
        (uint256 _baseAmountNotional, uint256 _quoteAmountNotional) = calculateNotionalValue();
        return _calculateAmountForShares(_shares, totalSupply(), _baseAmountNotional, _quoteAmountNotional, true);
    }

    function previewWithdrawInShares(uint256 _baseAmount, uint256 _quoteAmount) external view returns (uint256) {
        (uint256 _baseAmountNotional, uint256 _quoteAmountNotional) = calculateNotionalValue();
        return _calculateSharesToBurn(_baseAmount, _baseAmountNotional, _quoteAmount, _quoteAmountNotional);
    }

    function previewWithdrawInAmounts(uint256 _shares) external view returns (uint256, uint256) {
        (uint256 _baseAmountNotional, uint256 _quoteAmountNotional) = calculateNotionalValue();
        return _calculateAmountForShares(_shares, totalSupply(), _baseAmountNotional, _quoteAmountNotional, false);
    }

    function depositSingleSide(uint256 _totalAmountToPull, uint256 _amountToSwap, uint256 _minOut, bool _isBaseAsset)
        external
        payable
        nonReentrant
        returns (uint256)
    {
        require(_amountToSwap > 0 && _totalAmountToPull > _amountToSwap, Errors.InvalidInput());
        MarketParams memory _ctx = ctx;
        uint256 _prevBaseBalance = _currentBalance(_ctx.base, true);
        uint256 _prevQuoteBalance = _currentBalance(_ctx.quote, true);
        address _tokenToSwap = _isBaseAsset ? _ctx.base : _ctx.quote;
        uint256 _value;
        if (_tokenToSwap != address(0)) {
            _tokenToSwap.safeTransferFrom(msg.sender, address(this), _totalAmountToPull);
            _tokenToSwap.safeApprove(address(_ctx.book), _amountToSwap);
        } else {
            require(msg.value == _totalAmountToPull, Errors.NativeAssetInsufficient());
            _value = _amountToSwap;
        }
        if (_isBaseAsset) {
            _ctx.book.placeAndExecuteMarketSell{value: _value}(
                toU96(_amountToSwap * _ctx.sizePrecision / 10 ** _ctx.baseDecimals), _minOut, false, true
            );
        } else {
            _ctx.book.placeAndExecuteMarketBuy{value: _value}(
                toU96(_amountToSwap * _ctx.pricePrecision / 10 ** _ctx.quoteDecimals), _minOut, false, true
            );
        }
        if (_tokenToSwap != address(0)) {
            _tokenToSwap.safeApprove(address(_ctx.book), 0);
        }
        (uint256 _baseAmountNotional, uint256 _quoteAmountNotional) = calculateNotionalValue();
        uint256 _sharesToMint;
        uint256 _requiredBaseAmount = _currentBalance(_ctx.base, false) - _prevBaseBalance;
        uint256 _requiredQuoteAmount = _currentBalance(_ctx.quote, false) - _prevQuoteBalance;
        (_sharesToMint, _requiredBaseAmount, _requiredQuoteAmount) =
            _calculateSharesToMint(_requiredBaseAmount, _baseAmountNotional, _requiredQuoteAmount, _quoteAmountNotional);
        require(_sharesToMint > 0, Errors.SharesMintedZero());
        _mint(msg.sender, _sharesToMint);
        lastDepositTime[msg.sender] = block.timestamp;
        _depositToMarginAccountSingle(_requiredBaseAmount, _ctx.base);
        _depositToMarginAccountSingle(_requiredQuoteAmount, _ctx.quote);
        emit Events.ActiveVaultDeposit(msg.sender, _requiredBaseAmount, _requiredQuoteAmount, _sharesToMint);
        // Calculate refund, underflows + reverts if excess consumed
        _requiredBaseAmount = _currentBalance(_ctx.base, false) - _prevBaseBalance;
        _requiredQuoteAmount = _currentBalance(_ctx.quote, false) - _prevQuoteBalance;
        if (_requiredBaseAmount > 0) {
            _sendToRecipient(_requiredBaseAmount, _ctx.base, msg.sender);
        }
        if (_requiredQuoteAmount > 0) {
            _sendToRecipient(_requiredQuoteAmount, _ctx.quote, msg.sender);
        }
        return _sharesToMint;
    }

    function withdrawSingleSide(uint256 _shares, bool _isBaseForSwap, uint256 _minOut)
        external
        nonReentrant
        returns (uint256, uint256)
    {
        require(_shares > 0, Errors.SharesBurnedZero());
        require(lastDepositTime[msg.sender] + unlockInterval < block.timestamp, Locked());
        MarketParams memory _ctx = ctx;
        uint256 _prevBaseBalance = _currentBalance(_ctx.base, true);
        uint256 _prevQuoteBalance = _currentBalance(_ctx.quote, true);
        (uint256 _restingBaseAmount, uint256 _restingQuoteAmount) = getRestingBalances();
        (uint256 _postedBaseAmount, uint256 _postedQuoteAmount) = getPostedBalances();
        (uint256 _baseAmountForWithdraw, uint256 _quoteAmountForWithdraw) = _calculateAmountForShares(
            _shares,
            totalSupply(),
            _restingBaseAmount + _postedBaseAmount,
            _restingQuoteAmount + _postedQuoteAmount,
            false
        );
        if (_baseAmountForWithdraw > _restingBaseAmount || _quoteAmountForWithdraw > _restingQuoteAmount) {
            revert Errors.WithdrawalExceedsRestingBalance();
        }
        _burn(msg.sender, _shares);
        _withdrawFromMarginAccountSingle(_baseAmountForWithdraw, _ctx.base);
        _withdrawFromMarginAccountSingle(_quoteAmountForWithdraw, _ctx.quote);
        uint256 _value;
        if (_isBaseForSwap) {
            if (_ctx.base == address(0)) {
                _value = _baseAmountForWithdraw;
            } else {
                _ctx.base.safeApprove(address(_ctx.book), _baseAmountForWithdraw);
            }
        } else if (!_isBaseForSwap) {
            if (_ctx.quote == address(0)) {
                _value = _quoteAmountForWithdraw;
            } else {
                _ctx.quote.safeApprove(address(_ctx.book), _quoteAmountForWithdraw);
            }
        }
        if (_isBaseForSwap) {
            _ctx.book.placeAndExecuteMarketSell{value: _value}(
                toU96(_baseAmountForWithdraw * _ctx.sizePrecision / 10 ** _ctx.baseDecimals), 0, false, true
            );
        } else {
            _ctx.book.placeAndExecuteMarketBuy{value: _value}(
                toU96(_quoteAmountForWithdraw * _ctx.pricePrecision / 10 ** _ctx.quoteDecimals), 0, false, true
            );
        }
        if (_isBaseForSwap && _ctx.base != address(0)) {
            _ctx.base.safeApprove(address(_ctx.book), 0);
        } else if (!_isBaseForSwap && _ctx.quote != address(0)) {
            _ctx.quote.safeApprove(address(_ctx.book), 0);
        }
        uint256 _requiredBaseAmount = _currentBalance(_ctx.base, false) - _prevBaseBalance;
        uint256 _requiredQuoteAmount = _currentBalance(_ctx.quote, false) - _prevQuoteBalance;
        require(
            _isBaseForSwap && _requiredQuoteAmount >= _minOut || !_isBaseForSwap && _requiredBaseAmount >= _minOut,
            Errors.WithdrawSwapMinOutNotMet()
        );
        if (_requiredBaseAmount > 0) {
            _sendToRecipient(_requiredBaseAmount, _ctx.base, msg.sender);
        }
        if (_requiredQuoteAmount > 0) {
            _sendToRecipient(_requiredQuoteAmount, _ctx.quote, msg.sender);
        }
        emit Events.ActiveVaultWithdraw(msg.sender, _baseAmountForWithdraw, _quoteAmountForWithdraw, _shares);
        return (_baseAmountForWithdraw, _quoteAmountForWithdraw);
    }

    function deposit(uint256 _baseAmount, uint256 _quoteAmount) external payable nonReentrant returns (uint256) {
        require(
            (ctx.base == address(0) || ctx.quote == address(0))
                ? msg.value == (ctx.base == address(0) ? _baseAmount : _quoteAmount)
                : msg.value == 0,
            Errors.NativeAssetMismatch()
        );
        return _depositAndMint(_baseAmount, _quoteAmount);
    }

    function _depositAndMint(uint256 _baseAmount, uint256 _quoteAmount) internal returns (uint256) {
        (uint256 _baseAmountNotional, uint256 _quoteAmountNotional) = calculateNotionalValue();
        uint256 _shares;
        (_shares, _baseAmount, _quoteAmount) =
            _calculateSharesToMint(_baseAmount, _baseAmountNotional, _quoteAmount, _quoteAmountNotional);
        require(_shares > 0, Errors.SharesMintedZero());
        _mint(msg.sender, _shares);
        lastDepositTime[msg.sender] = block.timestamp;
        uint256 _nativeRefund;
        if (ctx.base == address(0)) {
            _nativeRefund = msg.value - _baseAmount;
        } else if (ctx.quote == address(0)) {
            _nativeRefund = msg.value - _quoteAmount;
        }
        _depositToMarginAccount(_baseAmount, _quoteAmount);
        if (_nativeRefund > 0) {
            _sendToRecipient(_nativeRefund, address(0), msg.sender);
        }
        emit Events.ActiveVaultDeposit(msg.sender, _baseAmount, _quoteAmount, _shares);
        return _shares;
    }

    function withdraw(uint256 _shares) external nonReentrant returns (uint256, uint256) {
        require(_shares > 0, Errors.SharesBurnedZero());
        require(lastDepositTime[msg.sender] + unlockInterval < block.timestamp, Locked());
        (uint256 _restingBaseAmount, uint256 _restingQuoteAmount) = getRestingBalances();
        (uint256 _postedBaseAmount, uint256 _postedQuoteAmount) = getPostedBalances();
        (uint256 _baseAmountForWithdraw, uint256 _quoteAmountForWithdraw) = _calculateAmountForShares(
            _shares,
            totalSupply(),
            _restingBaseAmount + _postedBaseAmount,
            _restingQuoteAmount + _postedQuoteAmount,
            false
        );
        if (_baseAmountForWithdraw > _restingBaseAmount || _quoteAmountForWithdraw > _restingQuoteAmount) {
            revert Errors.WithdrawalExceedsRestingBalance();
        }
        _burn(msg.sender, _shares);
        _withdrawFromMarginAccount(_baseAmountForWithdraw, _quoteAmountForWithdraw, msg.sender);
        emit Events.ActiveVaultWithdraw(msg.sender, _baseAmountForWithdraw, _quoteAmountForWithdraw, _shares);
        return (_baseAmountForWithdraw, _quoteAmountForWithdraw);
    }

    // ================== accounting ===================

    function calculateNotionalValue() public view returns (uint256, uint256) {
        (uint256 _baseAmountResting, uint256 _quoteAmountResting) = getRestingBalances();
        (uint256 _baseAmountPosted, uint256 _quoteAmountPosted) = getPostedBalances();
        return (_baseAmountResting + _baseAmountPosted, _quoteAmountResting + _quoteAmountPosted);
    }

    function getRestingBalances() public view returns (uint256 baseAmount, uint256 quoteAmount) {
        baseAmount = marginAccount.getBalance(address(this), ctx.base);
        quoteAmount = marginAccount.getBalance(address(this), ctx.quote);
    }

    function getPostedBalances() public view returns (uint256 baseAmountPosted, uint256 quoteAmountPosted) {
        uint40 current = ctx.head;
        uint40 tail = ctx.tail;
        if (current == 0) return (0, 0);
        while (current <= tail) {
            (uint256 _orderValue, bool _isBuy) = calculateCurrentOrderValue(current);
            if (_isBuy) {
                quoteAmountPosted += _orderValue;
            } else {
                baseAmountPosted += _orderValue;
            }
            current++;
        }
    }

    function calculateCurrentOrderValue(uint40 _orderId) internal view returns (uint256, bool) {
        (, uint96 _size,,,, uint32 _price,, bool _isBuy) = ctx.book.s_orders(_orderId);
        (uint40 _ppHead,) = _isBuy ? ctx.book.s_buyPricePoints(_price) : ctx.book.s_sellPricePoints(_price);
        if (_ppHead > _orderId) {
            return (0, _isBuy);
        }
        uint256 _orderValue;
        if (_isBuy) {
            _orderValue = ((uint256(_price) * _size / ctx.sizePrecision) * 10 ** ctx.quoteDecimals) / ctx.pricePrecision;
        } else {
            _orderValue = (uint256(_size) * 10 ** ctx.baseDecimals) / ctx.sizePrecision;
        }
        return (_orderValue, _isBuy);
    }

    // ============ gas crank functions ============

    function crankGas(uint256 _baseWithdraw, uint256 _quoteWithdraw) external {
        _verifyGasCrank();
        if (block.timestamp < lastCrankTime + gasCrankCooldown) {
            revert Errors.GasCrankCooldown();
        }
        (uint256 _baseAmountTotal, uint256 _quoteAmountTotal) = calculateNotionalValue();
        uint256 _baseAmountMaxWithdrawable = _baseAmountTotal * gasFeeOutMax / 10000;
        uint256 _quoteAmountMaxWithdrawable = _quoteAmountTotal * gasFeeOutMax / 10000;
        if (_baseWithdraw > _baseAmountMaxWithdrawable || _quoteWithdraw > _quoteAmountMaxWithdrawable) {
            revert Errors.GasCrankWithdrawExceedsMax();
        }
        lastCrankTime = block.timestamp;
        _withdrawFromMarginAccount(_baseWithdraw, _quoteWithdraw, gasCrank);
        emit Events.GasCrankWithdraw(gasCrank, _baseWithdraw, _quoteWithdraw);
    }

    // ============ market making functions ============

    function cancelAllReplace(
        uint32[] calldata buyPrices,
        uint32[] calldata sellPrices,
        uint96[] calldata buySizes,
        uint96[] calldata sellSizes
    ) external {
        _verifyOperator();
        if (buyPrices.length != buySizes.length || sellPrices.length != sellSizes.length) {
            revert Errors.InvalidLength();
        }
        MarketParams memory _ctx = ctx;
        if (_ctx.head != 0) {
            uint40[] memory _cancelIds = new uint40[](_ctx.tail - _ctx.head + 1);
            for (uint40 i = _ctx.head; i <= _ctx.tail; i++) {
                _cancelIds[i - _ctx.head] = i;
            }
            _ctx.book.batchUpdate(new uint32[](0), new uint96[](0), new uint32[](0), new uint96[](0), _cancelIds, true);
        }
        if (buyPrices.length > 0 || sellPrices.length > 0) {
            uint40 _oldCounter = _ctx.book.s_orderIdCounter();
            try _ctx.book.batchUpdate(buyPrices, buySizes, sellPrices, sellSizes, new uint40[](0), true) {
                uint40 _newCounter = _ctx.book.s_orderIdCounter();
                ctx.head = _oldCounter + 1;
                ctx.tail = _newCounter;
            } catch {
                ctx.head = 0;
                ctx.tail = 0;
            }
        } else {
            ctx.head = 0;
            ctx.tail = 0;
        }
    }

    // ============ Internal Functions ============

    function _withdrawFromMarginAccount(uint256 _baseAmount, uint256 _quoteAmount, address _recipient) internal {
        address _base = ctx.base;
        address _quote = ctx.quote;
        _withdrawFromMarginAccountSingle(_baseAmount, _base);
        _withdrawFromMarginAccountSingle(_quoteAmount, _quote);
        _sendToRecipient(_baseAmount, _base, _recipient);
        _sendToRecipient(_quoteAmount, _quote, _recipient);
    }

    function _depositToMarginAccount(uint256 _baseAmount, uint256 _quoteAmount) internal {
        address _base = ctx.base;
        address _quote = ctx.quote;
        if (_base != address(0)) {
            _receiveTokensFromAddress(_base, _baseAmount);
        }
        if (_quote != address(0)) {
            _receiveTokensFromAddress(_quote, _quoteAmount);
        }
        _depositToMarginAccountSingle(_baseAmount, _base);
        _depositToMarginAccountSingle(_quoteAmount, _quote);
    }

    function _currentBalance(address _token, bool _includeMsgValue) internal view returns (uint256) {
        if (_token == address(0)) {
            return address(this).balance - (_includeMsgValue ? msg.value : 0);
        }
        return IERC20Metadata(_token).balanceOf(address(this));
    }

    function _withdrawFromMarginAccountSingle(uint256 _amount, address _token) internal {
        marginAccount.withdraw(_amount, _token);
    }

    function _receiveTokensFromAddress(address _token, uint256 _amount) internal {
        _token.safeTransferFrom(msg.sender, address(this), _amount);
    }

    function _sendToRecipient(uint256 _amount, address _token, address _recipient) internal {
        if (_token == address(0)) {
            _recipient.safeTransferETH(_amount);
            return;
        }
        _token.safeTransfer(_recipient, _amount);
    }

    function _depositToMarginAccountSingle(uint256 _amount, address _token) internal {
        if (_token == address(0)) {
            marginAccount.deposit{value: _amount}(address(this), _token, _amount);
            return;
        }
        marginAccount.deposit(address(this), _token, _amount);
    }

    function _populateCtx(address _targetMarket) internal {
        ctx.book = IOrderBook(_targetMarket);
        (
            uint32 pricePrecision,
            uint96 sizePrecision,
            address base,
            uint256 baseDecimals,
            address quote,
            uint256 quoteDecimals,
            ,
            ,
            ,
            ,
        ) = ctx.book.getMarketParams();
        ctx.pricePrecision = pricePrecision;
        ctx.sizePrecision = sizePrecision;
        ctx.base = base;
        ctx.baseDecimals = uint8(baseDecimals);
        ctx.quote = quote;
        ctx.quoteDecimals = uint8(quoteDecimals);
    }

    function toU96(uint256 _from) internal pure returns (uint96 _to) {
        require((_to = uint96(_from)) == _from, Errors.Uint96Overflow());
    }

    receive() external payable {}
}
