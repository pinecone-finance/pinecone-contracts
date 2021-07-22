// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./interfaces/IRabbit.sol";
import "./VaultBase.sol";
import "./CakeStrat.sol";

//Investment strategy
contract VaultRabbitCake is VaultBase, CakeStrat{

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public fairLaunchPid;

    address public constant RABBIT = 0x95a1199EBA84ac5f19546519e287d43D2F0E1b41;
    IBank public constant RabbitBank = IBank(0xc18907269640D11E2A91D7204f33C5115Ce3419e);
    IFairLaunch public constant FairLaunch = IFairLaunch(0x81C1e8A6f8eB226aA7458744c5e12Fc338746571);

    function initialize (
        address _stakingToken,
        uint256 _fairLaunchPid,
        address _config
    ) external initializer {
        fairLaunchPid = _fairLaunchPid;

        _VaultBase_init(_config, address(RabbitBank));
        _StratCake_init(_stakingToken, RABBIT);

        _safeApprove(_stakingToken, address(RabbitBank));
        address ibToken = _ibToken();
        _safeApprove(ibToken, address(FairLaunch));

        IPineconeFarm pineconeFarm = config.pineconeFarm();
        _safeApprove(CAKE, address(pineconeFarm));
    }

    receive() external payable {}

    /* ========== public view ========== */

    function farmPid() public view returns(uint256) {
        return fairLaunchPid;
    }

    function stakeType() public pure returns(StakeType) {
        return StakeType.Rabbit_Cake;
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
        (uint256 wantAmt, uint256 rabbitAmt, uint256 cakeAmt) = balance();
        IPineconeConfig _config = config;
        uint256 wantTvl = wantAmt.mul(_config.priceOfToken(stakingToken)).div(UNIT);
        uint256 rabbitTvl = rabbitAmt.mul(_config.priceOfToken(RABBIT)).div(UNIT);
        uint256 cakeTvl = cakeAmt.mul(_config.priceOfToken(CAKE)).div(UNIT);
        return wantTvl.add(rabbitTvl).add(cakeTvl);
    }

    function balance() public view returns(uint256 wantAmt, uint256 rabbitAmt, uint256 cakeAmt) {
        IRabbitCalculator rabbitCalculator = config.rabbitCalculator();
        wantAmt = rabbitCalculator.balanceOf(_stakingTokenForRabbit(), fairLaunchPid, address(this));
        rabbitAmt = FairLaunch.pendingRabbit(fairLaunchPid, address(this));
        cakeAmt = _stakingCake();
        uint256 pendingCake = _pendingCake();
        cakeAmt = cakeAmt.add(pendingCake);
    }

    function balanceOf(address _user) public view returns(uint256 wantAmt, uint256 cakeAmt) {
        if (sharesTotal == 0) {
            return (0,0);
        }

        wantAmt = 0;
        cakeAmt = _earnedCake(_user);
        uint256 shares = sharesOf(_user);
        if (shares != 0) {
            (wantAmt,,) = balance();
            wantAmt = wantAmt.mul(shares).div(sharesTotal);
        }
    }

    function earnedOf(address _user) public view returns(uint256 wantAmt, uint256 cakeAmt) {
        UserAssetInfo storage user = users[_user];
        (wantAmt, cakeAmt) = balanceOf(_user);
        if (wantAmt > user.depositAmt) {
            wantAmt = wantAmt.sub(user.depositAmt);
        } else {
            wantAmt = 0;
        }
    }

    function pendingRewardsValue() public view returns(uint256 priceInUsd) {
        uint256 pendingRabbit = FairLaunch.pendingRabbit(fairLaunchPid, address(this));
        uint256 amt = IERC20(RABBIT).balanceOf(address(this));
        pendingRabbit = pendingRabbit.add(amt);
        uint256 pendingCake = _pendingCake();

        IPineconeConfig _config = config;
        uint256 rabbitValue = pendingRabbit.mul(_config.priceOfToken(RABBIT)).div(UNIT);
        uint256 cakeValue = pendingCake.mul(_config.priceOfToken(CAKE)).div(UNIT);
        return rabbitValue.add(cakeValue);
    }

    function pendingRewards(address _user) public view returns(uint256 wantAmt, uint256 pctAmt)
    {
        if (sharesTotal == 0) {
            return (0, 0);
        }

        (uint256 wantAmt0, uint256 cakeAmt) = earnedOf(_user);
        wantAmt = wantAmt0;
        IPineconeConfig _config = config;
        uint256 cakeToAmt = _config.getAmountsOut(cakeAmt, CAKE, stakingToken, ROUTER);
        wantAmt = wantAmt.add(cakeToAmt);
        uint256 fee = performanceFee(wantAmt);
        pctAmt = _config.tokenAmountPctToMint(stakingToken, fee);
        wantAmt = wantAmt.sub(fee);
    }

    /* ========== public write ========== */
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
        if (wantTotal > 0 && sharesTotal >0) {
            sharesAdded = sharesAdded
                .mul(sharesTotal)
                .div(wantTotal);
        }
        
        _farm();
        sharesTotal = sharesTotal.add(sharesAdded);
        uint256 pending = user.shares.mul(accPerShareOfCake).div(1e12).sub(user.rewardPaid);
        user.pending = user.pending.add(pending);
        user.shares = user.shares.add(sharesAdded);
        user.rewardPaid = user.shares.mul(accPerShareOfCake).div(1e12);

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
        require(user.shares > 0, "user.shares is 0");
        require(user.depositAmt > 0, "depositAmt <= 0");

        uint256 wantAmt = user.depositAmt;
        (uint256 earnedWantAmt, uint256 cakeAmt) = earnedOf(_user);

        _withdrawWant(wantAmt.add(earnedWantAmt));
        _withdrawCake(cakeAmt);

        uint256 swapAmt = _swap(stakingToken, cakeAmt, _tokenPath(CAKE, stakingToken), ROUTER);
        earnedWantAmt = earnedWantAmt.add(swapAmt);

        address wNativeRelayer = config.wNativeRelayer();
        //withdraw fee
        {
            uint256 withdrawFeeAmt = 0;
            bool hasFee = (user.depositedAt.add(minDepositTimeWithNoFee) > block.timestamp) ? true : false;
            if (hasFee) {
                withdrawFeeAmt = wantAmt.mul(withdrawFeeFactor).div(feeMax);
                _safeTransfer(stakingToken, devAddress, withdrawFeeAmt, wNativeRelayer);
                wantAmt = wantAmt.sub(withdrawFeeAmt);
            }
        }

        //performace fee
        (uint256 fee, uint256 pctAmt) = _distributePerformanceFees(earnedWantAmt, _user);
        earnedWantAmt = earnedWantAmt.sub(fee);
        wantAmt = wantAmt.add(earnedWantAmt);

        {
            uint256 balanceAmt = IERC20(stakingToken).balanceOf(address(this));
            if (wantAmt > balanceAmt) {
                wantAmt = balanceAmt;
            }
            _safeTransfer(stakingToken, _user, wantAmt, wNativeRelayer);
        }

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
    
        _farm();
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
        _farm();
        sharesTotal = sharesTotal.sub(sharesRemoved);
        uint256 pending = user.shares.mul(accPerShareOfCake).div(1e12).sub(user.rewardPaid);
        user.pending = user.pending.add(pending);
        user.shares = user.shares.sub(sharesRemoved);
        user.rewardPaid = user.shares.mul(accPerShareOfCake).div(1e12);

        return (wantAmt, sharesRemoved);
    }

    function claim(address _user) 
        public 
        onlyOwner
        nonReentrant
        returns(uint256, uint256)
    {
        (uint256 rewardAmt, uint256 pct) = _claim(_user);
        _farm();
        UserAssetInfo storage user = users[_user];
        user.pending = 0;
        user.rewardPaid = user.shares.mul(accPerShareOfCake).div(1e12);
        return (rewardAmt, pct);
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount)
        public
        onlyGov
    {
        require(_token != config.PCT(), "!safe");
        require(_token != stakingToken, "!safe");
        require(_token != RABBIT, "!safe");
        require(_token != CAKE, "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    /* ========== private methord ========== */
    function _farm() private 
    {
        if (stakingToken == WBNB) {
            uint256 wantAmt = IERC20(stakingToken).balanceOf(address(this));
            if (wantAmt > 0) {
                address wNativeRelayer = config.wNativeRelayer();
                IERC20(WBNB).safeTransfer(wNativeRelayer, wantAmt);
                IWNativeRelayer(wNativeRelayer).withdraw(wantAmt);
            }
            wantAmt = address(this).balance;
            if (wantAmt > 0) {
                IBank(stratAddress).deposit{value:wantAmt}(address(0), wantAmt);
            }
        } else {
            uint256 wantAmt = IERC20(stakingToken).balanceOf(address(this));
            if (wantAmt > 0) {
                IBank(stratAddress).deposit(stakingToken, wantAmt);
            }
        }

        uint256 ibAmt = IERC20(_ibToken()).balanceOf(address(this));
        if (ibAmt > 0) {
            FairLaunch.deposit(address(this), fairLaunchPid, ibAmt);
        }

        _reawardTokenToCake();
        _claimCake();
        _farmCake();
    }

    function _earn() private {
         //auto compounding rabbit + cake
        if (FairLaunch.pendingRabbit(fairLaunchPid, address(this)) > 0) {
            FairLaunch.harvest(fairLaunchPid);
        }
        _farm();
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
    
        _withdrawWant(_wantAmt);
        uint256 wantAmt = IERC20(stakingToken).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        address wNativeRelayer = config.wNativeRelayer();
        bool hasFee = (user.depositedAt.add(minDepositTimeWithNoFee) > block.timestamp) ? true : false;
        if (hasFee) {
            uint256 withdrawFeeAmt = _wantAmt.mul(withdrawFeeFactor).div(feeMax);
            _safeTransfer(stakingToken, devAddress, withdrawFeeAmt, wNativeRelayer);
            _wantAmt = _wantAmt.sub(withdrawFeeAmt);
        }
        _safeTransfer(stakingToken, _user, _wantAmt, wNativeRelayer);

        return (_wantAmt, sharesRemoved);
    }

    function _withdrawWant(uint256 amount) private  {
        if (amount == 0) return;
        amount = RabbitBank.ibTokenCalculation(_stakingTokenForRabbit(), amount);
        IRabbitCalculator rabbitCalculator = config.rabbitCalculator();
        uint256 amt = rabbitCalculator.balanceOfib(fairLaunchPid, address(this));
        if (amount > amt) {
            amount = amt;
        }
        FairLaunch.withdraw(address(this), fairLaunchPid, amount);
        RabbitBank.withdraw(_stakingTokenForRabbit(), amount);
        if (stakingToken == WBNB && address(this).balance > 0) {
            IWETH(WBNB).deposit{value:address(this).balance}();
        }
    }

    function _claim(address _user) private returns(uint256, uint256) {
        (uint256 wantAmt, uint256 cakeAmt) = earnedOf(_user);
        if (wantAmt == 0 && cakeAmt == 0) {
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

        _withdrawWant(wantAmt);
        _withdrawCake(cakeAmt);

        uint256 swapAmt = _swap(stakingToken, cakeAmt, _tokenPath(CAKE, stakingToken), ROUTER);
        wantAmt = wantAmt.add(swapAmt);

        uint256 balanceAmt = IERC20(stakingToken).balanceOf(address(this));
        if (wantAmt > balanceAmt) {
            wantAmt = balanceAmt;
        }

        //performance fee
        (uint256 fee, uint256 pctAmt) = _distributePerformanceFees(wantAmt, _user);
        wantAmt = wantAmt.sub(fee);
        _safeTransfer(stakingToken, _user, wantAmt, config.wNativeRelayer());
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
            uint256 profit = config.getAmountsOut(fee, stakingToken, WBNB, ROUTER);
            pct = pineconeFarm.mintForProfit(_user, profit, false);

            uint256 cakeAmt = _swap(CAKE, fee, _tokenPath(stakingToken, CAKE), ROUTER);
            if (cakeAmt > 0) {
                pineconeFarm.stakeRewardsTo(address(pineconeFarm), cakeAmt);
            }
        }
    }

    function _stakingTokenForRabbit() private view returns(address) {
        return (stakingToken == WBNB ) ? address(0) : stakingToken;
    }

    function _ibToken() private view returns(address) {
        IRabbitCalculator calculator = config.rabbitCalculator();
        address ibToken = calculator.ibToken(_stakingTokenForRabbit());
        return ibToken;
    }
}   