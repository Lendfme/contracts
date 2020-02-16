pragma solidity ^0.4.24;

import "../../../contracts/Exponential.sol";

contract testRateModel is Exponential {
    uint constant blocksPerYear = 2102400;

    enum IRError {
        NO_ERROR,
        FAILED_TO_ADD_CASH_PLUS_BORROWS,
        FAILED_TO_GET_EXP,
        FAILED_TO_MUL_PRODUCT_TIMES_BORROW_RATE
    }

    function powDecimal(uint utilizationRate, uint power) pure internal returns (Error, uint) {

        uint result = utilizationRate;
        Error err0;
        uint decimal = 10**18;
        uint i = 1;
        while(i < power){

            if(power - i > 2){

                (err0, result) = mul(result, utilizationRate ** 3);
                if (err0 != Error.NO_ERROR)
                    return (err0, 0);

                result = result / decimal ** 3;
                i += 3;
            }else if(power - i > 1){

                (err0, result) = mul(result, utilizationRate ** 2);
                if (err0 != Error.NO_ERROR)
                    return (err0, 0);

                result = result / decimal ** 2;
                i += 2;
            }else {

                (err0, result) = mul(result, utilizationRate);
                if (err0 != Error.NO_ERROR)
                    return (err0, 0);

                result = result / decimal;
                i++;
            }
        }

        return (err0, result);
    }

    /*
     * @dev Calculates the utilization and borrow rates for use by get{Supply,Borrow}Rate functions
     */
    function getUtilizationAndAnnualBorrowRate(uint ur) pure internal returns (IRError, Exp memory, Exp memory) {
        // (IRError err0, Exp memory utilizationRate) = getUtilizationRate(cash, borrows);
        // if (err0 != IRError.NO_ERROR) {
        //     return (err0, Exp({mantissa: 0}), Exp({mantissa: 0}));
        // }
        Exp memory utilizationRate = Exp({mantissa: ur});

        if (utilizationRate.mantissa >= 75e16 && utilizationRate.mantissa <= 85e16)
            return (IRError.NO_ERROR, utilizationRate, Exp({mantissa: 63835754242258350}));

        /**
         *  Borrow Rate
         *  0 < UR < 75% :      0.06 * UR + 0.05 * UR^4 + 0.03 * UR^8 + 0.12 * UR^32
         *  75% <= UR <= 85% :  0.06 * 0.75 + 0.05 * 0.75^4 + 0.03 * 0.75^8 + 0.12 * 0.75^32
         *  85% < UR :          0.06 * UR + 0.05 * UR^12 + 0.03 * UR^8 + 0.12 * UR^32
         */
        Error err;
        uint annualBorrowRateScaled;
        (err, annualBorrowRateScaled) = mul(utilizationRate.mantissa, 6);
        assert(err == Error.NO_ERROR);

        uint temp;
        uint base;

        (err, base) = powDecimal(utilizationRate.mantissa, 4);
        assert(err == Error.NO_ERROR);

        (err, temp) = mul(utilizationRate.mantissa > 85e16 ? base**3 / 10**36 : base, 5);
        assert(err == Error.NO_ERROR);

        (err, annualBorrowRateScaled) = add(annualBorrowRateScaled, temp);
        assert(err == Error.NO_ERROR);

        (err, temp) = mul(base**2 / 10**18, 3);
        assert(err == Error.NO_ERROR);

        (err, annualBorrowRateScaled) = add(annualBorrowRateScaled, temp);
        assert(err == Error.NO_ERROR);

        (err, base) = powDecimal(base**2 / 10**18, 4);
        assert(err == Error.NO_ERROR);

        (err, temp) = mul(base, 12);
        assert(err == Error.NO_ERROR);

        (err, annualBorrowRateScaled) = add(annualBorrowRateScaled, temp);
        assert(err == Error.NO_ERROR);

        return (IRError.NO_ERROR, utilizationRate, Exp({mantissa: annualBorrowRateScaled / 100}));
    }


    function getSupplyRate(uint ur) public view returns (uint, uint) {
        // _asset; // pragma ignore unused argument

        (IRError err0, Exp memory utilizationRate0, Exp memory annualBorrowRate) = getUtilizationAndAnnualBorrowRate(ur);
        if (err0 != IRError.NO_ERROR) {
            return (uint(err0), 0);
        }

        /**
         *  Supply Rate
         *  0 < UR < 75% :  0.98 * BorrowRate
         *  75% <= UR :     0.99 * BorrowRate
         */
        uint oneMinusSpreadBasisPoints = utilizationRate0.mantissa >= 75e16 ? 9900 : 9800;

        // We're going to multiply the utilization rate by the spread's numerator
        (Error err1, Exp memory utilizationRate1) = mulScalar(utilizationRate0, oneMinusSpreadBasisPoints);
        // mulScalar only overflows when product is greater than or equal to 2^256.
        // utilization rate's mantissa is a number between [0e18,1e18]. That means that
        // utilizationRate1 is a value between [0e18,8.5e21]. This is strictly less than 2^256.
        assert(err1 == Error.NO_ERROR);

        // Next multiply this product times the borrow rate
        (Error err2, Exp memory supplyRate0) = mulExp(utilizationRate1, annualBorrowRate);
        // If the product of the mantissas for mulExp are both less than 2^256,
        // then this operation will never fail. TODO: Verify.
        // We know that borrow rate is in the interval [0, 2.25e17] from above.
        // We know that utilizationRate1 is in the interval [0, 9e21] from directly above.
        // As such, the multiplication is in the interval of [0, 2.025e39]. This is strictly
        // less than 2^256 (which is about 10e77).
        assert(err2 == Error.NO_ERROR);

        // And then divide down by the spread's denominator (basis points divisor)
        // as well as by blocks per year.
        (Error err3, Exp memory supplyRate1) = divScalar(supplyRate0, 10000 * blocksPerYear); // basis points * blocks per year
        // divScalar only fails when divisor is zero. This is clearly not the case.
        assert(err3 == Error.NO_ERROR);

        return (uint(IRError.NO_ERROR), supplyRate1.mantissa);

    }

    function getBorrowRate(uint ur) public view returns (uint, uint) {

        (IRError err0, Exp memory _utilizationRate, Exp memory annualBorrowRate) = getUtilizationAndAnnualBorrowRate(ur);
        if (err0 != IRError.NO_ERROR) {
            return (uint(err0), 0);
        }

        // And then divide down by blocks per year.
        (Error err1, Exp memory borrowRate) = divScalar(annualBorrowRate, blocksPerYear); // basis points * blocks per year
        // divScalar only fails when divisor is zero. This is clearly not the case.
        assert(err1 == Error.NO_ERROR);

        // Note: mantissa is the rate scaled 1e18, which matches the expected result
        return (uint(IRError.NO_ERROR), borrowRate.mantissa);
    }
}


