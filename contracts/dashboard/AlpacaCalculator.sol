// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../libraries/SafeMath.sol";
import "../interfaces/IAlpaca.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IDashboard.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// Info of each user.
struct UserInfo {
    uint256 amount; // How many Staking tokens the user has provided.
    uint256 rewardDebt; // Reward debt. See explanation below.
    uint256 bonusDebt; // Last block that user exec something to the pool.
    address fundedBy; // Funded by who?
    //
    // We do some fancy math here. Basically, any point in time, the amount of ALPACAs
    // entitled to a user but is pending to be distributed is:
    //
    //   pending reward = (user.amount * pool.accAlpacaPerShare) - user.rewardDebt
    //
    // Whenever a user deposits or withdraws Staking tokens to a pool. Here's what happens:
    //   1. The pool's `accAlpacaPerShare` (and `lastRewardBlock`) gets updated.
    //   2. User receives the pending reward sent to his/her address.
    //   3. User's `amount` gets updated.
    //   4. User's `rewardDebt` gets updated.
}

// Info of each pool.
struct PoolInfo {
    address stakeToken; // Address of Staking token contract.
    uint256 allocPoint; // How many allocation points assigned to this pool. ALPACAs to distribute per block.
    uint256 lastRewardBlock; // Last block number that ALPACAs distribution occurs.
    uint256 accAlpacaPerShare; // Accumulated ALPACAs per share, times 1e12. See below.
    uint256 accAlpacaPerShareTilBonusEnd; // Accumated ALPACAs per share until Bonus End.
}

interface IFairLaunch2 is IFairLaunch {
    function alpacaPerBlock() external view returns(uint256);
    function poolInfo(uint256) external view returns(PoolInfo memory);
    function totalAllocPoint() external view returns(uint256);
    function userInfo(uint256, address) external view returns(UserInfo memory);
}

contract AlpacaCalculator is OwnableUpgradeable {
    using SafeMath for uint256;
    uint256 private constant UNIT = 1e18;
    uint256 private constant SEC_PER_YEAR = 365 days; 
    uint256 private constant BLOCK_PER_DAY = 28800;
    address private constant ALPACA = 0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F;
    IPriceCalculator public priceCalculator;
    ISCIXCalculator public constant scixCalculator = ISCIXCalculator(0x68b5087388023e2dcf55da2a8b5613FdA310E2ce);
    
    function initialize() external initializer {
        __Ownable_init();
    }

    function setPriceCalculator(address addr) external onlyOwner {
        priceCalculator = IPriceCalculator(addr);
    }

    function vaultInterest(address vault) public view returns(uint256) {
        IVaultConfig config = IVault(vault).config();
        uint256 _vaultDebtVal = IVault(vault).vaultDebtVal();
        uint256 _totalToken = IVault(vault).totalToken();
        uint256 floating = 0;
        if (_totalToken > _vaultDebtVal) {
            floating = _totalToken.sub(_vaultDebtVal);
        }
        uint256 ratePerSec = config.getInterestRate(_vaultDebtVal, floating);
        return ratePerSec;
    }

    function vaultUtilization(address vault) public view returns(uint256) {
        uint256 _vaultDebtVal = IVault(vault).vaultDebtVal();
        uint256 _totalToken = IVault(vault).totalToken();
        if (_totalToken == 0) {
            return 0;
        }

        return _vaultDebtVal.mul(UNIT).div(_totalToken);
    }

    function vaultApr(address vault, uint256 pid) public view returns(uint256 _apr, uint256 _alpacaApr) {
        uint256 utilization = vaultUtilization(vault);
        uint256 interest = vaultInterest(vault);
        IVaultConfig config = IVault(vault).config();
        uint256 fee = config.getReservePoolBps();
        _apr = interest.mul(SEC_PER_YEAR).mul(utilization).div(UNIT);
        _apr = _apr.mul(10000 - fee).div(10000);

        (uint256 tokenPerBlock, uint256 supplyOfPool) = alpacaPerBlock(vault, pid);
        uint256 tokenValuePerDay = tokenPerBlock.mul(BLOCK_PER_DAY).mul(priceOfAlpaca()).div(UNIT);
        uint256 tvlOfPool = supplyOfPool.mul(priceOfToken(IVault(vault).token())).div(UNIT);

        _alpacaApr = 0;
        if (tvlOfPool > 0) {
            _alpacaApr = tokenValuePerDay.mul(365).mul(UNIT).div(tvlOfPool);
        }
    }

    function alpacaAprOfSCIX() public view returns(uint256 _lendApr, uint256 _stakingApr) {
        address vault = 0xf1bE8ecC990cBcb90e166b71E368299f0116d421;
        uint256 utilization = vaultUtilization(vault);
        uint256 interest = vaultInterest(vault);
        IVaultConfig config = IVault(vault).config();
        uint256 fee = config.getReservePoolBps();
        _lendApr = interest.mul(SEC_PER_YEAR).mul(utilization).div(UNIT);
        _lendApr = _lendApr.mul(10000 - fee).div(10000);

        _stakingApr = scixCalculator.poolDailyApr().mul(365);
    }

    function priceOfAlpaca() public view returns(uint256) {
        return priceCalculator.priceOfToken(ALPACA);
    }

    function priceOfToken(address token) public view returns(uint256) {
        return priceCalculator.priceOfToken(token);
    }

    function alpacaPerBlock(address vault, uint256 pid) public view returns(uint256 tokenPerBlock, uint256 supplyOfPool) {
        IVaultConfig config = IVault(vault).config();
        IFairLaunch2 fairLaunch = IFairLaunch2(config.getFairLaunchAddr());
        uint256 totalPoint = fairLaunch.totalAllocPoint();
        uint256 perBlock = fairLaunch.alpacaPerBlock();
        PoolInfo memory info = fairLaunch.poolInfo(pid);
        if (totalPoint == 0) {
            return (0,0);
        }

        tokenPerBlock = perBlock.mul(info.allocPoint).div(totalPoint);
        supplyOfPool = IERC20(info.stakeToken).balanceOf(address(fairLaunch));
    }

    function balanceOf(address vault, uint256 pid, address account) public view returns(uint256) {
        uint256 ibAmt = balanceOfib(vault, pid, account);
        uint256 total = IVault(vault).totalToken();
        uint256 supply = IERC20(address(vault)).totalSupply();
        if (supply == 0) {
            return ibAmt;
        }

        ibAmt = ibAmt.mul(total).div(supply);
        return ibAmt;
    }

    function balanceOfib(address vault, uint256 pid, address account) public view returns(uint256) {
        IVaultConfig config = IVault(vault).config();
        IFairLaunch2 fairLaunch = IFairLaunch2(config.getFairLaunchAddr());
        UserInfo memory user = fairLaunch.userInfo(pid, account);
        return user.amount;
    }

    function ibTokenCalculation(address vault, uint256 amount) public view returns(uint256) {
        uint256 total = IVault(vault).totalToken();
        total = total.sub(amount);
        uint256 supply = IERC20(address(vault)).totalSupply();
        if (total == 0) {
            return amount;
        }

        return amount.mul(supply).div(total);
    }
}