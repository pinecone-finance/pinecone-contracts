
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
import "../interfaces/IPineconeToken.sol";
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
    IBSWCalculator public bswCalculator;

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

    function setBSWCalculator(address addr) external onlyOwner {
        bswCalculator = IBSWCalculator(addr);
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
        vaultApy = compundApy(vaultApr/365);
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
        vaultApy = compundApy(vaultApr/365);
        totalApy = vaultApy.add(rabbitCompoundingApy);
    }

    function vaultCakeApyOfMdex(uint256 cakePid) public view returns(uint256) {
        uint256 base_daily_apr = cakePoolDailyApr(cakePid);
        uint256 mdx_daily_apr = mdexCalculator.mdexPoolDailyApr();
        uint256 mdx_apy = compundApy(mdx_daily_apr);
        mdx_apy = base_daily_apr.mul(mdx_apy).div(mdx_daily_apr);
        return mdx_apy;
    }

    function vaultCakeApyOfBSW(uint256 cakePid) public view returns(uint256) {
        uint256 base_daily_apr = cakePoolDailyApr(cakePid);
        uint256 bsw_daily_apr = bswCalculator.bswPoolDailyApr();
        uint256 bsw_apy = compundApy(bsw_daily_apr);
        base_daily_apr = base_daily_apr.mul(UNIT + bsw_daily_apr).div(UNIT);
        bsw_apy = base_daily_apr.mul(bsw_apy).div(bsw_daily_apr);
        return bsw_apy;
    }

    function vaultRabbitApyOfCake(address token, uint256 pid) public view returns(uint256 totalApy, uint256 vaultApy, uint256 rabbitCompoundingApy) {
        (uint256 vaultApr, uint256 rabbitApr) = rabbitCalculator.vaultApr(token, pid);
        uint256 base_daily_apr = rabbitApr/ 365;
        uint256 cake_daily_apr = cakePoolDailyApr(0);
        uint256 cake_apy = compundApy(cake_daily_apr);
        base_daily_apr = base_daily_apr.mul(UNIT + cake_daily_apr).div(UNIT);
        rabbitCompoundingApy = base_daily_apr.mul(cake_apy).div(cake_daily_apr);
        vaultApy = compundApy(vaultApr/365);
        totalApy = vaultApy.add(rabbitCompoundingApy);
    }

    function vaultAlpacaApyOfBSW(address vault, uint256 pid) public view returns(uint256 totalApy, uint256 vaultApy, uint256 alpacaCompoundingApy) {
        (uint256 vaultApr, uint256 alpacaApr) = alpacaCalculator.vaultApr(vault, pid);
        uint256 base_daily_apr = alpacaApr/ 365;
        uint256 bsw_daily_apr = bswCalculator.bswPoolDailyApr();
        uint256 bsw_apy = compundApy(bsw_daily_apr);
        base_daily_apr = base_daily_apr.mul(UNIT + bsw_daily_apr).div(UNIT);
        alpacaCompoundingApy = base_daily_apr.mul(bsw_apy).div(bsw_daily_apr);
        vaultApy = compundApy(vaultApr/365);
        totalApy = vaultApy.add(alpacaCompoundingApy);
    }

    function vaultCakeApy(uint256 cakePid) public view returns(uint256) {
        uint256 dapr = cakePoolDailyApr(cakePid);
        uint256 apy = compundApy(dapr);
        return apy;
    } 

    function vaultBSWApy() public view returns(uint256) {
        uint256 dapr = bswCalculator.bswPoolDailyApr();
        uint256 apy = compundApy(dapr);
        return apy;
    } 

    function vaultRabbitDAprOfCake(address token, uint256 pid) public view 
        returns(
            uint256 stakingTokenDApr, 
            uint256 rewardTokenDApr, 
            uint256 highYeildDApr
        ) 
    {
        (uint256 vaultApr, uint256 rabbitApr) = rabbitCalculator.vaultApr(token, pid);
        stakingTokenDApr = vaultApr / 365;
        rewardTokenDApr = rabbitApr/ 365;
        highYeildDApr = cakePoolDailyApr(0);
    }

    function vaultCakeDAprOfBSW(uint256 cakePid) public view 
        returns(
           uint256 cakeDapr, 
           uint256 bswDapr
        ) 
    {
        cakeDapr = cakePoolDailyApr(cakePid);
        bswDapr = bswCalculator.bswPoolDailyApr();
    }

    function vaultAlpacaDAprOfBSW(address vault, uint256 pid) public view 
        returns(
            uint256 stakingTokenDApr, 
            uint256 rewardTokenDApr, 
            uint256 highYeildDApr
        ) 
    {
        (uint256 vaultApr, uint256 alpacaApr) = alpacaCalculator.vaultApr(vault, pid);
        stakingTokenDApr = vaultApr / 365;
        rewardTokenDApr = alpacaApr/ 365;
        highYeildDApr = bswCalculator.bswPoolDailyApr();
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
        if (_type == StakeType.Rabbit_Mdex) {
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
            earned0Apy = earnedPctApy;
            earned1Apy = 0;
        } else if (_type == StakeType.Rabbit_Cake) {
            address token  = IPineconeStrategy(strat).stakingToken();
            uint256 farmPid = IPineconeStrategy(strat).farmPid();
            (uint256 _apy,,) = vaultRabbitApyOfCake(token, farmPid);
            uint256 rabbit_apy = _apy.mul(UNIT - fee).div(UNIT);
            uint256 toPctAmount = pctToTokenAmount(want);
            uint256 pct_apy =  _apy.mul(fee).div(UNIT);
            pct_apy = pct_apy.mul(toPctAmount).div(UNIT);
            earned0Apy = rabbit_apy;
            earned1Apy = pct_apy.add(earnedPctApy);
        } else if (_type == StakeType.Cake_BSW) {
            uint256 _apy = vaultCakeApyOfBSW(cakePid);
            uint256 cake_apy = _apy.mul(UNIT - fee).div(UNIT);
            uint256 toPctAmount = pctToTokenAmount(address(CAKE));
            uint256 pct_apy =  _apy.mul(fee).div(UNIT);
            pct_apy = pct_apy.mul(toPctAmount).div(UNIT);
            earned0Apy = cake_apy;
            earned1Apy = pct_apy.add(earnedPctApy);
        } else if (_type == StakeType.Alpaca_BSW) {
            address vault  = IPineconeStrategy(strat).stratAddress();
            uint256 farmPid = IPineconeStrategy(strat).farmPid();
            (uint256 _apy,,) = vaultAlpacaApyOfBSW(vault, farmPid);
            uint256 alpaca_apy = _apy.mul(UNIT - fee).div(UNIT);
            uint256 toPctAmount = pctToTokenAmount(address(CAKE));
            uint256 pct_apy =  _apy.mul(fee).div(UNIT);
            pct_apy = pct_apy.mul(toPctAmount).div(UNIT);
            earned0Apy = alpaca_apy;
            earned1Apy = pct_apy.add(earnedPctApy);
        } else if (_type == StakeType.PCT) {
            earned0Apy = 0;
            uint256 pool_tvl = tvlOfPool(pid);
            if (pool_tvl > 0) {
                uint256 cakeAmt = IVaultPCT(strat).cakeDailyReward() / 2;
                cakeAmt = cakeAmt.mul(365);
                uint256 earnedCakeValue = cakeAmt.mul(priceCalculator.priceOfCake()).div(UNIT);
                earned0Apy = earnedCakeValue.mul(UNIT).div(pool_tvl);
            }
            earned1Apy = earnedPctApy;
        } else if (_type == StakeType.HotToken) {
            if (want == address(CAKE)) {
                uint256 _apy = vaultCakeApy(cakePid);
                uint256 cake_apy = _apy.mul(UNIT - fee).div(UNIT);
                uint256 toPctAmount = pctToTokenAmount(address(CAKE));
                uint256 pct_apy =  _apy.mul(fee).div(UNIT);
                pct_apy = pct_apy.mul(toPctAmount).div(UNIT);
                earned0Apy = cake_apy;
                earned1Apy = pct_apy.add(earnedPctApy);
            } else if (want == 0x965F527D9159dCe6288a2219DB51fc6Eef120dD1) {
                uint256 _apy = vaultBSWApy();
                uint256 bsw_apy = _apy.mul(UNIT - fee).div(UNIT);
                uint256 toPctAmount = pctToTokenAmount(0x965F527D9159dCe6288a2219DB51fc6Eef120dD1);
                uint256 pct_apy =  _apy.mul(fee).div(UNIT);
                pct_apy = pct_apy.mul(toPctAmount).div(UNIT);
                earned0Apy = bsw_apy;
                earned1Apy = pct_apy.add(earnedPctApy);
            }
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

    function tvlOfPool2(uint256 pid) public view returns(address want, address strat, uint256 priceInUsd, uint256 amount) {
        (want, strat) = pineconeFarm.poolInfoOf(pid);
        if (strat == address(0)) {
            return (want,strat,0,0);
        }

        priceInUsd = IPineconeStrategy(strat).tvl();
        amount = priceInUsd.mul(UNIT).div(priceCalculator.priceOfToken(want));
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

    function pctFeeOfUser(address user) public view returns(
        uint256 buyFee,
        uint256 sellFee,
        uint256 txFee
    ) {
        address pct = priceCalculator.pctToken();
        bool ret = IPineconeToken(pct).isExcludedFromFee(user);
        if (ret == true) {
            return (0,0,0);
        }

        ret = IPineconeToken(pct).isPresaleUser(user);
        if (ret == true) {
            return (0,5,0);
        }

        return (5,10,10);
    }

    function pendingRewardsValue(uint256 pid) public view returns(uint256) {
        (, address strat) = pineconeFarm.poolInfoOf(pid);
        if (strat == address(0)) {
            return (0);
        }

        return IPineconeStrategy(strat).pendingRewardsValue();
    }

    function aprOfPool(uint256 pid) public view 
        returns(
            uint256 stakingTokenDApr, 
            uint256 rewardTokenDApr, 
            uint256 highYeildDApr, 
            uint256 pctDApr,
            uint256 pctPremium,
            uint256 pctFee
        ) 
    {
        (address want, address strat) = pineconeFarm.poolInfoOf(pid);
        if (strat == address(0)) {
            return (0,0,0,0,0,0);
        }

        stakingTokenDApr = 0;
        rewardTokenDApr = 0;
        highYeildDApr = 0;
        pctPremium = 0;
        pctDApr = earnedApy(pid)/365;
        pctFee = IPineconeStrategy(strat).performanceFee(UNIT);
        StakeType _type = IPineconeStrategy(strat).stakeType();
        if (_type == StakeType.Rabbit_Cake) {
            address token  = IPineconeStrategy(strat).stakingToken();
            uint256 farmPid = IPineconeStrategy(strat).farmPid();
            (stakingTokenDApr, rewardTokenDApr, highYeildDApr) = vaultRabbitDAprOfCake(token, farmPid);
            pctPremium = pctToTokenAmount(want);
        } else if (_type == StakeType.Cake_BSW) {
            (stakingTokenDApr, highYeildDApr) = vaultCakeDAprOfBSW(0);
            rewardTokenDApr = stakingTokenDApr;
            pctPremium = pctToTokenAmount(address(CAKE));
        } else if (_type == StakeType.Alpaca_BSW) {
            address vault  = IPineconeStrategy(strat).stratAddress();
            uint256 farmPid = IPineconeStrategy(strat).farmPid();
            (stakingTokenDApr, rewardTokenDApr, highYeildDApr) = vaultAlpacaDAprOfBSW(vault, farmPid);
            pctPremium = pctToTokenAmount(want);
        }
    }
}