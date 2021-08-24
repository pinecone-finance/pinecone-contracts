// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./VaultBase.sol";
import "./interfaces/IMasterChef.sol";
import "./interfaces/ISmartRouter.sol";
import "./interfaces/IPancakeRouter02.sol";

//Investment strategy
contract VaultHot is VaultBase {
    
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct UserAssetInfo
    {
        uint256 depositAmt;
        uint256 depositedAt;
        uint256 shares;
    }

    uint256 public sharesTotal;
    mapping (address=>UserAssetInfo) users;

    address public constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant BSW = 0x965F527D9159dCe6288a2219DB51fc6Eef120dD1;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant CAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    uint256 internal constant dust = 1000;
    uint256 internal constant UNIT = 1e18;

    address public stakingToken;
    uint256 public pid;
    address public swapRouter;
    address public smartRouter;

    function initialize (
        address _stakingToken,
        address _stratAddress,
        uint256 _pid,
        address _smartRouter,
        address _swapRouter,
        address _config
    ) external initializer {
        _VaultBase_init(_config, _stratAddress);

        stakingToken = _stakingToken;
        pid = _pid;
        smartRouter = _smartRouter;
        swapRouter = _swapRouter;
        sharesTotal = 0;

        _safeApprove(_stakingToken, _stratAddress);

        _safeApprove(_stakingToken, _swapRouter);
        _safeApprove(WBNB, _swapRouter);

        _safeApprove(CAKE, CAKE_ROUTER);
        _safeApprove(WBNB, CAKE_ROUTER);

        IPineconeFarm pineconeFarm = config.pineconeFarm();
        _safeApprove(CAKE, address(pineconeFarm));
    }

    /* ========== public view ========== */
    function sharesOf(address _user) public view returns(uint256) {
        return users[_user].shares;
    }

    function withdrawableBalanceOf(address _user) public virtual view returns(uint256) {
        return users[_user].depositAmt;
    }

    function userOf(address _user) public view returns(
        uint256 _depositAmt, 
        uint256 _depositedAt, 
        uint256 _shares
    ) {
        UserAssetInfo storage user = users[_user];
        _depositAmt = user.depositAmt;
        _depositedAt = user.depositedAt;
        _shares = user.shares;
    }

    function farmPid() public view returns(uint256) {
        return pid;
    }

    function stakeType() public pure returns(StakeType) {
        return StakeType.HotToken;
    }

    function earned0Address() public view returns(address) {
        return stakingToken;
    }

    function earned1Address() public view returns(address) {
        return config.PCT();
    }

    function userInfoOf(address _user, uint256 _addPct) public view 
        returns(
            uint256 depositedAt, 
            uint256 depositAmt,
            uint256 balanceValue,
            uint256 earned0Amt,
            uint256 earned1Amt,
            uint256 withdrawbaleAmt
        ) 
    {
        UserAssetInfo storage user = users[_user];
        depositedAt = user.depositedAt;
        depositAmt = user.depositAmt;
        (earned0Amt, earned1Amt) = pendingRewards(_user);
        earned1Amt = earned1Amt.add(_addPct);
        withdrawbaleAmt = withdrawableBalanceOf(_user);
        uint256 wantAmt = depositAmt.add(earned0Amt);

        IPineconeConfig _config = config;
        uint256 wantValue = wantAmt.mul(_config.priceOfToken(stakingToken)).div(UNIT);
        uint256 earned1Value = earned1Amt.mul(_config.priceOfPct()).div(UNIT);
        balanceValue = wantValue.add(earned1Value);
    }

    function tvl() public view returns(uint256 priceInUsd) {
        (uint256 wantAmt, uint256 pendingAmt) = balance();
        wantAmt = wantAmt.add(pendingAmt);
        IPineconeConfig _config = config;
        uint256 wantTvl = wantAmt.mul(_config.priceOfToken(stakingToken)).div(UNIT);
        return wantTvl;
    }

    function balance() public view returns(uint256 wantAmt, uint256 pendingAmt) {
        wantAmt = stakingAmount();
        pendingAmt = pendingAmount();
    }

    function balanceOf(address _user) public view returns(uint256 wantAmt, uint256 pendingAmt) {
        if (sharesTotal == 0) {
            return (0,0);
        }

        uint256 shares = sharesOf(_user);
        (wantAmt, pendingAmt) = balance();
        wantAmt = wantAmt.mul(shares).div(sharesTotal);
        pendingAmt = pendingAmt.mul(shares).div(sharesTotal);
    }

    function earnedOf(address _user) public view returns(uint256) {
        UserAssetInfo storage user = users[_user];
        (uint256 wantAmt, uint256 pendingAmt) = balanceOf(_user);
        if (wantAmt > user.depositAmt) {
            wantAmt = wantAmt.sub(user.depositAmt);
        } else {
            wantAmt = 0;
        }
        wantAmt = wantAmt.add(pendingAmt);
    }

    function pendingRewardsValue() public view returns(uint256 priceInUsd) {
        uint256 pendingAmt = pendingAmount();
        return pendingAmt.mul(config.priceOfToken(stakingToken)).div(UNIT);
    }

    function pendingRewards(address _user) public view returns(uint256 wantAmt, uint256 pctAmt)
    {
        if (sharesTotal == 0) {
            return (0, 0);
        }

        wantAmt = earnedOf(_user);
        uint256 fee = performanceFee(wantAmt);
        pctAmt = config.tokenAmountPctToMint(stakingToken, fee, swapRouter);
        wantAmt = wantAmt.sub(fee);
    }

    function stakingAmount() public view returns(uint256) {
        (uint amount,) = IMasterChef(stratAddress).userInfo(pid, address(this));
        return amount;
    }

    function pendingAmount() public view returns(uint256) {
        if (stakingToken == BSW) {
            return IBSWMasterChef(stratAddress).pendingBSW(pid, address(this));
        } else {
            return IMasterChef(stratAddress).pendingCake(pid, address(this));
        }
    }

    /* ========== public write ========== */
    function setSmartRouter(address _router) external onlyDev {
        smartRouter = _router;
    }

    function deposit(uint256 _wantAmt, address _user)
        public
        onlyOwner
        whenNotPaused
        returns(uint256)
    {
        IERC20(stakingToken).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );

        UserAssetInfo storage user = users[_user];
        user.depositedAt = block.timestamp;
        user.depositAmt = user.depositAmt.add(_wantAmt);
        uint256 sharesAdded = _wantAmt;
        (uint256 wantTotal,) = balance();
        if (wantTotal > 0 && sharesTotal > 0) {
            sharesAdded = sharesAdded
                .mul(sharesTotal)
                .div(wantTotal);
        }
        
        sharesTotal = sharesTotal.add(sharesAdded);
        user.shares = user.shares.add(sharesAdded);

        _earn();
        return sharesAdded;
    }

    function farm() public nonReentrant 
    {
        _farmStakingToken();
    }

    function earn() public whenNotPaused onlyGov
    {
        _earn();
    }

    function withdrawAll(address _user)
        public 
        onlyOwner
        nonReentrant
        returns (uint256, uint256, uint256)
    {
        require(sharesTotal > 0, "sharesTotal is 0");

        UserAssetInfo storage user = users[_user];
        require(user.depositAmt > 0 || user.shares > 0, "depositAmt <= 0 && shares <= 0");

        uint256 wantAmt = user.depositAmt;
        uint256 earnedWantAmt = earnedOf(_user);

        _withdrawStakingToken(wantAmt.add(earnedWantAmt));

        //withdraw fee 
        uint256 withdrawFeeAmt = 0;
        bool hasFee = (user.depositedAt.add(minDepositTimeWithNoFee) > block.timestamp) ? true : false;
        if (hasFee) {
            withdrawFeeAmt = wantAmt.mul(withdrawFeeFactor).div(feeMax);
            _safeTransfer(stakingToken, devAddress, withdrawFeeAmt);
            wantAmt = wantAmt.sub(withdrawFeeAmt);
        }

        //performace fee
        (uint256 fee, uint256 pctAmt) = _distributePerformanceFees(earnedWantAmt, _user);
        earnedWantAmt = earnedWantAmt.sub(fee);
        wantAmt = wantAmt.add(earnedWantAmt);

        earnedWantAmt = IERC20(stakingToken).balanceOf(address(this));
        if (wantAmt > earnedWantAmt) {
            wantAmt = earnedWantAmt;
        }

        _safeTransfer(stakingToken, _user, wantAmt);

        if (user.shares > sharesTotal) {
            sharesTotal = 0;
        } else {
            sharesTotal = sharesTotal.sub(user.shares);
        }
        user.shares = 0;
        user.depositAmt = 0;
        user.depositedAt = 0;

        _earn();
        return (wantAmt, earnedWantAmt, pctAmt);
    }

    function withdraw(uint256 _wantAmt, address _user)
        public 
        onlyOwner
        nonReentrant
        returns (uint256, uint256)
    {
        require(_wantAmt > 0, "_wantAmt <= 0");
        require(sharesTotal > 0, "sharesTotal is 0");

        UserAssetInfo storage user = users[_user];
        require(user.shares > 0, "user.shares is 0");
        require(user.depositAmt > 0, "depositAmt <= 0");

        (uint256 wantAmt, uint256 sharesRemoved) = _withdraw(_wantAmt, _user);
        _earn();
        sharesTotal = sharesTotal.sub(sharesRemoved);
        user.shares = user.shares.sub(sharesRemoved);
        return (wantAmt, sharesRemoved);
    }

    function claim(address _user) 
        public 
        onlyOwner
        nonReentrant
        returns(uint256, uint256)
    {
        (uint256 rewardAmt, uint256 pct) = _claim(_user);
        _earn();
        return (rewardAmt, pct);
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount)
        public
        onlyGov
    {
        require(_token != config.PCT(), "!safe");
        require(_token != stakingToken, "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    /* ========== private method ========== */
    function _earn() private {
        _claimStakingToken();
        _farmStakingToken();
    }

    function _withdraw(uint256 _wantAmt, address _user) private returns(uint256, uint256) {
        UserAssetInfo storage user = users[_user];
        (uint256 wantTotal,) = balance();
        if (_wantAmt > user.depositAmt) {
            _wantAmt = user.depositAmt;
        }
        user.depositAmt = user.depositAmt.sub(_wantAmt);
        uint256 sharesRemoved = _wantAmt.mul(sharesTotal).div(wantTotal);
        if (sharesRemoved > user.shares) {
            sharesRemoved = user.shares;
        }
        
        _withdrawStakingToken(_wantAmt);
        uint256 wantAmt = IERC20(stakingToken).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        bool hasFee = (user.depositedAt.add(minDepositTimeWithNoFee) > block.timestamp) ? true : false;
        if (hasFee) {
            uint256 withdrawFeeAmt = _wantAmt.mul(withdrawFeeFactor).div(feeMax);
            _safeTransfer(stakingToken, devAddress, withdrawFeeAmt);
            _wantAmt = _wantAmt.sub(withdrawFeeAmt);
        }
        _safeTransfer(stakingToken, _user, _wantAmt);

        return (_wantAmt, sharesRemoved);
    }

    function _claim(address _user) private returns(uint256, uint256) {
        uint256 wantAmt = earnedOf(_user);
        if (wantAmt == 0) {
            return(0,0);
        }
        UserAssetInfo storage user = users[_user];
        (uint256 wantTotal,) = balance();
        uint256 sharesRemoved = wantAmt.mul(sharesTotal).div(wantTotal);
        if (sharesRemoved > user.shares) {
            sharesRemoved = user.shares;
        }
        sharesTotal = sharesTotal.sub(sharesRemoved);
        user.shares = user.shares.sub(sharesRemoved);
        //clean dust shares
        if (user.shares > 0 && user.shares < dust) {
            sharesTotal = sharesTotal.sub(user.shares);
            user.shares = 0;
        } 

        _withdrawStakingToken(wantAmt);

        uint256 balanceAmt = IERC20(stakingToken).balanceOf(address(this));
        if (wantAmt > balanceAmt) {
            wantAmt = balanceAmt;
        }

        //performance fee
        (uint256 fee, uint256 pctAmt) = _distributePerformanceFees(wantAmt, _user);
        wantAmt = wantAmt.sub(fee);

        _safeTransfer(stakingToken, _user, wantAmt);
        return (wantAmt, pctAmt);
    }

    function _distributePerformanceFees(uint256 _wantAmt, address _user) private returns(uint256 fee, uint256 pct) {
        if (_wantAmt <= dust) {
            return (0, 0);
        }

        pct = 0;
        fee = performanceFee(_wantAmt);
        if (fee > 0) {
            IPineconeFarm pineconeFarm = config.pineconeFarm();
            uint256 profit = ISmartRouter(smartRouter).getAmountOut(fee, stakingToken, WBNB, swapRouter);
            pct = pineconeFarm.mintForProfit(_user, profit, false);

            uint256 cakeAmt = _swap(fee, stakingToken, CAKE);
            if (cakeAmt > 0) {
                pineconeFarm.stakeRewardsTo(address(pineconeFarm), cakeAmt);
            }
        }
    }

    function _safeApprove(address token, address spender) internal {
        if (token != address(0) && IERC20(token).allowance(address(this), spender) == 0) {
            IERC20(token).safeApprove(spender, uint256(~0));
        }
    }

    function _safeTransfer(address _token, address _to, uint256 _amount) internal {
        if (_amount == 0) return;
        IERC20(_token).safeTransfer(_to, _amount);
    }

    function _swap(uint256 amountIn, address tokenIn, address tokenOut) internal returns(uint256) {
        address[] memory path = ISmartRouter(smartRouter).tokenPath(tokenIn, tokenOut);
        if (swapRouter == CAKE_ROUTER) {
            return _swap(tokenOut, amountIn, path, CAKE_ROUTER);
        } else {
            (, uint256 slippage) = ISmartRouter(smartRouter).getAmountOutAndSlippage(amountIn, path, swapRouter);
            if (slippage < ISmartRouter(smartRouter).minSlippage()) {
                return _swap(tokenOut, amountIn, path, swapRouter);
            } else {
                if (tokenIn == CAKE) {
                    uint256 bnbAmt = _swap(WBNB, amountIn, ISmartRouter(smartRouter).tokenPath(tokenIn, WBNB), CAKE_ROUTER);
                    return _swap(tokenOut, bnbAmt, ISmartRouter(smartRouter).tokenPath(WBNB, tokenOut), swapRouter);
                } else {
                    uint256 bnbAmt = _swap(WBNB, amountIn, ISmartRouter(smartRouter).tokenPath(tokenIn, WBNB), swapRouter);
                    return _swap(tokenOut, bnbAmt, ISmartRouter(smartRouter).tokenPath(WBNB, tokenOut), CAKE_ROUTER);
                }
            }   
        }
    }

    function _swap(address token, uint256 amount, address[] memory path, address router) internal returns(uint256) {
        if (amount == 0 || path.length == 0) return 0;

        uint256 amt = IERC20(path[0]).balanceOf(address(this));
        if (amount > amt) {
            amount = amt;
        }

        uint256 beforeAmount = IERC20(token).balanceOf(address(this));
        IPancakeRouter02(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount,
            0,
            path,
            address(this),
            now + 60
        );

        uint256 afterAmount = IERC20(token).balanceOf(address(this));
        if (afterAmount > beforeAmount) {
            return afterAmount.sub(beforeAmount);
        }
        return 0;
    }

    function _withdrawStakingToken(uint256 _amount) internal {
        if (_amount == 0 || IERC20(stakingToken).balanceOf(address(this)) >= _amount) return;
        uint256 _amt = stakingAmount();
        if (_amount > _amt) {
            _amount = _amt;
        }
        IMasterChef(stratAddress).leaveStaking(_amount);
    }

    function _farmStakingToken() internal {
        uint256 amount = IERC20(stakingToken)).balanceOf(address(this));
        if (amount > 0) {
            IMasterChef(stratAddress).enterStaking(amount);
        }
    }

    function _claimStakingToken() internal {
        IMasterChef(stratAddress).leaveStaking(0);
    }
}