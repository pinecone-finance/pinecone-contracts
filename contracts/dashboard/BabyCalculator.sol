// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../libraries/SafeMath.sol";
import "../libraries/SafeDecimal.sol";
import "../interfaces/IMasterChef.sol";
import "../interfaces/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract BabyCalculator is OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeDecimal for uint256;

    uint256 private constant BLOCK_PER_DAY = 28800;
    uint256 private constant UNIT = 1e18;

    IMasterChef public constant master = IMasterChef(0xdfAa0e08e357dB0153927C7EaBB492d1F60aC730);
    IERC20 private constant Baby = IERC20(0x53E562b9B7E5E94b81f10e96Ee70Ad06df3D2657);

    function initialize() external initializer {
        __Ownable_init();
    }

    function babyPoolDailyApr() public view returns(uint256) {
        uint256 _totalAllocPoint = master.totalAllocPoint();
        if (_totalAllocPoint == 0) {
            return 0;
        }

        uint256 _perBlock = master.cakePerBlock();
        if (_perBlock == 0) {
            return 0;
        }

        uint256 _perDay = _perBlock.mul(BLOCK_PER_DAY);
        uint256 _balance = Baby.balanceOf(address(master));
        (,uint256 _allocPoint,,) = master.poolInfo(0);
        uint256 _dapr = _perDay.mul(_allocPoint).mul(UNIT).div(_totalAllocPoint).div(_balance);
        return _dapr;
    }
}