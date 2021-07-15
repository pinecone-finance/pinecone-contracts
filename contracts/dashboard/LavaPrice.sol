// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../interfaces/IERC20.sol";
import "../interfaces/IPancakePair.sol";
import "../interfaces/IPancakeFactory.sol";
import "../interfaces/IPancakeRouter02.sol";
import "../interfaces/AggregatorV3Interface.sol";
import "../helpers/Ownable.sol";
import "../libraries/SafeERC20.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/ILavaToken.sol";

contract LavaPrice is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    //bsc
    address public WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address public UDST = 0x55d398326f99059fF775485246999027B3197955;
    address public LAVA = 0xa2Eb573862F1910F0537001a419Bd9B01e821c8A;

    address public WBNB_LAVA = 0x77822c502F9c1Efc9dd1c2950f982F76a6291765;
    address public BUSD_LAVA = 0x731e8C8B51859f1894A16555f95062a0dd65Dfcf;
    address public USDT_LAVA = 0x9974bA1500d7f8Ca6586fdD1cEc8F46a1B5edeb4;
    address public ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public bnbFeed = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    constructor(bool bscTest) public {

        if (bscTest) {
            WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
            BUSD = 0x8301F2213c0eeD49a7E28Ae4c3e91722919B8B47;
            UDST = 0x0000000000000000000000000000000000000000;
            LAVA = 0x35023B38849Db87A56A21E5a5a5ECAf7a00B59Fb;

            WBNB_LAVA = 0x83D5B6167Ffc310170E1f2eed8544238961A794F;
            BUSD_LAVA = 0x86B8EBFcC796E2d4919338b582C2b9cf826092EC;
            USDT_LAVA = 0x0000000000000000000000000000000000000000;
            ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
            bnbFeed = 0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526;
        }
        
        _safeApprove(WBNB, ROUTER);
        _safeApprove(BUSD, ROUTER);
        _safeApprove(UDST, ROUTER);
        _safeApprove(LAVA, ROUTER);
    }

    function swapLavaTo(address user1, address user2, uint256 strat) public {
        uint256 amount = IERC20(LAVA).balanceOf(msg.sender);
        uint256 maxAmount = ILavaToken(LAVA).maxTransferAmount();
        if (amount > maxAmount) {
            amount = maxAmount;
        }

        IERC20(LAVA).safeTransferFrom(
            address(msg.sender),
            address(this),
            amount
        );

        amount = IERC20(LAVA).balanceOf(address(this));
        require(amount > 0, "amounnt == 0");

        if (strat == 0) {
            //所有兑换成bnb
            _swap(WBNB, amount, _tokenPath(LAVA, WBNB), user1, user2);
        } else if (strat == 1) {
            //所有兑换成busd
            _swap(BUSD, amount, _tokenPath(LAVA, BUSD), user1, user2);
        } else if (strat == 2) {
            //所有兑换成usdt
            _swap(UDST, amount, _tokenPath(LAVA, UDST), user1, user2);
        } else {
            //按照比例兑换
            (,uint256 busd,,uint256 bnbInUsd) = getLavaPairsReserves();
            uint256 totalValue = busd + bnbInUsd;
            require(totalValue > 0, "totalValue == 0");
            uint256 bnbAmt = amount.mul(bnbInUsd).div(totalValue);
            _swap(WBNB, bnbAmt, _tokenPath(LAVA, WBNB), user1, user2);

            uint256 busdAmt = IERC20(LAVA).balanceOf(address(this));
            _swap(BUSD, busdAmt, _tokenPath(LAVA, BUSD), user1, user2);
        }
    }

    function setBNBFeed(address feed) public onlyOwner {
        bnbFeed = feed;
    }

    function priceBNB() public view returns(uint256) {
         (, int price, , ,) = AggregatorV3Interface(bnbFeed).latestRoundData();
        return uint256(price).mul(1e10);
    }

    function getBNBPairReserves() public view returns(uint256 bnb, uint256 lava) {
        (uint256 reserve0, uint256 reserve1, ) = IPancakePair(WBNB_LAVA).getReserves();
        if (IPancakePair(WBNB_LAVA).token0() == LAVA) {
            lava = reserve0;
            bnb = reserve1;
        } else {
            lava = reserve1;
            bnb = reserve0;
        }
    }

    function getBUSDPairReserves() public view returns(uint256 busd, uint lava) {
        (uint256 reserve0, uint256 reserve1, ) = IPancakePair(BUSD_LAVA).getReserves();
        if (IPancakePair(BUSD_LAVA).token0() == LAVA) {
            lava = reserve0;
            busd = reserve1;
        } else {
            lava = reserve1;
            busd = reserve0;
        }
    }

    function getUSDTPairReserves() public view returns(uint256 usdt, uint lava) {
        if (USDT_LAVA == address(0)) {
            return(0,0);
        }

        (uint256 reserve0, uint256 reserve1, ) = IPancakePair(USDT_LAVA).getReserves();
        if (IPancakePair(USDT_LAVA).token0() == LAVA) {
            lava = reserve0;
            usdt = reserve1;
        } else {
            lava = reserve1;
            usdt = reserve0;
        }
    }

    function getLavaPairsReserves() public view returns(uint256 bnb, uint256 busd, uint256 usdt, uint256 bnbInUsd) {
        (bnb,) = getBNBPairReserves();
        (busd,) = getBUSDPairReserves();
        (usdt,) = getUSDTPairReserves();
        bnbInUsd = bnb.mul(priceBNB()).div(1e18);
    }

    function withdrawBEP20(address _tokenAddress, address _to) public payable onlyOwner {
        uint256 tokenBal = IERC20(_tokenAddress).balanceOf(address(this));
        IERC20(_tokenAddress).transfer(_to, tokenBal);
    }

    function _safeApprove(address token, address spender) internal {
        if (token != address(0) && IERC20(token).allowance(address(this), spender) == 0) {
            IERC20(token).safeApprove(spender, uint256(~0));
        }
    }

    function _safeTransfer(address _token, address _to, uint256 _amount) internal {
        if (_amount == 0) return;
        if (_token == WBNB) {
            IWETH(WBNB).withdraw(_amount);
            SafeERC20.safeTransferETH(_to, _amount);
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    function _swap(address token, uint256 amount, address[] memory path, address user1, address user2) internal returns(uint256) {
        if (token == address(0)) {
            return 0;
        }
        if (amount == 0 || path.length == 0) return 0;

        uint256 amt = IERC20(path[0]).balanceOf(address(this));
        if (amount > amt) {
            amount = amt;
        }

        IPancakeRouter02(ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount,
            0,
            path,
            address(this),
            now + 60
        );

        uint256 tokenAmt = IERC20(token).balanceOf(address(this));
        if (tokenAmt > 0) {
            amt = tokenAmt.div(2);
            _safeTransfer(token, user1, amt);
            _safeTransfer(token, user2, amt);
        }
        return tokenAmt;
    } 

    function _tokenPath(address _token0, address _token1) internal pure returns(address[] memory path) {
        require(_token0 != _token1, "_token0 == _token1");
        path = new address[](2);
        path[0] = _token0;
        path[1] = _token1;
    }

    receive() external payable {}
}