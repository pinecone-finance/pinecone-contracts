// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IStakePool {
    function getPoolTotalDeposited(uint256 _poolId) external view returns (uint256);
    function getStakeTotalDeposited(address _account, uint256 _poolId) external view returns (uint256);
    function getStakeTotalUnclaimed(address _account, uint256 _poolId) external view returns (uint256);
    function deposit(uint256 _poolId, uint256 _depositAmount) external;
    function withdraw(uint256 _poolId, uint256 _withdrawAmount) external;
    function exit(uint256 _poolId) external;
    function claim(uint256 _poolId) external;
    function rewardRate() external view returns (uint256);
    function startBlock() external view returns (uint256);
    function blocksPerEpoch() external view returns (uint256);
    function reducedRewardRatePerEpoch() external view returns (uint256);
    function totalReducedEpochs() external view returns (uint256);
    function totalRewardWeight() external view returns (uint256);
    function getPoolRewardWeight(uint256 _poolId) external view returns (uint256);
}