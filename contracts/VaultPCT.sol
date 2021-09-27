// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./VaultBase.sol";
import "./Strat.sol";

//Investment strategy
contract VaultPCT is VaultBase, Strat{

    struct CakeRewardToken {
        uint256 startTime;
        uint256 accAmount;
        uint256 totalAmount;
        uint256 accPerShare;
    }
    
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    CakeRewardToken public cakeTokenReward;
    uint256 public calcDuration;

    uint256 public constant SEC_PER_DAY = 1 days;

    function initialize (
        address _config ) 
        external initializer
    {
        require(_config != address(0), "zero address");
        _VaultBase_init(_config, address(0));
        _Strat_init(config.PCT(), address(0));
        calcDuration = 5 days;
    }

    /* ========== public view ========== */
    function stakeType() public pure returns(StakeType) {
        return StakeType.PCT;
    }

    function earned0Address() public pure returns(address) {
        return WBNB;
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
        earned0Amt = 0;
        earned1Amt = _addPct;
        withdrawbaleAmt = withdrawableBalanceOf(_user);

        IPineconeConfig _config = config;
        uint256 wantValue = depositAmt.mul(_config.priceOfToken(stakingToken)).div(UNIT);
        uint256 earned0Value = earned0Amt.mul(_config.priceOfToken(WBNB)).div(UNIT);
        uint256 earned1Value = earned1Amt.mul(_config.priceOfPct()).div(UNIT);
        balanceValue = wantValue.add(earned0Value).add(earned1Value);
    }

    function tvl() public view returns(uint256 priceInUsd) {
        uint256 wantAmt = balance();
        IPineconeConfig _config = config;
        uint256 wantTvl = wantAmt.mul(_config.priceOfToken(stakingToken)).div(UNIT);
        return wantTvl;
    }

    function balance() public view returns(uint256) {
        return sharesTotal;
    }

    function balanceOf(address _user) public view returns(uint256) {
        if (sharesTotal == 0) {
            return 0;
        }

        return depositAmtOf(_user);
    }

    function earnedOf(address _user) public view returns(uint256 bnbAmt, uint256 pctAmt) {
        if (sharesTotal == 0) {
            return (0, 0);
        }

        pctAmt = 0;
        UserAssetInfo storage user = users[_user];
        bnbAmt = user.pending.add(user.shares.mul(cakeTokenReward.accPerShare).div(1e12).sub(user.rewardPaid));
    }

    function pendingRewardsValue() public pure returns(uint256 priceInUsd) {
        return 0;
    }

    function pendingRewards(address _user) public view returns(uint256 bnbAmt, uint256 pctAmt) {
        return earnedOf(_user);
    }

    function setCalDuration(uint256 _duration) public onlyDev {
        require(_duration > SEC_PER_DAY, "duration less than 1 days");
        calcDuration = _duration;
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
        sharesTotal = sharesTotal.add(sharesAdded);
        uint256 pending = user.shares.mul(cakeTokenReward.accPerShare).div(1e12).sub(user.rewardPaid);
        user.pending = user.pending.add(pending);
        user.shares = user.shares.add(sharesAdded);
        user.rewardPaid = user.shares.mul(cakeTokenReward.accPerShare).div(1e12);
        return sharesAdded;
    }

    function withdrawAll(address _user)
        public 
        onlyOwner
        nonReentrant
        returns (uint256, uint256, uint256)
    {
        require(sharesTotal > 0, "sharesTotal is 0");

        UserAssetInfo storage user = users[_user];
        require(user.depositAmt > 0, "depositAmt <= 0");

        (uint256 bnbAmt,) = pendingRewards(_user);

        uint256 _wantAmt = user.depositAmt;
        sharesTotal = sharesTotal.sub(_wantAmt);

        bool hasFee = (user.depositedAt.add(minDepositTimeWithNoFee) > block.timestamp) ? true : false;
        if (hasFee) {
            uint256 withdrawFeeAmt = _wantAmt.mul(withdrawFeeFactor).div(feeMax);
            _safeTransfer(stakingToken, devAddress, withdrawFeeAmt);
            _wantAmt = _wantAmt.sub(withdrawFeeAmt);
        }

        uint256 wantAmt = IERC20(stakingToken).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        IERC20(stakingToken).safeTransfer(_user, _wantAmt);

        user.depositAmt = 0;
        user.depositedAt = 0;
        user.shares = 0;
        user.pending = 0;
        user.rewardPaid = 0;

        return (_wantAmt, bnbAmt, 0);
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
        require(user.depositAmt >= _wantAmt, "depositAmt < _wantAmt");

        sharesTotal = sharesTotal.sub(_wantAmt);
        user.depositAmt = user.depositAmt.sub(_wantAmt);

        uint256 pending = user.shares.mul(cakeTokenReward.accPerShare).div(1e12).sub(user.rewardPaid);
        user.pending = user.pending.add(pending);
        user.shares = user.shares.sub(_wantAmt);
        user.rewardPaid = user.shares.mul(cakeTokenReward.accPerShare).div(1e12);

        uint256 sharesRemoved = _wantAmt;
        bool hasFee = (user.depositedAt.add(minDepositTimeWithNoFee) > block.timestamp) ? true : false;
        if (hasFee) {
            uint256 withdrawFeeAmt = _wantAmt.mul(withdrawFeeFactor).div(feeMax);
            _safeTransfer(stakingToken, devAddress, withdrawFeeAmt);
            _wantAmt = _wantAmt.sub(withdrawFeeAmt);
        }

        uint256 wantAmt = IERC20(stakingToken).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        IERC20(stakingToken).safeTransfer(_user, _wantAmt);
        return (_wantAmt, sharesRemoved);
    }

    function claim(address _user) 
        public 
        onlyOwner
        nonReentrant
        returns(uint256, uint256)
    {
        _user;
        return (0, 0);
    }

    function claimBNB(address _user) 
        public 
        onlyOwner
        nonReentrant
        returns(uint256)
    {
        (uint256 bnbAmt,) = pendingRewards(_user);
        UserAssetInfo storage user = users[_user];
        user.pending = 0;
        user.rewardPaid = user.shares.mul(cakeTokenReward.accPerShare).div(1e12);
        return bnbAmt;
    }

    function updateCakeRewards(uint256 _amount) public onlyOwner {
        if (sharesTotal == 0) {
            return;
        }

        if (cakeTokenReward.startTime == 0) {
            cakeTokenReward.startTime = block.timestamp;
        } else {
            uint256 cap = block.timestamp.sub(cakeTokenReward.startTime);
            if (cap >= calcDuration) {
                cakeTokenReward.startTime = block.timestamp;
                cakeTokenReward.accAmount = 0;
            }
        }
        cakeTokenReward.accAmount = cakeTokenReward.accAmount.add(_amount);
        cakeTokenReward.totalAmount = cakeTokenReward.totalAmount.add(_amount);
        cakeTokenReward.accPerShare = cakeTokenReward.accPerShare.add(_amount.mul(1e12).div(sharesTotal));
    }

    function cakeDailyReward() public view returns(uint256) {
        if (cakeTokenReward.startTime == 0) {
            return 0;
        }

        uint256 cap = block.timestamp.sub(cakeTokenReward.startTime);
        if (cap <= SEC_PER_DAY) {
            return cakeTokenReward.accAmount;
        } else {
            return cakeTokenReward.accAmount.mul(SEC_PER_DAY).div(cap);
        }
    }

    function _safeTransfer(address _token, address _to, uint256 _amount) internal {
        if (_amount == 0) return;
        IERC20(_token).safeTransfer(_to, _amount);
    }
}