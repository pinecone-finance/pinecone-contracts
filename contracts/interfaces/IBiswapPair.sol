// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2;

import "./IPancakePair.sol";

interface IBiswapPair is IPancakePair {
    function swapFee() external view returns (uint32);
    function devFee() external view returns (uint32);
    function setSwapFee(uint32) external;
    function setDevFee(uint32) external;
}