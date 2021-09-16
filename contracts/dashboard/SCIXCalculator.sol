// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../libraries/SafeMath.sol";
import "../libraries/SafeDecimal.sol";
import "../libraries/Math.sol";
import "../interfaces/IStakePool.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IDashboard.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract SCIXCalculator is OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeDecimal for uint256;

    uint256 private constant BLOCK_PER_DAY = 28800;
    uint256 private constant UNIT = 1e18;

    IPriceCalculator public constant priceCalculator = IPriceCalculator(0xeCFAd58c39d0108Dc93a07FdBa79A0d0F1286D87);
    IStakePool public constant master = IStakePool(0x68145F3319F819b8E01Dfa3c094fa8205E9EfB9a);
    address private constant SCIX = 0x2CFC48CdFea0678137854F010b5390c5144C0Aa5;
    address private constant ALPACA = 0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F;

    struct Context {
        uint256 startBlock;
        uint256 rewardRate;
        uint256 blocksPerEpoch;
        uint256 reducedRewardRatePerEpoch;
        uint256 totalRewardWeight;
        uint256 totalReducedEpochs;
        uint256 rewardWeight;
    }

    function initialize() external initializer {
        __Ownable_init();
    }

    function poolDailyApr() public view returns(uint256) {
        uint256 alpacaAmt = master.getPoolTotalDeposited(3);
        if (alpacaAmt == 0) {
            return 0;
        }

        uint256 scixPrice = priceCalculator.priceOfToken(SCIX);
        uint256 alpacaPrice = priceCalculator.priceOfToken(ALPACA);

        uint256 scixDailyReward = getDailyReward(3);
        return scixPrice.mul(scixDailyReward).mul(UNIT).div(alpacaAmt).div(alpacaPrice);
    }

    function getDailyReward(uint256 _pid) public view returns(uint256) {
        Context memory ctx = Context(
            master.startBlock(),
            master.rewardRate(),
            master.blocksPerEpoch(),
            master.reducedRewardRatePerEpoch(),
            master.totalRewardWeight(),
            master.totalReducedEpochs(),
            master.getPoolRewardWeight(_pid)
        );

        uint256 from = block.number;
        uint256 to = from + BLOCK_PER_DAY;
        return getBlockReward(ctx, from, to);
    }

    function getBlockReward(Context memory _ctx, uint256 _from, uint256 _to) internal pure returns (uint256) {
        uint256 lastReductionBlock = _ctx.startBlock + _ctx.blocksPerEpoch * _ctx.totalReducedEpochs;

        if (_from >= lastReductionBlock) {
            return _ctx.rewardRate.sub(_ctx.reducedRewardRatePerEpoch.mul(_ctx.totalReducedEpochs))
            .mul(_ctx.rewardWeight).mul(_to - _from).div(_ctx.totalRewardWeight);
        }

        uint256 totalRewards = 0;
        if (_to > lastReductionBlock) {
            totalRewards = _ctx.rewardRate.sub(_ctx.reducedRewardRatePerEpoch.mul(_ctx.totalReducedEpochs))
            .mul(_ctx.rewardWeight).mul(_to - lastReductionBlock).div(_ctx.totalRewardWeight);

            _to = lastReductionBlock;
        }
        return totalRewards + getReduceBlockReward(_ctx, _from, _to);
  }

    function getReduceBlockReward(Context memory _ctx, uint256 _from, uint256 _to) internal pure returns (uint256) {
        _from = Math.max(_ctx.startBlock, _from);
        if (_from >= _to) {
            return 0;
        }
        uint256 epochBegin = _ctx.startBlock.add(_ctx.blocksPerEpoch.mul((_from - _ctx.startBlock) / _ctx.blocksPerEpoch));
        uint256 epochEnd = epochBegin + _ctx.blocksPerEpoch;
        uint256 rewardPerBlock = _ctx.rewardRate.sub(_ctx.reducedRewardRatePerEpoch.mul((_from - _ctx.startBlock) / _ctx.blocksPerEpoch));

        uint256 totalRewards = 0;
        while (_to > epochBegin) {
            uint256 left = Math.max(epochBegin, _from);
            uint256 right = Math.min(epochEnd, _to);
            if (right > left) {
                totalRewards += rewardPerBlock.mul(_ctx.rewardWeight).mul(right - left).div(_ctx.totalRewardWeight);
            }

            rewardPerBlock = rewardPerBlock.sub(_ctx.reducedRewardRatePerEpoch);
            epochBegin = epochEnd;
            epochEnd = epochBegin + _ctx.blocksPerEpoch;
        }
        return totalRewards;
    }
}