// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface ISmartRouter {
    function getAmountOutAndSlippage(
        uint256 amount, 
        address inToken, 
        address outToken
    ) external view 
        returns (
            uint256 amountOut, 
            uint256 slippage
        );

    function getAmountOutAndSlippage(
        uint256 amount, 
        address [] memory path,
        address router
    ) external view
        returns (
            uint256 amountOut, 
            uint256 slippage
        );

    function getAmountOutAndSlippage(
        uint256 amount,
        address inToken,
        address outToken,
        address router
    ) external view
        returns (
            uint256 amountOut,
            uint256 slippage
        );

    function getAmountOut(
        uint256 amount, 
        address token0, 
        address token1, 
        bool optimize
    ) external view 
        returns (uint256);
    
    function getAmountOut(
        uint256 amount, 
        address token0, 
        address token1, 
        address router
    ) external view 
        returns (uint256);

    function tokenPath(
        address _token0, 
        address _token1
    ) external pure 
        returns(address[] memory path);

    function minSlippage() external view returns(uint256);
}