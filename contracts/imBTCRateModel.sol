pragma solidity ^0.4.24;

import "./Exponential.sol";
import "./InterestRateModel.sol";
import "./LiquidationChecker.sol";


contract MoneyMarket {
    function markets(address asset) public view returns (bool, uint, InterestRateModel, uint, uint, uint, uint, uint, uint);
    function oracle() public view returns (address);
}

contract PriceOracleProxy {
    address public mostRecentCaller;
    uint public mostRecentBlock;

    /**
     * @notice Gets the price of a given asset
     * @dev fetches the price of a given asset
     * @param asset Asset to get the price of
     * @return the price scaled by 10**18, or zero if the price is not available
     */
    function assetPrices(address asset) public returns (uint);
}

/**
 * @title The Lendf.Me Standard Interest Rate Model with LiquidationChecker
 * @author Lendf.Me
 */
contract ImBTCInterestRateModel is Exponential, LiquidationChecker {

    uint constant oneMinusSpreadBasisPoints = 9800;
    uint constant blocksPerYear = 2102400;
    // uint constant mantissaFivePercent = 5 * 10**16;
    uint public baseRate = 11200000000000000;
    uint public maxBaseRate = 60000000000000000;

    address public owner;
    address public newOwner;

    modifier onlyOwner() {
        require(msg.sender == owner, "non-owner");
        _;
    }

    enum IRError {
        NO_ERROR,
        FAILED_TO_ADD_CASH_PLUS_BORROWS,
        FAILED_TO_GET_EXP,
        FAILED_TO_MUL_PRODUCT_TIMES_BORROW_RATE
    }

    event OwnerUpdate(address indexed owner, address indexed newOwner);
    event LiquidatorUpdate(address indexed owner, address indexed newLiquidator, address indexed oldLiquidator);
    event BaseRateUpdate(address indexed owner, uint indexed newBaseRate, uint indexed oldBaseRate);
    event MaxBaseRateUpdate(address indexed owner, uint indexed newMaxBaseRate, uint indexed oldMaxBaseRate);

    constructor(address moneyMarket, address liquidator) LiquidationChecker(moneyMarket, liquidator) {
        owner = msg.sender;
    }

    function transferOwnership(address newOwner_) external onlyOwner {
        require(newOwner_ != owner, "TransferOwnership: the same owner.");
        newOwner = newOwner_;
    }

    function acceptOwnership() external {
        require(msg.sender == newOwner, "AcceptOwnership: only new owner do this.");
        emit OwnerUpdate(owner, newOwner);
        owner = newOwner;
        newOwner = address(0x0);
    }

    function setLiquidator(address _liquidator) external onlyOwner {
        require(_liquidator != address(0), "setLiquidator: liquidator cannot be a zero address");
        require(liquidator != _liquidator, "setLiquidator: The old and new addresses cannot be the same");
        address oldLiquidator = liquidator;
        liquidator = _liquidator;
        emit LiquidatorUpdate(msg.sender, _liquidator, oldLiquidator);
    }

    function setMaxBaseRate(uint _maxBaseRate) external onlyOwner {
        require(_maxBaseRate != maxBaseRate, "setMaxBaseRate: the same maxBaseRate");
        require(_maxBaseRate <= 10**18, "setMaxBaseRate: maxBaseRate must be less than or equal to the 100%");
        uint oldMaxBaseRate = maxBaseRate;
        maxBaseRate = _maxBaseRate;
        emit MaxBaseRateUpdate(msg.sender, _maxBaseRate, oldMaxBaseRate);
    }

    function setBaseRate(uint _baseRate) external onlyOwner {
        require(_baseRate != baseRate, "setBaseRate: the same baseRate");
        require(_baseRate <= maxBaseRate, "setBaseRate: baseRate must be less than or equal to the maxBaseRate");
        uint oldBaseRate = baseRate;
        baseRate = _baseRate;
        emit BaseRateUpdate(msg.sender, _baseRate, oldBaseRate);
    }

    /**
     * @dev Calculates the utilization rate (borrows / (cash + borrows)) as an Exp
     */
    function getUtilizationRate(uint cash, uint borrows) pure internal returns (IRError, Exp memory) {
        if (borrows == 0) {
            // Utilization rate is zero when there's no borrows
            return (IRError.NO_ERROR, Exp({mantissa: 0}));
        }

        (Error err0, uint cashPlusBorrows) = add(cash, borrows);
        if (err0 != Error.NO_ERROR) {
            return (IRError.FAILED_TO_ADD_CASH_PLUS_BORROWS, Exp({mantissa: 0}));
        }

        (Error err1, Exp memory utilizationRate) = getExp(borrows, cashPlusBorrows);
        if (err1 != Error.NO_ERROR) {
            return (IRError.FAILED_TO_GET_EXP, Exp({mantissa: 0}));
        }

        return (IRError.NO_ERROR, utilizationRate);
    }

    /**
     * @dev Calculates the utilization and borrow rates for use by get{Supply,Borrow}Rate functions
     */
    function getUtilizationAndAnnualBorrowRate(uint cash, uint borrows) pure internal returns (IRError, Exp memory, Exp memory) {
        (IRError err0, Exp memory utilizationRate) = getUtilizationRate(cash, borrows);
        if (err0 != IRError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}), Exp({mantissa: 0}));
        }

        // Borrow Rate is UtilizationRate * 20%
        // 20% of utilizationRate, is `rate * 20 / 100`
        (Error err1, Exp memory utilizationRateMuled) = mulScalar(utilizationRate, 20);
        // `mulScalar` only overflows when the product is >= 2^256.
        // utilizationRate is a real number on the interval [0,1], which means that
        // utilizationRate.mantissa is in the interval [0e18,1e18], which means that 45 times
        // that is in the interval [0e18,45e18]. That interval has no intersection with 2^256, and therefore
        // this can never overflow. As such, we assert.
        assert(err1 == Error.NO_ERROR);

        (Error err2, Exp memory utilizationRateScaled) = divScalar(utilizationRateMuled, 100);
        // 100 is a constant, and therefore cannot be zero, which is the only error case of divScalar.
        assert(err2 == Error.NO_ERROR);

        // Add the 5% for (5% + 20% * Ua)
        // (Error err3, Exp memory annualBorrowRate) = addExp(utilizationRateScaled, Exp({mantissa: mantissaFivePercent}));
        // `addExp` only fails when the addition of mantissas overflow.
        // As per above, utilizationRateMuled is capped at 45e18,
        // and utilizationRateScaled is capped at 4.5e17. mantissaFivePercent = 0.5e17, and thus the addition
        // is capped at 5e17, which is less than 2^256.
        // assert(err3 == Error.NO_ERROR);

        return (IRError.NO_ERROR, utilizationRate, utilizationRateScaled);
    }

    /**
     * @notice Gets the current supply interest rate based on the given asset, total cash and total borrows
     * @dev The return value should be scaled by 1e18, thus a return value of
     *      `(true, 1000000000000)` implies an interest rate of 0.000001 or 0.0001% *per block*.
     * @param _asset The asset to get the interest rate of
     * @param cash The total cash of the asset in the market
     * @param borrows The total borrows of the asset in the market
     * @return Success or failure and the supply interest rate per block scaled by 10e18
     */
    function getSupplyRate(address _asset, uint cash, uint borrows) public view returns (uint, uint) {
        _asset; // pragma ignore unused argument

        (IRError err0, Exp memory utilizationRate0, Exp memory annualBorrowRate) = getUtilizationAndAnnualBorrowRate(cash, borrows);
        if (err0 != IRError.NO_ERROR) {
            return (uint(err0), 0);
        }

        // We're going to multiply the utilization rate by the spread's numerator
        (Error err1, Exp memory utilizationRate1) = mulScalar(utilizationRate0, oneMinusSpreadBasisPoints);
        // mulScalar only overflows when product is greater than or equal to 2^256.
        // utilization rate's mantissa is a number between [0e18,1e18]. That means that
        // utilizationRate1 is a value between [0e18,9e21]. This is strictly less than 2^256.
        assert(err1 == Error.NO_ERROR);

        // Next multiply this product times the borrow rate
        (Error err2, Exp memory supplyRate0) = mulExp(utilizationRate1, annualBorrowRate);
        // If the product of the mantissas for mulExp are both less than 2^256,
        // then this operation will never fail. TODO: Verify.
        // We know that borrow rate is in the interval [0, 4e17] from above.
        // We know that utilizationRate1 is in the interval [0, 9e21] from directly above.
        // As such, the multiplication is in the interval of [0, 3.6e39]. This is strictly
        // less than 2^256 (which is about 10e77).
        assert(err2 == Error.NO_ERROR);

        // And then divide down by the spread's denominator (basis points divisor)
        // as well as by blocks per year.
        (Error err3, Exp memory supplyRate1) = divScalar(supplyRate0, 10000 * blocksPerYear); // basis points * blocks per year
        // divScalar only fails when divisor is zero. This is clearly not the case.
        assert(err3 == Error.NO_ERROR);

        // Note: mantissa is the rate scaled 1e18, which matches the expected result
        return (uint(IRError.NO_ERROR), supplyRate1.mantissa + baseRate / blocksPerYear);
    }

    /**
     * @notice Gets the current borrow interest rate based on the given asset, total cash and total borrows
     * @dev The return value should be scaled by 1e18, thus a return value of
     *      `(true, 1000000000000)` implies an interest rate of 0.000001 or 0.0001% *per block*.
     * @param asset The asset to get the interest rate of
     * @param cash The total cash of the asset in the market
     * @param borrows The total borrows of the asset in the market
     * @return Success or failure and the borrow interest rate per block scaled by 10e18
     */
    function getBorrowRate(address asset, uint cash, uint borrows) public returns (uint, uint) {
        require(isAllowed(asset, cash));

        (IRError err0, Exp memory _utilizationRate, Exp memory annualBorrowRate) = getUtilizationAndAnnualBorrowRate(cash, borrows);
        if (err0 != IRError.NO_ERROR) {
            return (uint(err0), 0);
        }

        // And then divide down by blocks per year.
        (Error err1, Exp memory borrowRate) = divScalar(annualBorrowRate, blocksPerYear); // basis points * blocks per year
        // divScalar only fails when divisor is zero. This is clearly not the case.
        assert(err1 == Error.NO_ERROR);

        _utilizationRate; // pragma ignore unused variable

        // Note: mantissa is the rate scaled 1e18, which matches the expected result
        return (uint(IRError.NO_ERROR), borrowRate.mantissa + baseRate / blocksPerYear);
    }
}
