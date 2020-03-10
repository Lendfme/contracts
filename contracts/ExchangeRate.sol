pragma solidity =0.5.12;

contract PotLike {
    function chi() external view returns (uint256);
    function rho() external view returns (uint256);
    function dsr() external view returns (uint256);
}

contract ExchangeRateModel {

    address public owner;
    address public newOwner;
    PotLike public pot;

    address public token;

    uint constant public scale = 10 ** 27;

    event OwnerUpdate(address indexed owner, address indexed newOwner);
    event SetPot(address indexed owner, address indexed newPot, address indexed oldPot);

    modifier onlyOwner() {
        require(msg.sender == owner, "non-owner");
        _;
    }

    constructor(address _pot, address _token) public {
        owner = msg.sender;
        pot = PotLike(_pot);
        token = _token;
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

    function setPot(address _pot) external onlyOwner {
        require(_pot != address(0), "setPot: pot cannot be a zero address.");
        require(address(pot) != _pot, "setPot: The old and new addresses cannot be the same.");
        address _oldpot = address(pot);
        pot = PotLike(_pot);
        emit SetPot(owner, _pot, _oldpot);
    }

    // --- Math ---
    function rpow(uint x, uint n, uint base) internal pure returns (uint z) {
        assembly {
            switch x case 0 {switch n case 0 {z := base} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := base } default { z := x }
                let half := div(base, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, base)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }

    function safeMul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    function getExchangeRate() external view returns (uint) {
        return getFixedExchangeRate(now - pot.rho());
    }

    function getFixedExchangeRate(uint interval) public view returns (uint) {
        uint _scale = scale;
        return safeMul(rpow(pot.dsr(), interval, _scale), pot.chi()) / _scale;
    }

    function getFixedInterestRate(uint interval) external view returns (uint) {
        return rpow(pot.dsr(), interval, scale);
    }

    function getMaxSwingRate(uint interval) external view returns (uint) {
        return safeMul(getFixedExchangeRate(interval), scale) / pot.chi();
    }
}
