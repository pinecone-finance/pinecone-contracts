// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./VaultBase.sol";
import "./Strat.sol";

//Investment strategy
contract VaultPCTPair is VaultBase, Strat{
    
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    function initialize (
        address _stakingToken,
        address _config ) 
        external initializer
    {
        _VaultBase_init(_config, address(0));
        _StratWex_init(_stakingToken, address(0));
    }

    /* ========== public view ========== */
    function stakeType() public pure returns(StakeType) {
        return StakeType.PCTPair;
    }

    function earned0Address() public view returns(address) {
        return config.PCT();
    }

    function earned1Address() public pure returns(address) {
        return address(0);
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
        uint256 earnedValue = earned0Amt.mul(_config.priceOfPct()).div(UNIT);
        balanceValue = wantValue.add(earnedValue);
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
        return depositAmtOf(_user);
    }

    function earnedOf(address _user) public pure returns(uint256) {
        _user;
        return 0;
    }

    function pendingRewardsValue() public pure returns(uint256 priceInUsd) {
        return 0;
    }

    function pendingRewards(address _user) public pure returns(uint256 wantAmt, uint256 pctAmt)
    {
        _user;
        return (0, 0);
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

        sharesTotal = sharesTotal.add(_wantAmt);
        return _wantAmt;
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

        uint256 _wantAmt = user.depositAmt;
        sharesTotal = sharesTotal.sub(_wantAmt);
        user.depositAmt = 0;
        user.depositedAt = 0;

        uint256 wantAmt = IERC20(stakingToken).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        IERC20(stakingToken).safeTransfer(_user, _wantAmt);
        return (_wantAmt, 0, 0);
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

        uint256 wantAmt = IERC20(stakingToken).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        IERC20(stakingToken).safeTransfer(_user, _wantAmt);
        return (_wantAmt, _wantAmt);
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
}