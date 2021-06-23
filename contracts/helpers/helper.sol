// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../interfaces/IPancakeRouter02.sol";
import "../interfaces/IPancakeFactory.sol";
import "../libraries/SafeERC20.sol";
import "../interfaces/IWETH.sol";
import "../libraries/SafeMath.sol";

contract helper {
    
    IPancakeFactory private constant factory = IPancakeFactory(0x6725F303b657a9451d8BA641348b6761A6CC7a17);
    IPancakeRouter02 private constant router = IPancakeRouter02(0xD99D1c33F9fC3444f8101754aBC46c52416550D1);
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    address private constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    
    event CreatePair(address pair, address token0, address token1);
    
    function createPair(address token0, address token1) public returns(address pair) {
        pair = factory.getPair(token0, token1);
        if (pair == address(0)) {
            pair = factory.createPair(token0, token1);
            require(pair != address(0), "pair == address(0)");    
        }
        
        emit CreatePair(pair, token0, token1);
    }
    

    function addLiquidityEth(address token, uint256 tokenAmount, uint256 ethAmount) public payable {
        require(msg.value == ethAmount, "ethAmount != msg.value");
        
        IERC20(token).safeTransferFrom(
            address(msg.sender),
            address(this),
            tokenAmount
        );
        _safeApprove(token, address(router));
        _safeApprove(WBNB, address(router));
        IWETH(WBNB).deposit{value: msg.value}();
        
        tokenAmount = IERC20(token).balanceOf(address(this));
    
        // add the liquidity
        IPancakeRouter02(router).addLiquidity(
            WBNB,
            token,
            ethAmount,
            tokenAmount,
            0,
            0,
            msg.sender,
            now + 60
        );
    }

    function addLiquidity(address token0, address token1, uint256 token0Amount, uint256 token1Amount) public {        
        IERC20(token0).safeTransferFrom(
            address(msg.sender),
            address(this),
            token0Amount
        );

        IERC20(token1).safeTransferFrom(
            address(msg.sender),
            address(this),
            token1Amount
        );

        token0Amount = IERC20(token0).balanceOf(address(this));
        token1Amount = IERC20(token1).balanceOf(address(this));

        _safeApprove(token0, address(router));
        _safeApprove(token1, address(router));
    
        // add the liquidity
        IPancakeRouter02(router).addLiquidity(
            token0,
            token1,
            token0Amount,
            token1Amount,
            0,
            0,
            msg.sender,
            now + 60
        );
    }

    function removeLiquidityEth(address lpToken, address token) public {
        uint256 balance = IERC20(lpToken).balanceOf(msg.sender);
        IERC20(lpToken).safeTransferFrom(
            address(msg.sender),
            address(this),
            balance
        );
        _safeApprove(lpToken, address(router));
        
        require(balance > 0, "lpToken balance == 0");
        IPancakeRouter02(router).removeLiquidityETH(
            token,
            balance,
            0,
            0,
            msg.sender,
            now + 60
        );
    }

    function removeLiquidity(address lpToken, address token0, address token1) public {
        uint256 balance = IERC20(lpToken).balanceOf(msg.sender);
        IERC20(lpToken).safeTransferFrom(
            address(msg.sender),
            address(this),
            balance
        );
        _safeApprove(lpToken, address(router));
        
        require(balance > 0, "lpToken balance == 0");
        IPancakeRouter02(router).removeLiquidity(
            token0,
            token1,
            balance,
            0,
            0,
            msg.sender,
            now + 60
        );
    }

    function swapEthTo(address token, uint256 ethAmount, address to) public payable {
        require(msg.value == ethAmount, "ethAmount != msg.value");
    
        _safeApprove(token, address(router));
        _safeApprove(WBNB, address(router));
        IWETH(WBNB).deposit{value: msg.value}();
        
        address[] memory  path = new address[](2);
        path[0] = WBNB;
        path[1] = token;

        IPancakeRouter02(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
            ethAmount,
            0,
            path,
            to,
            now + 60
        );
    }

    function swapTo(address inToken, address outToken, uint256 inAmt, address to) public {
        IERC20(inToken).safeTransferFrom(
            address(msg.sender),
            address(this),
            inAmt
        );

        inAmt = IERC20(inToken).balanceOf(address(this));

        _safeApprove(inToken, address(router));
        _safeApprove(outToken, address(router));

        address[] memory  path = new address[](2);
        path[0] = inToken;
        path[1] = outToken;

        IPancakeRouter02(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
            inAmt,
            0,
            path,
            to,
            now + 60
        );

        if (outToken == WBNB) {
            uint256 amount = IERC20(WBNB).balanceOf(address(this));
            IWETH(WBNB).withdraw(amount);
            SafeERC20.safeTransferETH(to, amount);
        }
    }

    function _safeApprove(address token, address spender) internal {
        if (token != address(0) && IERC20(token).allowance(address(this), spender) == 0) {
            IERC20(token).safeApprove(spender, uint256(~0));
        }
    }

    function withdrawBNB() public payable {
        msg.sender.transfer(address(this).balance);
    }

    function withdrawBEP20(address _tokenAddress) public payable {
        uint256 tokenBal = IERC20(_tokenAddress).balanceOf(address(this));
        IERC20(_tokenAddress).transfer(msg.sender, tokenBal);
    }

    receive() external payable {}
}