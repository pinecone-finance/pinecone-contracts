// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

enum StakeType {
    None,
    PCTPair,
    Rabbit_Mdex,
    Cake_Mdex,
    RewardsCake_Mdex,
    Rabbit_Cake,
    Cake_BSW,
    RewardsCake_BSW,
    Alpaca_BSW,
    HotToken,
    PCT
}

interface IPineconeFarm {
    function add(uint256 _allocPCTPoint, address _want, bool _withUpdate, address _strat) external returns(uint256);
    function set(uint256 _pid, uint256 _allocPCTPoint, bool _withUpdate) external;
    function setMinter(address _minter, bool _canMint) external;
    function mintForProfit(address _to, uint256 _cakeProfit, bool _updatePCTRewards) external returns(uint256);
    function stakeRewardsTo(address _to, uint256 _amount) external;
    function setCakeRewardsPid(uint256 _cakeRewardsPid) external;
    function setPctPerBlock(uint256 _PCTPerBlock, uint256 _startBlock) external;
    function amountPctToMint(uint256 _bnbProfit) external view returns (uint256);
    function inCaseTokensGetStuck(address _token, uint256 _amount) external;
    function dailyEarnedAmount(uint256 _pid) external view returns(uint256);
    function pineconeStratAddress(uint256 _pid) external view returns(address);
    function poolInfoOf(uint256 _pid) external view returns(address want, address strat);
    function userInfoOfPool(uint256 _pid, address _user) external view 
        returns(
            uint256 depositedAt, 
            uint256 depositAmt,
            uint256 balanceValue,
            uint256 earned0Amt,
            uint256 earned1Amt,
            uint256 withdrawbaleAmt
        ); 
    function claimBNB() external;
    function setClaimCoolDown(uint256 _duration) external;
}

interface IPineconeStrategy {
    function earn() external;
    function farm() external;
    function pause() external;
    function unpause() external;
    function sharesTotal() external view returns (uint256);
    function sharesOf(address _user) external view returns(uint256);
    function withdrawableBalanceOf(address _user) external view returns(uint256);
    function deposit(uint256 _wantAmt, address _user) external returns(uint256);
    function depositForPresale(uint256 _wantAmt, address _user) external returns(uint256);
    function withdraw(uint256 _wantAmt, address _user) external returns(uint256, uint256);
    function withdrawAll(address _user) external returns(uint256, uint256, uint256);
    function claim(address _user) external returns(uint256, uint256);
    function claimBNB(uint256 shares, address _user) external returns(uint256);
    function pendingBNB(uint256 _shares, address _user) external view returns(uint256);
    function stakeType() external view returns(StakeType);
    function earned0Address() external view returns(address);
    function earned1Address() external view returns(address);
    function performanceFee(uint256 _profit) external view returns(uint256);
    function stratAddress() external view returns(address);
    function tvl() external view returns(uint256 priceInUsd);
    function farmPid() external view returns(uint256);
    function userInfoOf(address _user, uint256 _addPct) external view 
        returns(
            uint256 depositedAt, 
            uint256 depositAmt,
            uint256 balanceValue,
            uint256 earned0Amt,
            uint256 earned1Amt,
            uint256 withdrawbaleAmt
        ); 
    function inCaseTokensGetStuck(address _token, uint256 _amount) external;
    function stakingToken() external view returns(address);
    function setWithdrawFeeFactor(uint256 _withdrawFeeFactor) external;
    function pendingRewardsValue() external view returns(uint256 priceInUsd);
    function pendingRewards(address _user) external view returns(uint256 wantAmt, uint256 pctAmt);
}

interface IOwner {
    function owner() external view returns (address);
}

interface IVaultPCT {
    function updateCakeRewards(uint256 _amount) external; 
    function cakeDailyReward() external view returns(uint256);
    function claimBNB(address _user) external returns(uint256);
}



