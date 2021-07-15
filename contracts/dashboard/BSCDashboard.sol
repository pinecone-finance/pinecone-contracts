
// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/SafeMath.sol";
import "../libraries/SafeDecimal.sol";
import "../interfaces/IMasterChef.sol";
import "../interfaces/IPancakePair.sol";
import "../interfaces/IDashboard.sol";
import "../interfaces/IPinecone.sol";
import "../helpers/ERC20.sol";
import "../interfaces/IPancakeFactory.sol";
import "../interfaces/IAlpaca.sol";
import "../interfaces/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract BSCDashboard is OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeDecimal for uint256;

    IPriceCalculator public priceCalculator;
    IAlpacaCalculator public alpacaCalculator;
    IWexCalculator public wexCalculator;
    IPineconeFarm public pineconeFarm;

    IMasterChef private constant cakeMaster = IMasterChef(0x73feaa1eE314F8c655E354234017bE2193C9E24E);
    IPancakeFactory private constant factory = IPancakeFactory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);

    uint256 private constant BLOCK_PER_DAY = 28800;
    uint256 private constant BLOCK_PER_YEAR = 10512000;
    uint256 private constant UNIT = 1e18;

    address private constant CAKE_BNB = 0x0eD7e52944161450477ee417DE9Cd3a859b14fD0;
    address private constant BUSD_BNB = 0x58F876857a02D6762E0101bb5C46A8c1ED44Dc16;
    IERC20 private constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 private constant CAKE = IERC20(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);
    IERC20 private constant BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

    IMdexCalculator public mdexCalculator;
    IRabbitCalculator public rabbitCalculator;

    function initialize() external initializer {
        __Ownable_init();
    }

    function setPineconeFarm(address addr) external onlyOwner {
        pineconeFarm = IPineconeFarm(addr);
    }

    function setPriceCalculator(address addr) external onlyOwner {
        priceCalculator = IPriceCalculator(addr);
    }

    function setAlpacaCalculator(address addr) external onlyOwner {
        alpacaCalculator = IAlpacaCalculator(addr);
    }

    function setWexCalculator(address addr) external onlyOwner {
        wexCalculator = IWexCalculator(addr);
    }

    function setMdexCalculator(address addr) external onlyOwner {
        mdexCalculator = IMdexCalculator(addr);
    }

    function setRabbitCalculator(address addr) external onlyOwner {
        rabbitCalculator = IRabbitCalculator(addr);
    }

    function cakePerYearOfPool(uint256 pid) public view returns(uint256) {
        (, uint256 allocPoint,,) = cakeMaster.poolInfo(pid);
        return cakeMaster.cakePerBlock().mul(BLOCK_PER_YEAR).mul(allocPoint).div(cakeMaster.totalAllocPoint());
    }

    function cakePerDayOfPool(uint256 pid) public view returns(uint256) {
        (, uint256 allocPoint,,) = cakeMaster.poolInfo(pid);
        return cakeMaster.cakePerBlock().mul(BLOCK_PER_DAY).mul(allocPoint).div(cakeMaster.totalAllocPoint());
    }

    function tokenPriceInBNB(address token)  public view returns(uint256) {
        address pair = factory.getPair(token, address(WBNB));
        uint256 decimal = uint256(ERC20(token).decimals());

        return WBNB.balanceOf(pair).mul(10**decimal).div(IERC20(token).balanceOf(pair));
    }

    function cakePriceInBNB() public view returns(uint256) {
        return WBNB.balanceOf(CAKE_BNB).mul(UNIT).div(CAKE.balanceOf(CAKE_BNB));
    }

    function bnbPriceInUSD() public view returns(uint256) {
        return BUSD.balanceOf(BUSD_BNB).mul(UNIT).div(WBNB.balanceOf(BUSD_BNB));
    }

    function tvl(address flip, uint256 amount) public view returns (uint256) {
        if (flip == address(CAKE)) {
            return cakePriceInBNB().mul(bnbPriceInUSD()).mul(amount).div(1e36);
        }
        address _token0 = IPancakePair(flip).token0();
        address _token1 = IPancakePair(flip).token1();
        if (_token0 == address(WBNB) || _token1 == address(WBNB)) {
            uint256 bnb = WBNB.balanceOf(address(flip)).mul(amount).div(IERC20(flip).totalSupply());
            uint256 price = bnbPriceInUSD();
            return bnb.mul(price).div(UNIT).mul(2);
        }
        uint256 balanceToken0 = IERC20(_token0).balanceOf(flip);
        uint256 price = tokenPriceInBNB(_token0);
        return balanceToken0.mul(price).div(UNIT).mul(bnbPriceInUSD()).div(UNIT).mul(2);
    }

    function cakePoolDailyApr(uint256 pid) public view returns(uint256) {
        (address token,,,) = cakeMaster.poolInfo(pid);
        uint256 poolSize = tvl(token, IERC20(token).balanceOf(address(cakeMaster))).mul(UNIT).div(bnbPriceInUSD());
        return cakePriceInBNB().mul(cakePerDayOfPool(pid)).div(poolSize);
    }

    function compoundAPYOfCakePool(uint256 pid) public view returns(uint256) {
        uint256 __apr = cakePoolDailyApr(pid);
        return compundApy(__apr);
    }

    function compundApy(uint256 dApr) public pure returns(uint256) {
        uint256 compoundTimes = 365;
        uint256 unitAPY = UNIT + dApr;
        uint256 result = UNIT;
        for(uint256 i=0; i<compoundTimes; i++) {
            result = (result * unitAPY) / UNIT;
        }
        return result - UNIT;
    }

    function vaultAlpacaApyOfWex(address vault, uint256 pid) public view returns(uint256 totalApy, uint256 vaultApy, uint256 alpacaCompoundingApy) {
        (uint256 vaultApr, uint256 alpacaApr) = alpacaCalculator.vaultApr(vault, pid);
        uint256 base_daily_apr = alpacaApr/ 365;
        uint256 wex_daily_apr = wexCalculator.wexPoolDailyApr();
        uint256 wex_apy = compundApy(wex_daily_apr);
        alpacaCompoundingApy = base_daily_apr.mul(wex_apy).div(wex_daily_apr);
        vaultApy = vaultApr;
        totalApy = vaultApy.add(alpacaCompoundingApy);
    }

    function vaultCakeApyOfWex(uint256 cakePid) public view returns(uint256) {
        uint256 base_daily_apr = cakePoolDailyApr(cakePid);
        uint256 wex_daily_apr = wexCalculator.wexPoolDailyApr();
        uint256 wex_apy = compundApy(wex_daily_apr);
        wex_apy = base_daily_apr.mul(wex_apy).div(wex_daily_apr);
        return wex_apy;
    }

    function vaultRabbitApyOfMdex(address token, uint256 pid) public view returns(uint256 totalApy, uint256 vaultApy, uint256 rabbitCompoundingApy) {
        (uint256 vaultApr, uint256 rabbitApr) = rabbitCalculator.vaultApr(token, pid);
        uint256 base_daily_apr = rabbitApr/ 365;
        uint256 mdex_daily_apr = mdexCalculator.mdexPoolDailyApr();
        uint256 mdex_apy = compundApy(mdex_daily_apr);
        rabbitCompoundingApy = base_daily_apr.mul(mdex_apy).div(mdex_daily_apr);
        vaultApy = vaultApr;
        totalApy = vaultApy.add(rabbitCompoundingApy);
    }

    function vaultCakeApyOfMdex(uint256 cakePid) public view returns(uint256) {
        uint256 base_daily_apr = cakePoolDailyApr(cakePid);
        uint256 mdx_daily_apr = mdexCalculator.mdexPoolDailyApr();
        uint256 mdx_apy = compundApy(mdx_daily_apr);
        mdx_apy = base_daily_apr.mul(mdx_apy).div(mdx_daily_apr);
        return mdx_apy;
    }

    function apyOfPool(
        uint256 pid,
        uint256 cakePid
    ) 
        public view 
        returns(
            uint256 earned0Apy, 
            uint256 earned1Apy
        ) 
    {
        (address want, address strat) = pineconeFarm.poolInfoOf(pid);
        if (strat == address(0)) {
            return (0,0);
        }
        earned0Apy = 0;
        earned1Apy = 0;
        StakeType _type = IPineconeStrategy(strat).stakeType();
        uint256 earnedPctApy = earnedApy(pid);
        uint256 fee = IPineconeStrategy(strat).performanceFee(UNIT);
        if(_type == StakeType.Alpaca_Wex) {
            address farmAddress = IPineconeStrategy(strat).stratAddress();
            uint256 farmPid = IPineconeStrategy(strat).farmPid();
            (uint256 _apy,,) = vaultAlpacaApyOfWex(farmAddress, farmPid);
            uint256 alpaca_apy = _apy.mul(UNIT - fee).div(UNIT);
            uint256 toPctAmount = pctToTokenAmount(want);
            uint256 pct_apy =  _apy.mul(fee).div(UNIT);
            pct_apy = pct_apy.mul(toPctAmount).div(UNIT);
            earned0Apy = alpaca_apy;
            earned1Apy = pct_apy.add(earnedPctApy);
        }
        else if (_type == StakeType.Cake_Wex) {
            uint256 _apy = vaultCakeApyOfWex(cakePid);
            uint256 cake_apy = _apy.mul(UNIT - fee).div(UNIT);
            uint256 toPctAmount = pctToTokenAmount(address(CAKE));
            uint256 pct_apy =  _apy.mul(fee).div(UNIT);
            pct_apy = pct_apy.mul(toPctAmount).div(UNIT);
            earned0Apy = cake_apy;
            earned1Apy = pct_apy.add(earnedPctApy);
        } else if (_type == StakeType.Rabbit_Mdex) {
            address token  = IPineconeStrategy(strat).stakingToken();
            uint256 farmPid = IPineconeStrategy(strat).farmPid();
            (uint256 _apy,,) = vaultRabbitApyOfMdex(token, farmPid);
            uint256 rabbit_apy = _apy.mul(UNIT - fee).div(UNIT);
            uint256 toPctAmount = pctToTokenAmount(want);
            uint256 pct_apy =  _apy.mul(fee).div(UNIT);
            pct_apy = pct_apy.mul(toPctAmount).div(UNIT);
            earned0Apy = rabbit_apy;
            earned1Apy = pct_apy.add(earnedPctApy);
        } else if (_type == StakeType.Cake_Mdex) {
            uint256 _apy = vaultCakeApyOfMdex(cakePid);
            uint256 cake_apy = _apy.mul(UNIT - fee).div(UNIT);
            uint256 toPctAmount = pctToTokenAmount(address(CAKE));
            uint256 pct_apy =  _apy.mul(fee).div(UNIT);
            pct_apy = pct_apy.mul(toPctAmount).div(UNIT);
            earned0Apy = cake_apy;
            earned1Apy = pct_apy.add(earnedPctApy);
        } else if (_type == StakeType.PCTPair) {
            earned0Apy = 0;
            earned1Apy = earnedPctApy;
        }
    }

    function earnedApy(uint256 pid) public view returns(uint256) {
        uint256 pctAmt = pineconeFarm.dailyEarnedAmount(pid);
        pctAmt = pctAmt.mul(365);
        uint256 pool_tvl = tvlOfPool(pid);
        uint256 earnedPctValue = pctAmt.mul(priceCalculator.priceOfPct()).div(UNIT);
        uint256 earnedPctApy = 0;
        if (pool_tvl > 0) {
            earnedPctApy = earnedPctValue.mul(UNIT).div(pool_tvl);
        }

        return earnedPctApy;
    }

    function tvlOfPool(uint256 pid) public view returns(uint256 priceInUsd) {
        (, address strat) = pineconeFarm.poolInfoOf(pid);
        if (strat == address(0)) {
            return 0;
        }
        return IPineconeStrategy(strat).tvl();
    }

    function pctToTokenAmount(address token) public view returns(uint256) {
        uint256 bnbAmount = UNIT;
        uint256 tokenPrice = priceCalculator.priceOfToken(token);
        if (token != address(WBNB)) {
            uint256 bnbPrice = priceCalculator.priceOfBNB();
            bnbAmount = tokenPrice.mul(UNIT).div(bnbPrice);
        }

        uint256 pctAmount = pineconeFarm.amountPctToMint(bnbAmount);
        uint256 pctPrice = priceCalculator.priceOfPct();
        uint256 toAmount = pctAmount.mul(pctPrice).div(tokenPrice);
        return toAmount;
    }

    function userInfoOfPool(
        uint256 pid, 
        address user) 
        public view 
        returns(
            uint256 depositAmt, 
            uint256 depositedAt, 
            uint256 balance,
            uint256 earned0Amt,
            uint256 earned1Amt,
            uint256 withdrawableAmt
        )
    {
        (depositedAt, depositAmt, balance, earned0Amt, earned1Amt, withdrawableAmt) = pineconeFarm.userInfoOfPool(pid, user);
    }
}