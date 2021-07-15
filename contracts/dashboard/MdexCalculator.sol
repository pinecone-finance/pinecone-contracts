// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../libraries/SafeMath.sol";
import "../libraries/SafeDecimal.sol";
import "../interfaces/IBoardRoomMDX.sol";
import "../interfaces/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

struct PoolInfo {
    IERC20 lpToken;
    uint256 allocPoint;
    uint256 lastRewardBlock;
    uint256 accMDXPerShare;
    uint256 mdxAmount;
}

interface IBoardRoomMDX2 is IBoardRoomMDX {
    function poolInfo(uint256) external view returns(PoolInfo memory);
    function mdxPerBlock() external view returns(uint256);
    function totalAllocPoint() external view returns(uint256);
}

contract MdexCalculator is OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeDecimal for uint256;

    uint256 private constant BLOCK_PER_DAY = 28800;
    uint256 private constant UNIT = 1e18;

    IBoardRoomMDX2 private constant master = IBoardRoomMDX2(0x6aEE12e5Eb987B3bE1BA8e621BE7C4804925bA68);
    IERC20 private constant MDEX = IERC20(0x9C65AB58d8d978DB963e63f2bfB7121627e3a739);

    function initialize() external initializer {
        __Ownable_init();
    }

    function mdexPoolDailyApr() public view returns(uint256) {
        uint256 _totalAllocPoint = master.totalAllocPoint();
        if (_totalAllocPoint == 0) {
            return 0;
        }

        uint256 _perBlock = master.mdxPerBlock();
        if (_perBlock == 0) {
            return 0;
        }

        uint256 _perDay = _perBlock.mul(BLOCK_PER_DAY);
        PoolInfo memory _info = master.poolInfo(4);
        uint256 _balance = _info.mdxAmount;
        uint256 _dapr = _perDay.mul(_info.allocPoint).mul(UNIT).div(_totalAllocPoint).div(_balance);
        return _dapr;
    }
}