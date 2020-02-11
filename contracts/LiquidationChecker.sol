pragma solidity ^0.4.24;


contract EIP20Interface {
    function balanceOf(address _owner) public view returns (uint256 balance);
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

contract MoneyMarket {
    /**
     * @dev Account allowed to set oracle prices for this contract. Initially set
     *      in constructor, but can be changed by the admin.
     */
    address public oracle;
}

contract LiquidationChecker {
    MoneyMarket public moneyMarket;
    address public liquidator;
    bool public allowLiquidation;

    constructor(address moneyMarket_, address liquidator_) public {
        moneyMarket = MoneyMarket(moneyMarket_);
        liquidator = liquidator_;
        allowLiquidation = false;
    }

    function isAllowed(address asset, uint newCash) internal returns(bool) {
        return allowLiquidation || !isLiquidate(asset, newCash);
    }

    function isLiquidate(address asset, uint newCash) internal returns(bool) {
        return cashIsUp(asset, newCash) && oracleTouched();
    }

    function cashIsUp(address asset, uint newCash) internal view returns(bool) {
        uint oldCash = EIP20Interface(asset).balanceOf(moneyMarket);

        return newCash >= oldCash;
    }

    function oracleTouched() internal returns(bool) {
        PriceOracleProxy oracle = PriceOracleProxy(moneyMarket.oracle());

        bool sameOrigin = oracle.mostRecentCaller() == tx.origin;
        bool sameBlock = oracle.mostRecentBlock() == block.number;

        return sameOrigin && sameBlock;
    }

    function setAllowLiquidation(bool allowLiquidation_) public {
        require(msg.sender == liquidator, "LIQUIDATION_CHECKER_INVALID_LIQUIDATOR");

        allowLiquidation = allowLiquidation_;
    }
}
