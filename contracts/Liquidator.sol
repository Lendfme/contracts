pragma solidity ^0.4.24;

import "./EIP20Interface.sol";
import "./EIP20NonStandardInterface.sol";
import "./ErrorReporter.sol";
import "./InterestRateModel.sol";
import "./SafeToken.sol";

contract LiquidationChecker {
    function setAllowLiquidation(bool allowLiquidation_) public;
}

contract MoneyMarket{
    /**
     * @dev Container for per-asset balance sheet and interest rate information written to storage, intended to be stored in a map where the asset address is the key
     *
     *      struct Market {
     *         isSupported = Whether this market is supported or not (not to be confused with the list of collateral assets)
     *         blockNumber = when the other values in this struct were calculated
     *         totalSupply = total amount of this asset supplied (in asset wei)
     *         supplyRateMantissa = the per-block interest rate for supplies of asset as of blockNumber, scaled by 10e18
     *         supplyIndex = the interest index for supplies of asset as of blockNumber; initialized in _supportMarket
     *         totalBorrows = total amount of this asset borrowed (in asset wei)
     *         borrowRateMantissa = the per-block interest rate for borrows of asset as of blockNumber, scaled by 10e18
     *         borrowIndex = the interest index for borrows of asset as of blockNumber; initialized in _supportMarket
     *     }
     */
    struct Market {
        bool isSupported;
        uint blockNumber;
        InterestRateModel interestRateModel;

        uint totalSupply;
        uint supplyRateMantissa;
        uint supplyIndex;

        uint totalBorrows;
        uint borrowRateMantissa;
        uint borrowIndex;
    }

    /**
     * @dev map: assetAddress -> Market
     */
    mapping(address => Market) public markets;

    /**
     * @notice users repay all or some of an underwater borrow and receive collateral
     * @param targetAccount The account whose borrow should be liquidated
     * @param assetBorrow The market asset to repay
     * @param assetCollateral The borrower's market asset to receive in exchange
     * @param requestedAmountClose The amount to repay (or -1 for max)
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function liquidateBorrow(address targetAccount, address assetBorrow, address assetCollateral, uint requestedAmountClose) public returns (uint);

    /**
     * @notice withdraw `amount` of `asset` from sender's account to sender's address
     * @dev withdraw `amount` of `asset` from msg.sender's account to msg.sender
     * @param asset The market asset to withdraw
     * @param requestedAmount The amount to withdraw (or -1 for max)
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function withdraw(address asset, uint requestedAmount) public returns (uint);

    /**
     * @notice return supply balance with any accumulated interest for `asset` belonging to `account`
     * @dev returns supply balance with any accumulated interest for `asset` belonging to `account`
     * @param account the account to examine
     * @param asset the market asset whose supply balance belonging to `account` should be checked
     * @return uint supply balance on success, throws on failed assertion otherwise
     */
    function getSupplyBalance(address account, address asset) view public returns (uint);

    /**
     * @notice return borrow balance with any accumulated interest for `asset` belonging to `account`
     * @dev returns borrow balance with any accumulated interest for `asset` belonging to `account`
     * @param account the account to examine
     * @param asset the market asset whose borrow balance belonging to `account` should be checked
     * @return uint borrow balance on success, throws on failed assertion otherwise
     */
    function getBorrowBalance(address account, address asset) view public returns (uint);
}

contract Liquidator is ErrorReporter, SafeToken {
    MoneyMarket public moneyMarket;

    constructor(address moneyMarket_) public {
        moneyMarket = MoneyMarket(moneyMarket_);
    }

    event BorrowLiquidated(address targetAccount,
        address assetBorrow,
        uint borrowBalanceBefore,
        uint borrowBalanceAccumulated,
        uint amountRepaid,
        uint borrowBalanceAfter,
        address liquidator,
        address assetCollateral,
        uint collateralBalanceBefore,
        uint collateralBalanceAccumulated,
        uint amountSeized,
        uint collateralBalanceAfter);

    function liquidateBorrow(address targetAccount, address assetBorrow, address assetCollateral, uint requestedAmountClose) public returns (uint) {
        require(targetAccount != address(this), "FAILED_LIQUIDATE_LIQUIDATOR");
        require(targetAccount != msg.sender, "FAILED_LIQUIDATE_SELF");
        require(msg.sender != address(this), "FAILED_LIQUIDATE_RECURSIVE");
        require(assetBorrow != assetCollateral, "FAILED_LIQUIDATE_IN_KIND");

        InterestRateModel interestRateModel;
        (,,interestRateModel,,,,,,) = moneyMarket.markets(assetBorrow);

        require(interestRateModel != address(0), "FAILED_LIQUIDATE_NO_INTEREST_RATE_MODEL");
        require(checkTransferIn(assetBorrow, msg.sender, requestedAmountClose) == Error.NO_ERROR, "FAILED_LIQUIDATE_TRANSFER_IN_INVALID");

        require(doTransferIn(assetBorrow, msg.sender, requestedAmountClose) == Error.NO_ERROR, "FAILED_LIQUIDATE_TRANSFER_IN_FAILED");

        tokenAllowAll(assetBorrow, moneyMarket);

        LiquidationChecker(interestRateModel).setAllowLiquidation(true);

        uint result = moneyMarket.liquidateBorrow(targetAccount, assetBorrow, assetCollateral, requestedAmountClose);

        require(moneyMarket.withdraw(assetCollateral, uint(-1)) == uint(Error.NO_ERROR), "FAILED_LIQUIDATE_WITHDRAW_FAILED");

        LiquidationChecker(interestRateModel).setAllowLiquidation(false);

        // Ensure there's no remaining balances here
        require(moneyMarket.getSupplyBalance(address(this), assetCollateral) == 0, "FAILED_LIQUIDATE_REMAINING_SUPPLY_COLLATERAL"); // just to be sure
        require(moneyMarket.getSupplyBalance(address(this), assetBorrow) == 0, "FAILED_LIQUIDATE_REMAINING_SUPPLY_BORROW"); // just to be sure
        require(moneyMarket.getBorrowBalance(address(this), assetCollateral) == 0, "FAILED_LIQUIDATE_REMAINING_BORROW_COLLATERAL"); // just to be sure
        require(moneyMarket.getBorrowBalance(address(this), assetBorrow) == 0, "FAILED_LIQUIDATE_REMAINING_BORROW_BORROW"); // just to be sure

        // Transfer out everything remaining
        tokenTransferAll(assetCollateral, msg.sender);
        tokenTransferAll(assetBorrow, msg.sender);

        return uint(result);
    }

    function tokenAllowAll(address asset, address allowee) internal {
        EIP20Interface token = EIP20Interface(asset);

        if (token.allowance(address(this), allowee) != uint(-1))
            // require(token.approve(allowee, uint(-1)), "FAILED_LIQUIDATE_ASSET_ALLOWANCE_FAILED");
            require(doApprove(asset, allowee, uint(-1)) == Error.NO_ERROR, "FAILED_LIQUIDATE_ASSET_ALLOWANCE_FAILED");
    }

    function tokenTransferAll(address asset, address recipient) internal {
        uint balance = getBalanceOf(asset, address(this));

        if (balance > 0){
            require(doTransferOut(asset, recipient, balance) == Error.NO_ERROR, "FAILED_LIQUIDATE_TRANSFER_OUT_FAILED");
        }
    }
}
