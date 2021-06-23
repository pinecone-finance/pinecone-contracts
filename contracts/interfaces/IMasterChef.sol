// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IMasterChef {
    function cakePerBlock() view external returns(uint256);
    function totalAllocPoint() view external returns(uint256);

    function poolInfo(uint256 _pid) view external returns(address lpToken, uint256 allocPoint, uint256 lastRewardBlock, uint256 accCakePerShare);
    function userInfo(uint256 _pid, address _account) view external returns(uint256 amount, uint256 rewardDebt);
    function poolLength() view external returns(uint256);

    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
    function emergencyWithdraw(uint256 _pid) external;

    function enterStaking(uint256 _amount) external;
    function leaveStaking(uint256 _amount) external;

    function pendingCake(uint256 _pid, address _user) view external returns (uint256);
}
