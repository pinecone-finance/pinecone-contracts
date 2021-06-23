// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./interfaces/IAlpaca.sol";
import "./VaultBase.sol";
import "./Strat.sol";

//Investment strategy
contract VaultAlpacaWex is VaultBase, Strat{

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IFairLaunch public fairLaunch;
    uint256 public fairLaunchPid;

    address constant ALPACA = 0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F;

    function initialize (
        address _stakingToken,
        address _stratAddress,
        uint256 _fairLaunchPid,
        address _config
    ) external initializer {
        fairLaunchPid = _fairLaunchPid;
        IVaultConfig _vaultConfig = IVault(_stratAddress).config();
        fairLaunch = IFairLaunch(_vaultConfig.getFairLaunchAddr());

        _VaultBase_init(_config, _stratAddress);
        _StratWex_init(_stakingToken, ALPACA);

        _safeApprove(_stakingToken, _stratAddress);
        _safeApprove(_stratAddress, address(fairLaunch));
    }

    receive() external payable {}

    /* ========== public view ========== */
    function farmPid() public view returns(uint256) {
        return fairLaunchPid;
    }

    function stakeType() public pure returns(StakeType) {
        return StakeType.Alpaca_Wex;
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
        (uint256 wantAmt, uint256 wexAmt) = balance();
        IPineconeConfig _config = config;
        uint256 wantTvl = wantAmt.mul(_config.priceOfToken(stakingToken)).div(UNIT);
        uint256 wexTvl = wexAmt.mul(_config.priceOfToken(WEX)).div(UNIT);
        return wantTvl.add(wexTvl);
    }

    function balance() public view returns(uint256 wantAmt, uint256 wexAmt) {
        IAlpacaCalculator alpacaCalculator = config.alpacaCalculator();
        wantAmt = alpacaCalculator.balanceOf(stratAddress, fairLaunchPid, address(this));
        wexAmt = _stakingWex();
    }

    function balanceOf(address _user) public view returns(uint256 wantAmt, uint256 wexAmt) {
        if (sharesTotal == 0) {
            return (0,0);
        }

        wantAmt = 0;
        wexAmt = _pendingWex(_user);
        uint256 shares = sharesOf(_user);
        if (shares != 0) {
            (wantAmt,) = balance();
            wantAmt = wantAmt.mul(shares).div(sharesTotal);
        }
    }

    function earnedOf(address _user) public view returns(uint256 wantAmt, uint256 wexAmt) {
        UserAssetInfo storage user = users[_user];
        (wantAmt, wexAmt) = balanceOf(_user);
        if (wantAmt > user.depositAmt) {
            wantAmt = wantAmt.sub(user.depositAmt);
        } else {
            wantAmt = 0;
        }
    }

    function pendingRewardsValue() public view returns(uint256 priceInUsd) {
        uint256 pendingAlpaca = fairLaunch.pendingAlpaca(fairLaunchPid, address(this));
        uint256 amt = IERC20(ALPACA).balanceOf(address(this));
        pendingAlpaca = pendingAlpaca.add(amt);
        uint256 pendingWex = _pendingWex();

        IPineconeConfig _config = config;
        uint256 alpacaValue = pendingAlpaca.mul(_config.priceOfToken(ALPACA)).div(UNIT);
        uint256 wexValue = pendingWex.mul(_config.priceOfToken(WEX)).div(UNIT);
        return alpacaValue.add(wexValue);
    }

    function pendingRewards(address _user) public view returns(uint256 wantAmt, uint256 pctAmt)
    {
        if (sharesTotal == 0) {
            return (0, 0);
        }

        (uint256 wantAmt0, uint256 wexAmt) = earnedOf(_user);
        wantAmt = wantAmt0;
        IPineconeConfig _config = config;
        uint256 wexToAmt = _config.getAmountsOut(wexAmt, WEX, stakingToken);
        wantAmt = wantAmt.add(wexToAmt);
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
        
        (uint256 wantTotal,) = balance();
        if (wantTotal > 0 && sharesTotal >0) {
            sharesAdded = sharesAdded
                .mul(sharesTotal)
                .div(wantTotal);
        }
        sharesTotal = sharesTotal.add(sharesAdded);
        uint256 pending = user.shares.mul(accPerShareOfWex).div(1e12).sub(user.rewardPaid);
        user.pending = user.pending.add(pending);
        user.shares = user.shares.add(sharesAdded);
        user.rewardPaid = user.shares.mul(accPerShareOfWex).div(1e12);
        _farm();

        return sharesAdded;
    }

    function farm() public nonReentrant 
    {
        _farm();
    }

    function earn() public whenNotPaused onlyGov
    {
        //auto compounding alpaca + wex
        if (lastEarnBlock >= block.number) return;
        fairLaunch.harvest(fairLaunchPid);
        _reawardTokenToWex();
        _claimWex();
        _farm();
        lastEarnBlock = block.number;
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
        (uint256 earnedWantAmt, uint256 wexAmt) = earnedOf(_user);

        _withdrawWant(wantAmt.add(earnedWantAmt));
        _withdrawWex(wexAmt);

        uint256 swapAmt = _swap(stakingToken, wexAmt, _tokenPath(WEX, stakingToken));
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
        return (rewardAmt, pct);
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount)
        public
        onlyGov
    {
        require(_token != config.PCT(), "!safe");
        require(_token != stakingToken, "!safe");
        require(_token != ALPACA, "!safe");
        require(_token != WEX, "!safe");
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
                IVault(stratAddress).deposit{value:wantAmt}(wantAmt);
            }
        } else {
            uint256 wantAmt = IERC20(stakingToken).balanceOf(address(this));
            if (wantAmt > 0) {
                IVault(stratAddress).deposit(wantAmt);
            }
        }

        uint256 ibAmt = IERC20(stratAddress).balanceOf(address(this));
        if (ibAmt > 0) {
            fairLaunch.deposit(address(this), fairLaunchPid, ibAmt);
        }

        _farmWex();
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
        sharesTotal = sharesTotal.sub(sharesRemoved);
        uint256 pending = user.shares.mul(accPerShareOfWex).div(1e12).sub(user.rewardPaid);
        user.pending = user.pending.add(pending);
        user.shares = user.shares.sub(sharesRemoved);
        user.rewardPaid = user.shares.mul(accPerShareOfWex).div(1e12);

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
        IAlpacaCalculator alpacaCalculator = config.alpacaCalculator();
        uint256 amt = alpacaCalculator.balanceOfib(stratAddress, fairLaunchPid, address(this));
        if (amount > amt) {
            amount = amt;
        }
        fairLaunch.withdraw(address(this), fairLaunchPid, amount);
        amt = IERC20(stratAddress).balanceOf(address(this));
        if (amount > amt) {
            amount = amt;
        }

        IVault(stratAddress).withdraw(amount);
        if (stakingToken == WBNB && address(this).balance > 0) {
            IWETH(WBNB).deposit{value:address(this).balance}();
        }
    }

    function _claim(address _user) private returns(uint256, uint256) {
        (uint256 wantAmt, uint256 wexAmt) = earnedOf(_user);
        require(wantAmt > 0 || wexAmt > 0, "wantAmt == 0 && wexAmt == 0");
        UserAssetInfo storage user = users[_user];
        user.pending = 0;
        if (wantAmt > 0) {
            if (user.shares > 0) {
                (uint256 wantTotal, ) = balance();
                uint256 sharesRemoved = wantAmt.mul(sharesTotal).div(wantTotal);
                if (sharesRemoved > user.shares) {
                    sharesRemoved = user.shares;
                }
                sharesTotal = sharesTotal.sub(sharesRemoved);
                user.shares = user.shares.sub(sharesRemoved);
                //clean dust shares
                if (user.shares > 0 && user.shares < dust) {
                    user.shares = 0;
                    sharesTotal = sharesTotal.sub(user.shares);
                    user.rewardPaid = 0;
                } else {
                    user.rewardPaid = user.shares.mul(accPerShareOfWex).div(1e12);
                }
            } else {
                user.rewardPaid = 0;
            }
        } else {
            user.rewardPaid = user.shares.mul(accPerShareOfWex).div(1e12);
        }

        _withdrawWant(wantAmt);
        _withdrawWex(wexAmt);

        uint256 swapAmt = _swap(stakingToken, wexAmt, _tokenPath(WEX, stakingToken));
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
            uint256 profit = config.getAmountsOut(fee, stakingToken, WBNB);
            pct = pineconeFarm.mintForProfit(_user, profit, false);

            uint256 cakeAmt = _swap(CAKE, fee, _tokenPath(stakingToken, CAKE));
            if (cakeAmt > 0) {
                _safeApprove(CAKE, address(pineconeFarm));
                pineconeFarm.stakeRewardsTo(address(pineconeFarm), cakeAmt);
            }
        }
    }
}