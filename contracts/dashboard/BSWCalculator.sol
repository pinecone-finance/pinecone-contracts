// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../libraries/SafeMath.sol";
import "../libraries/SafeDecimal.sol";
import "../interfaces/IMasterChef.sol";
import "../interfaces/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract BSWCalculator is OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeDecimal for uint256;

    uint256 private constant BLOCK_PER_DAY = 28800;
    uint256 private constant UNIT = 1e18;

    IBSWMasterChef public constant bswMaster = IBSWMasterChef(0xDbc1A13490deeF9c3C12b44FE77b503c1B061739);
    IERC20 private constant BSW = IERC20(0x965F527D9159dCe6288a2219DB51fc6Eef120dD1);

    function initialize() external initializer {
        __Ownable_init();
    }

    function bswPoolDailyApr() public view returns(uint256) {
        uint256 _totalAllocPoint = bswMaster.totalAllocPoint();
        if (_totalAllocPoint == 0) {
            return 0;
        }

        uint256 _perBlock = bswMaster.BSWPerBlock();
        if (_perBlock == 0) {
            return 0;
        }

        uint256 _perDay = _perBlock.mul(BLOCK_PER_DAY);
        uint256 _balance = bswMaster.depositedBsw();
        (,uint256 _allocPoint,,) = bswMaster.poolInfo(0);
        uint256 _dapr = _perDay.mul(_allocPoint).mul(UNIT).div(_totalAllocPoint).div(_balance);
        return _dapr;
    }
}