// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../interfaces/IERC20.sol";
import "../interfaces/IPancakePair.sol";
import "../interfaces/IPancakeFactory.sol";
import "../interfaces/IPancakeRouter02.sol";
import "../interfaces/AggregatorV3Interface.sol";
import "../interfaces/IDashboard.sol";
import "../libraries/HomoraMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";


contract PriceCalculator is IPriceCalculator, OwnableUpgradeable {
    using SafeMath for uint256;
    using HomoraMath for uint256;

    address public PCT;
    address public PCT_BNB;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant VAI = 0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;

    IPancakeFactory private constant factory = IPancakeFactory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);
    address private constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    /* ========== STATE VARIABLES ========== */

    mapping(address => address) private pairTokens;
    mapping(address => address) private tokenFeeds;

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __Ownable_init();
        setPairToken(VAI, BUSD);
    }

    /* ========== Restricted Operation ========== */

    function setPairToken(address asset, address pairToken) public onlyOwner {
        pairTokens[asset] = pairToken;
    }

    function setTokenFeed(address asset, address feed) public onlyOwner {
        tokenFeeds[asset] = feed;
    }

    function setPCTAddress(address pct, address pct_bnb) public onlyOwner {
        PCT = pct;
        PCT_BNB = pct_bnb;
    }

    /* ========== Value Calculation ========== */
    function getAmountsOut(uint256 amount, address[] memory path) view public override returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        
        uint256[] memory amounts = IPancakeRouter02(ROUTER).getAmountsOut(amount, path);
        if (amounts.length == 0) {
            return 0;
        }
        return amounts[amounts.length.sub(1)];
    }

    function priceOfBNB() view public override returns (uint256) {
        (, int price, , ,) = AggregatorV3Interface(tokenFeeds[WBNB]).latestRoundData();
        return uint256(price).mul(1e10);
    }

    function priceOfCake() view public override returns (uint256) {
        (, int price, , ,) = AggregatorV3Interface(tokenFeeds[CAKE]).latestRoundData();
        return uint256(price).mul(1e10);
    }

    function priceOfPct() view public override returns (uint256) {
        (, uint256 pctPriceInUSD) = valueOfAsset(PCT, 1e18);
        return pctPriceInUSD;
    }

    function pricesInUSD(address[] memory assets) public view override returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            (, uint256 valueInUSD) = valueOfAsset(assets[i], 1e18);
            prices[i] = valueInUSD;
        }
        return prices;
    }

    function priceOfToken(address token) public view override returns(uint256) {
        (, uint256 pctPriceInUSD) = valueOfAsset(token, 1e18);
        return pctPriceInUSD;
    }

    function valueOfAsset(address asset, uint256 amount) public view override returns (uint256 valueInBNB, uint256 valueInUSD) {
        if (asset == address(0) || asset == WBNB) {
            return _oracleValueOf(WBNB, amount);
        } else if (asset == PCT || asset == PCT_BNB) {
            return _unsafeValueOfAsset(asset, amount);
        } else if (keccak256(abi.encodePacked(IPancakePair(asset).symbol())) == keccak256("Cake-LP")) {
            return _getPairPrice(asset, amount);
        } else {
            return _oracleValueOf(asset, amount);
        }
    }

    function _oracleValueOf(address asset, uint256 amount) private view returns (uint256 valueInBNB, uint256 valueInUSD) {
        if (tokenFeeds[asset] != address(0)) {
            (, int price, , ,) = AggregatorV3Interface(tokenFeeds[asset]).latestRoundData();
            valueInUSD = uint256(price).mul(1e10).mul(amount).div(1e18);
            valueInBNB = valueInUSD.mul(1e18).div(priceOfBNB());
        } else {
            return _unsafeValueOfAsset(asset, amount);
        }
    }

    function _getPairPrice(address pair, uint256 amount) private view returns (uint256 valueInBNB, uint256 valueInUSD) {
        address token0 = IPancakePair(pair).token0();
        address token1 = IPancakePair(pair).token1();
        uint256 totalSupply = IPancakePair(pair).totalSupply();
        (uint256 r0, uint256 r1, ) = IPancakePair(pair).getReserves();

        uint256 sqrtK = HomoraMath.sqrt(r0.mul(r1)).fdiv(totalSupply);
        (uint256 px0,) = _oracleValueOf(token0, 1e18);
        (uint256 px1,) = _oracleValueOf(token1, 1e18);
        uint256 fairPriceInBNB = sqrtK.mul(2).mul(HomoraMath.sqrt(px0)).div(2**56).mul(HomoraMath.sqrt(px1)).div(2**56);

        valueInBNB = fairPriceInBNB.mul(amount).div(1e18);
        valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
    }

    function _unsafeValueOfAsset(address asset, uint256 amount) private view returns (uint256 valueInBNB, uint256 valueInUSD) {
        if (asset == address(0) || asset == WBNB) {
            valueInBNB = amount;
            valueInUSD = amount.mul(priceOfBNB()).div(1e18);
        }
        else if (keccak256(abi.encodePacked(IPancakePair(asset).symbol())) == keccak256("Cake-LP")) {
            if (IPancakePair(asset).totalSupply() == 0) return (0, 0);

            (uint256 reserve0, uint256 reserve1, ) = IPancakePair(asset).getReserves();
            if (IPancakePair(asset).token0() == WBNB) {
                valueInBNB = amount.mul(reserve0).mul(2).div(IPancakePair(asset).totalSupply());
                valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
            } else if (IPancakePair(asset).token1() == WBNB) {
                valueInBNB = amount.mul(reserve1).mul(2).div(IPancakePair(asset).totalSupply());
                valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
            } else {
                (uint256 token0PriceInBNB,) = valueOfAsset(IPancakePair(asset).token0(), 1e18);
                valueInBNB = amount.mul(reserve0).mul(2).mul(token0PriceInBNB).div(1e18).div(IPancakePair(asset).totalSupply());
                valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
            }
        }
        else {
            address pairToken = pairTokens[asset] == address(0) ? WBNB : pairTokens[asset];
            address pair = factory.getPair(asset, pairToken);
            if (IERC20(asset).balanceOf(pair) == 0) return (0, 0);

            (uint256 reserve0, uint256 reserve1, ) = IPancakePair(pair).getReserves();
            if (IPancakePair(pair).token0() == pairToken) {
                valueInBNB = reserve0.mul(amount).div(reserve1);
            } else if (IPancakePair(pair).token1() == pairToken) {
                valueInBNB = reserve1.mul(amount).div(reserve0);
            } else {
                return (0, 0);
            }

            if (pairToken != WBNB) {
                (uint256 pairValueInBNB,) = valueOfAsset(pairToken, 1e18);
                valueInBNB = valueInBNB.mul(pairValueInBNB).div(1e18);
            }
            valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
        }
    }
}