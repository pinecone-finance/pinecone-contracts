// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./libraries/SafeMath.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IPancakePair.sol";
import "./interfaces/IPancakeFactory.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract SmartRouter is OwnableUpgradeable {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address public constant BSW = 0x965F527D9159dCe6288a2219DB51fc6Eef120dD1;
    address public constant ALPACA = 0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F;

    address public constant CAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant BSW_ROUTER = 0x3a6d8cA21D1CF76F653A67577FA0D27453350dD8;

    uint256 private constant UNIT = 1e18;

    uint256 public minSlippage;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    function initialize() external initializer {
        __Ownable_init();
        minSlippage = 1e16; //1%
    }

    function setMinSlippage(uint256 _minSlippage) external onlyOwner {
        minSlippage = _minSlippage;
    }

    function getAmountOutAndSlippage(
        uint256 amount, 
        address inToken, 
        address outToken
    ) public view 
        returns (
            uint256 amountOut, 
            uint256 slippage
        ) 
    {
        if (amount == 0) {
            return (0, 0);
        }

        if (inToken == BSW || outToken == BSW) {
            return getAmountOutAndSlippage(amount, tokenPath(inToken, outToken), BSW_ROUTER);
        } else {
            return getAmountOutAndSlippage(amount, tokenPath(inToken, outToken), CAKE_ROUTER);
        }
    }

    function getAmountOutAndSlippage(
        uint256 amount, 
        address [] memory path,
        address router
    ) public view
        returns (
            uint256 amountOut, 
            uint256 slippage
        )  
    {
        if (amount == 0) {
            return (0, 0);
        }

        require(path.length > 1, "path.length <= 1");
        slippage = 0;
        uint256 amountIn = amount;
        for (uint256 i = 0; i < path.length - 1; ++i) {
            (uint256 amt, uint256 slip) = getAmountOutAndSlippage(amountIn, path[i], path[i+1], router);
            amountIn = amt;
            slippage = slippage.add(slip);
            if (i == path.length - 2) {
                amountOut = amt;
            }
        }
    }

    function getAmountOutAndSlippage(
        uint256 amount,
        address inToken,
        address outToken,
        address router
    ) public view
        returns (
            uint256 amountOut,
            uint256 slippage
        )
    {
        if (amount == 0) {
            return (0, 0);
        }

        address factory = IPancakeRouter02(router).factory();
        address pair = IPancakeFactory(factory).getPair(inToken, outToken);
        require(pair != address(0), "pair == address(0)");
        (uint256 r0, uint256 r1, ) = IPancakePair(pair).getReserves();
        if (r1 == 0 || r0 == 0) {
            return (0, UNIT);
        }
        (r0, r1) = (IPancakePair(pair).token0() == inToken) ? (r0, r1) : (r1, r0);
        amountOut = IPancakeRouter02(router).getAmountOut(amount, r0, r1);

        uint256 noSlippageOut = r1.mul(amount).div(r0);
        slippage = noSlippageOut.sub(amountOut).mul(UNIT).div(noSlippageOut);
    }

    function getAmountOut(
        uint256 amount, 
        address token0, 
        address token1, 
        bool optimize
    ) public view 
        returns (uint256) 
    {
        if (token0 == BSW || token1 == BSW) {
            if (optimize) {
                if (token0 == ALPACA || token1 == ALPACA) {
                    (uint256 amountOut, uint256 slippage) = getAmountOutAndSlippage(amount, tokenPath(token0, token1), BSW_ROUTER);
                    if (slippage < minSlippage) {
                        return amountOut;
                    } else {
                        if (token0 == ALPACA) {
                            //ALPACA => WBNB on CAKE_ROUTER
                            uint256 bnbAmt = getAmountOut(amount, ALPACA, WBNB, CAKE_ROUTER);
                            //WBNB => BSW on BSW_ROUTER
                            return getAmountOut(bnbAmt, WBNB, BSW, BSW_ROUTER);
                        } else {
                            //BSW => WBNB on BSW_ROUTER
                            uint256 bnbAmt = getAmountOut(amount, BSW, WBNB, BSW_ROUTER);
                            //WBNB => ALPACA on CAKE_ROUTER
                            return getAmountOut(bnbAmt, WBNB, ALPACA, CAKE_ROUTER);
                        }
                    }
                } else {
                    return getAmountOut(amount, token0, token1, BSW_ROUTER);
                }
            } else {
                return getAmountOut(amount, token0, token1, BSW_ROUTER);
            }
        } else {
            return getAmountOut(amount, token0, token1, CAKE_ROUTER);
        }
    }

    function getAmountOut(
        uint256 amount, 
        address token0, 
        address token1, 
        address router
    ) public view 
        returns (uint256) 
    {
        if (amount == 0) {
            return 0;
        }
        if (token0 == token1) {
            return amount;
        }

        uint256[] memory amounts = IPancakeRouter02(router).getAmountsOut(amount, tokenPath(token0, token1));
        if (amounts.length == 0) {
            return 0;
        }
        return amounts[amounts.length - 1];
    }

    function tokenPath(address _token0, address _token1) public pure returns(address[] memory path) {
        require(_token0 != _token1, "_token0 == _token1");
        if (_token0 == ALPACA) {
            if (_token1 == BUSD) {
                path = new address[](2);
                path[0] = _token0;
                path[1] = _token1;
            } else if (_token1 == WBNB) {
                path = new address[](3);
                path[0] = _token0;
                path[1] = BUSD;
                path[2] = _token1;
            } else {
                path = new address[](4);
                path[0] = _token0;
                path[1] = BUSD;
                path[2] = WBNB;
                path[3] = _token1;
            }
        } else if (_token1 == ALPACA) {
            if (_token0 == BUSD) {
                path = new address[](2);
                path[0] = _token0;
                path[1] = _token1;
            } else if (_token0 == WBNB) {
                path = new address[](3);
                path[0] = _token0;
                path[1] = BUSD;
                path[2] = _token1;
            } else {
                path = new address[](4);
                path[0] = _token0;
                path[1] = WBNB;
                path[2] = BUSD;
                path[3] = _token1;
            }
        } else {
            if (_token0 == WBNB || _token1 == WBNB) {
                path = new address[](2);
                path[0] = _token0;
                path[1] = _token1;
            } else {
                if (_token0 == BSW || _token1 == BSW) {
                    if (_token0 == USDT || _token1 == USDT) {
                        path = new address[](2);
                        path[0] = _token0;
                        path[1] = _token1;
                    } else {
                        path = new address[](3);
                        path[0] = _token0;
                        path[1] = WBNB;
                        path[2] = _token1;
                    }
                } else {
                    path = new address[](3);
                    path[0] = _token0;
                    path[1] = WBNB;
                    path[2] = _token1;
                }
            }
        }
    }
}