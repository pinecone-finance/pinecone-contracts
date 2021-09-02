// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "./IDashboard.sol";
import "./IPinecone.sol";

interface IPineconeConfig {
    function PCT() external view returns(address);
    function alpacaCalculator() external view returns(IAlpacaCalculator);
    function priceCalculator() external view returns(IPriceCalculator);
    function wexCalculator() external view returns(IWexCalculator);
    function pineconeFarm() external view returns(IPineconeFarm);
    function priceOfToken(address _token) external view returns(uint256);
    function priceOfPct() external view returns(uint256);
    function tokenAmountPctToMint(address _token, uint256 _profit) external view returns(uint256);
    function tokenAmountPctToMint(address _token, uint256 _profit, address _router) external view returns(uint256);
    function getAmountsOut(uint256 amount, address token0, address token1, address router) external view returns (uint256);
    function wNativeRelayer() external view returns (address);
    function rabbitCalculator() external view returns(IRabbitCalculator);
    function valueInBNB(address _token, uint256 _amount) external view returns(uint256);
}