// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./IPancakeRouter02.sol";

interface IBiswapRouter02 is IPancakeRouter02 {
    function swapFeeReward() external pure returns (address);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut, uint swapFee) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut, uint swapFee) external pure returns (uint amountIn);
}