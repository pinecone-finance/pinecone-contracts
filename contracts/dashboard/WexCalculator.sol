// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../libraries/SafeMath.sol";
import "../libraries/SafeDecimal.sol";
import "../interfaces/IWexMaster.sol";
import "../interfaces/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

struct PoolInfo {
    IERC20 lpToken;
    uint256 allocPoint;
    uint256 lastRewardBlock;
    uint256 accWexPerShare;
}

interface IWexMaster2 is IWexMaster {
    function poolInfo(uint256) external view returns(PoolInfo memory);
    function wexPerBlock() external view returns(uint256);
    function totalAllocPoint() external view returns(uint256);
}

contract WexCalculator is OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeDecimal for uint256;

    uint256 private constant BLOCK_PER_DAY = 28800;
    uint256 private constant UNIT = 1e18;

    IWexMaster2 private constant wexMaster = IWexMaster2(0x22fB2663C7ca71Adc2cc99481C77Aaf21E152e2D);
    IERC20 private constant WEX = IERC20(0xa9c41A46a6B3531d28d5c32F6633dd2fF05dFB90);

    function initialize() external initializer {
        __Ownable_init();
    }

    function wexPoolDailyApr() public view returns(uint256) {
        uint256 _totalAllocPoint = wexMaster.totalAllocPoint();
        if (_totalAllocPoint == 0) {
            return 0;
        }

        uint256 _balance = WEX.balanceOf(address(wexMaster));
        if (_balance == 0) {
            return 0;
        }

        uint256 _wexPerBlock = wexMaster.wexPerBlock();
        if (_wexPerBlock == 0) {
            return 0;
        }

        uint256 _wexPerDay = _wexPerBlock.mul(BLOCK_PER_DAY);
        PoolInfo memory _info = wexMaster.poolInfo(3);
        uint256 _dapr = _wexPerDay.mul(_info.allocPoint).mul(UNIT).div(_totalAllocPoint).div(_balance);
        return _dapr;
    }
}