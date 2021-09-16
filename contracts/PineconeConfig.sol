// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
import "./helpers/Ownable.sol";
import "./interfaces/IPinecone.sol";
import "./interfaces/IDashboard.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./libraries/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract PineconeConfig is OwnableUpgradeable {
    using SafeMath for uint256;
    
    address public PCT;
    IAlpacaCalculator public alpacaCalculator;
    IPriceCalculator public priceCalculator;
    IWexCalculator public wexCalculator;
    IPineconeFarm public pineconeFarm;
    address public wNativeRelayer;

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    IRabbitCalculator public rabbitCalculator;
    IMdexCalculator public mdexCalculator;

    function initialize() external initializer {
        __Ownable_init();
    }

    function setPCT(address _addr) public onlyOwner {
        PCT = _addr;
    }

    function setAlpacaCalculator(address _addr) public onlyOwner {
        alpacaCalculator = IAlpacaCalculator(_addr);
    }

    function setPriceCalculator(address _addr) public onlyOwner {
        priceCalculator = IPriceCalculator(_addr);
    }

    function setWexCalculator(address _addr) public onlyOwner {
        wexCalculator = IWexCalculator(_addr);
    }

    function setRabbitCalculator(address _addr) public onlyOwner {
        rabbitCalculator = IRabbitCalculator(_addr);
    }

    function setMdexCalculator(address _addr) public onlyOwner {
        mdexCalculator = IMdexCalculator(_addr);
    }

    function setPineconeFarm(address _addr) public onlyOwner {
        pineconeFarm = IPineconeFarm(_addr);
    }

    function setWNativeRelayer(address _addr) public onlyOwner {
        wNativeRelayer = _addr;
    }

    function priceOfToken(address _token) public view returns(uint256) {
        return priceCalculator.priceOfToken(_token);
    }

    function priceOfPct() public view returns(uint256) {
        return priceCalculator.priceOfToken(PCT);
    }

    function tokenAmountPctToMint(address _token, uint256 _profit) public view returns(uint256) {
        if (_token == WBNB) {
            return pineconeFarm.amountPctToMint(_profit);
        } else {
            uint256 bnbAmt = priceCalculator.getAmountsOut(_profit, _tokenPath(_token, WBNB));
            return pineconeFarm.amountPctToMint(bnbAmt);
        }
    }

    function valueInBNB(address _token, uint256 _amount) public view returns(uint256) {
        if (_token == WBNB) {
            return _amount;
        } else {
            (uint256 bnbAmt, ) = priceCalculator.valueOfAsset(_token, _amount);
            return bnbAmt;
        }
    }

    function tokenAmountPctToMint(address _token, uint256 _profit, address _router) public view returns(uint256) {
        if (_token == WBNB) {
            return pineconeFarm.amountPctToMint(_profit);
        } else {
            uint256 bnbAmt = getAmountsOut(_profit, _token, WBNB, _router);
            return pineconeFarm.amountPctToMint(bnbAmt);
        }
    }

    function getAmountsOut(uint256 amountIn, address tokenIn, address tokenOut, address router) public view returns (uint256) {
        if (amountIn == 0) {
            return 0;
        }
        if (tokenIn == tokenOut) {
            return amountIn;
        }

        uint256[] memory amounts = IPancakeRouter02(router).getAmountsOut(amountIn, _tokenPath(tokenIn, tokenOut));
        if (amounts.length == 0) {
            return 0;
        }
        return amounts[amounts.length - 1];
    }

    function getAmountsOut(uint256 amountIn, address tokenIn, address tokenOut) public view returns (uint256) {
        if (amountIn == 0) {
            return 0;
        }

        if (tokenIn == tokenOut) {
            return amountIn;
        }

        uint256 priceOfTokenIn = priceCalculator.priceOfToken(tokenIn);
        uint256 priceOfTokenOut = priceCalculator.priceOfToken(tokenOut);

        return amountIn.mul(priceOfTokenIn).div(priceOfTokenOut);
    }


    function _tokenPath(address _token0, address _token1) private pure returns(address[] memory path) {
        require(_token0 != _token1, "_token0 == _token1");
        if (_token0 == WBNB || _token1 == WBNB) {
            path = new address[](2);
            path[0] = _token0;
            path[1] = _token1;
        } else {
            path = new address[](3);
            path[0] = _token0;
            path[1] = WBNB;
            path[2] = _token1;
        }
    }
}


