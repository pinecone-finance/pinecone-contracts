// SPDX-License-Identifier: MIT
pragma solidity ^0.6.2;

import "./SafeMath.sol";


library SafeDecimal {
    using SafeMath for uint256;

    uint8 public constant decimals = 18;
    uint256 public constant UNIT = 10 ** uint256(decimals);

    function unit() external pure returns (uint256) {
        return UNIT;
    }

    function multiply(uint256 x, uint256 y) internal pure returns (uint256) {
        return x.mul(y).div(UNIT);
    }

    // https://mpark.github.io/programming/2014/08/18/exponentiation-by-squaring/
    function power(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 result = UNIT;
        while (n > 0) {
            if (n % 2 != 0) {
                result = multiply(result, x);
            }
            x = multiply(x, x);
            n /= 2;
        }
        return result;
    }
}