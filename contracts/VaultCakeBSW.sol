// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./VaultBase.sol";
import "./BSWStrat.sol";

//Investment strategy
contract VaultCakeBSW is VaultBase, BSWStrat{

    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    address public constant CAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    function initialize  (
        address _config
    ) external initializer {
        address _stratAddress = 0x73feaa1eE314F8c655E354234017bE2193C9E24E;
        address _stakingToken = CAKE; 

        _VaultBase_init(_config, _stratAddress);
        _StratBSW_init(_stakingToken, CAKE);

        IPineconeFarm pineconeFarm = config.pineconeFarm();
        _safeApprove(CAKE, address(pineconeFarm));

        _safeApprove(CAKE, CAKE_ROUTER);
        _safeApprove(WBNB, CAKE_ROUTER);
    }

    /* ========== public view ========== */
    function stakeType() public pure returns(StakeType) {
        return StakeType.Cake_BSW;
    }

    function earned0Address() public pure returns(address) {
        return CAKE;
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
        uint256 wantValue = wantAmt.mul(_config.priceOfToken(CAKE)).div(UNIT);
        uint256 earned1Value = earned1Amt.mul(_config.priceOfPct()).div(UNIT);
        balanceValue = wantValue.add(earned1Value);
    }

    function tvl() public view returns(uint256 priceInUsd) {
        (uint256 wantAmt, uint256 cakeAmt, uint256 bswAmt) = balance();
        wantAmt = wantAmt.add(cakeAmt);

        IPineconeConfig _config = config;
        uint256 wantTvl = wantAmt.mul(_config.priceOfToken(CAKE)).div(UNIT);
        uint256 bswTvl = bswAmt.mul(_config.priceOfToken(BSW)).div(UNIT);
        return wantTvl.add(bswTvl);
    }

    function balance() public view returns(uint256 wantAmt, uint256 cakeAmt, uint256 bswAmt) {
        wantAmt = _stakingCake();
        cakeAmt = _pendingCake();
        bswAmt = _stakingBSW();
        uint256 pendingBSW = _pendingBSW();
        bswAmt = bswAmt.add(pendingBSW);
    }

    function balanceOf(address _user) public view returns(uint256 wantAmt, uint256 bswAmt) {
        if (sharesTotal == 0) {
            return (0,0);
        }
        
        wantAmt = 0;
        bswAmt = _earnedBSW(_user);
        uint256 shares = sharesOf(_user);
        if (shares != 0) {
            (wantAmt,, ) = balance();
            wantAmt = wantAmt.mul(shares).div(sharesTotal);
        }
    }

    function earnedOf(address _user) public view returns(uint256 wantAmt, uint256 bswAmt) {
        UserAssetInfo storage user = users[_user];
        (wantAmt, bswAmt) = balanceOf(_user);
        if (wantAmt > user.depositAmt) {
            wantAmt = wantAmt.sub(user.depositAmt);
        } else {
            wantAmt = 0;
        }
    }

    function pendingRewardsValue() public view returns(uint256 priceInUsd) {
        uint256 cakeAmt = _pendingCake();
        uint256 bswAmt = _pendingBSW();

        IPineconeConfig _config = config;
        uint256 cakeValue = cakeAmt.mul(_config.priceOfToken(CAKE)).div(UNIT);
        uint256 bswValue = bswAmt.mul(_config.priceOfToken(BSW)).div(UNIT);
        return cakeValue.add(bswValue);
    }    

    function pendingRewards(address _user) public view returns(uint256 wantAmt, uint256 pctAmt)
    {
        if (sharesTotal == 0) {
            return (0, 0);
        }

        (uint256 wantAmt0, uint256 bswAmt) = earnedOf(_user);
        wantAmt = wantAmt0;
        IPineconeConfig _config = config;
        uint256 bswToAmt = _config.getAmountsOut(bswAmt, BSW, CAKE, ROUTER);
        wantAmt = wantAmt.add(bswToAmt);
        uint256 fee = performanceFee(wantAmt);
        pctAmt = _config.tokenAmountPctToMint(CAKE, fee);
        wantAmt = wantAmt.sub(fee);
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
        (uint256 wantTotal,,) = balance();
        if (wantTotal > 0 && sharesTotal > 0) {
            sharesAdded = sharesAdded
                .mul(sharesTotal)
                .div(wantTotal);
        }
        
        _farmCake();
        _reawardCakeToBSW();
        _claimBSW();
        _farmBSW();

        sharesTotal = sharesTotal.add(sharesAdded);
        uint256 pending = user.shares.mul(accPerShareOfBSW).div(1e12).sub(user.rewardPaid);
        user.pending = user.pending.add(pending);
        user.shares = user.shares.add(sharesAdded);
        user.rewardPaid = user.shares.mul(accPerShareOfBSW).div(1e12);
        return sharesAdded;
    }

    function farm() public nonReentrant 
    {
        _farm();
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
        (uint256 earnedWantAmt, uint256 bswAmt) = earnedOf(_user);

        _withdrawCake(wantAmt.add(earnedWantAmt));
        _withdrawBSW(bswAmt);

        uint256 swapAmt = _swap(CAKE, bswAmt, _tokenPath(BSW, CAKE), ROUTER);
        earnedWantAmt = earnedWantAmt.add(swapAmt);

        //withdraw fee 
        uint256 withdrawFeeAmt = 0;
        bool hasFee = (user.depositedAt.add(minDepositTimeWithNoFee) > block.timestamp) ? true : false;
        if (hasFee) {
            withdrawFeeAmt = wantAmt.mul(withdrawFeeFactor).div(feeMax);
            _safeTransfer(CAKE, devAddress, withdrawFeeAmt, address(0));
            wantAmt = wantAmt.sub(withdrawFeeAmt);
        }

        //performace fee
        (uint256 fee, uint256 pctAmt) = _distributePerformanceFees(earnedWantAmt, _user);
        earnedWantAmt = earnedWantAmt.sub(fee);
        wantAmt = wantAmt.add(earnedWantAmt);

        earnedWantAmt = IERC20(CAKE).balanceOf(address(this));
        if (wantAmt > earnedWantAmt) {
            wantAmt = earnedWantAmt;
        }

        _safeTransfer(CAKE, _user, wantAmt, address(0));

        if (user.shares > sharesTotal) {
            sharesTotal = 0;
        } else {
            sharesTotal = sharesTotal.sub(user.shares);
        }
        user.shares = 0;
        user.depositAmt = 0;
        user.depositedAt = 0;
        user.pending = 0;
        user.rewardPaid = 0;

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
        uint256 pending = user.shares.mul(accPerShareOfBSW).div(1e12).sub(user.rewardPaid);
        user.pending = user.pending.add(pending);
        user.shares = user.shares.sub(sharesRemoved);
        user.rewardPaid = user.shares.mul(accPerShareOfBSW).div(1e12);
        return (wantAmt, sharesRemoved);
    }

    function _withdraw(uint256 _wantAmt, address _user) private returns(uint256, uint256) {
        UserAssetInfo storage user = users[_user];
        (uint256 wantTotal,,) = balance();
        if (_wantAmt > user.depositAmt) {
            _wantAmt = user.depositAmt;
        }
        user.depositAmt = user.depositAmt.sub(_wantAmt);
        uint256 sharesRemoved = _wantAmt.mul(sharesTotal).div(wantTotal);
        if (sharesRemoved > user.shares) {
            sharesRemoved = user.shares;
        }
        
        _withdrawCake(_wantAmt);
        uint256 wantAmt = IERC20(CAKE).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        bool hasFee = (user.depositedAt.add(minDepositTimeWithNoFee) > block.timestamp) ? true : false;
        if (hasFee) {
            uint256 withdrawFeeAmt = _wantAmt.mul(withdrawFeeFactor).div(feeMax);
            _safeTransfer(CAKE, devAddress, withdrawFeeAmt, address(0));
            _wantAmt = _wantAmt.sub(withdrawFeeAmt);
        }
        _safeTransfer(CAKE, _user, _wantAmt, address(0));

        return (_wantAmt, sharesRemoved);
    }

    function claim(address _user) 
        public 
        onlyOwner
        nonReentrant
        returns(uint256, uint256)
    {
        (uint256 rewardAmt, uint256 pct) = _claim(_user);
        _earn();
        UserAssetInfo storage user = users[_user];
        user.pending = 0;
        user.rewardPaid = user.shares.mul(accPerShareOfBSW).div(1e12);
        return (rewardAmt, pct);
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount)
        public
        onlyGov
    {
        require(_token != config.PCT(), "!safe");
        require(_token != CAKE, "!safe");
        require(_token != BSW, "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    /* ========== private method ========== */
    function _farm() private {
        _farmCake();
        _farmBSW();
    }

    function _earn() private {
        //auto compounding cake
        _claimCake();
        _reawardCakeToBSW();
        _claimBSW();
        _farm();
    }

    function _claim(address _user) private returns(uint256, uint256) {
        (uint256 wantAmt, uint256 bswAmt) = earnedOf(_user);
        if (wantAmt == 0 && bswAmt == 0) {
            return(0,0);
        }
        UserAssetInfo storage user = users[_user];
        (uint256 wantTotal,,) = balance();
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

        _withdrawCake(wantAmt);
        _withdrawBSW(bswAmt);
        uint256 swapAmt = _swap(CAKE, bswAmt, _tokenPath(BSW, CAKE), ROUTER);
        wantAmt = wantAmt.add(swapAmt);

        uint256 balanceAmt = IERC20(CAKE).balanceOf(address(this));
        if (wantAmt > balanceAmt) {
            wantAmt = balanceAmt;
        }

        //performance fee
        (uint256 fee, uint256 pctAmt) = _distributePerformanceFees(wantAmt, _user);
        wantAmt = wantAmt.sub(fee);

        _safeTransfer(CAKE, _user, wantAmt, address(0));
        return (wantAmt, pctAmt);
    }

    function _distributePerformanceFees(uint256 _amount, address _user) private returns(uint256 fee, uint256 pct) {
        if (_amount <= dust) {
            return (0, 0);
        }

        pct = 0;
        fee = performanceFee(_amount);
        if (fee > 0) {
            IPineconeConfig _config = config;
            uint256 profit = _config.getAmountsOut(fee, CAKE, WBNB, CAKE_ROUTER);
            IPineconeFarm pineconeFarm = _config.pineconeFarm();
            pct = pineconeFarm.mintForProfit(_user, profit, false);
            pineconeFarm.stakeRewardsTo(address(pineconeFarm), fee);
        }
    }
}

