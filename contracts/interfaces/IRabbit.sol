// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IBank {

  function totalToken(address token) external view returns (uint256);

  function deposit(address token, uint256 amount) external payable;

  function withdraw(address token, uint256 pAmount) external;

  function config() external view returns(IBankConfig);

  function ibTokenCalculation(address token, uint256 amount) view external returns(uint256);
}

interface IBankConfig {

    function getInterestRate(uint256 debt, uint256 floating) external view returns (uint256);

    function getReserveBps() external view returns (uint256);

    function getLiquidateBps() external view returns (uint256);
}

interface IFairLaunch {
  function poolLength() external view returns (uint256);

  function addPool(
    uint256 _allocPoint,
    address _stakeToken,
    bool _withUpdate
  ) external;

  function setPool(
    uint256 _pid,
    uint256 _allocPoint,
    bool _withUpdate
  ) external;

  function pendingRabbit(uint256 _pid, address _user) external view returns (uint256);

  function updatePool(uint256 _pid) external;

  function deposit(address _for, uint256 _pid, uint256 _amount) external;

  function withdraw(address _for, uint256 _pid, uint256 _amount) external;

  function withdrawAll(address _for, uint256 _pid) external;

  function harvest(uint256 _pid) external;
}