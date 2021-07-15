// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../libraries/SafeMath.sol";
import "../interfaces/IRabbit.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IDashboard.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

struct TokenBank {
    address tokenAddr; 
    address ibTokenAddr; 
    bool isOpen;
    bool canDeposit; 
    bool canWithdraw; 
    uint256 totalVal;
    uint256 totalDebt;
    uint256 totalDebtShare;
    uint256 totalReserve;
    uint256 lastInterestTime;
}

// Info of each user.
struct UserInfo {
    uint256 amount; // How many Staking tokens the user has provided.
    uint256 rewardDebt; // Reward debt. See explanation below.
    uint256 bonusDebt; // Last block that user exec something to the pool.
    address fundedBy; // Funded by who?
}
  
// Info of each pool.
struct PoolInfo {
    address stakeToken; // Address of Staking token contract.
    uint256 allocPoint; // How many allocation points assigned to this pool. Rabbits to distribute per block.
    uint256 lastRewardBlock; // Last block number that Rabbits distribution occurs.
    uint256 accRabbitPerShare; // Accumulated Rabbits per share, times 1e12. See below.
    uint256 accRabbitPerShareTilBonusEnd; // Accumated Rabbits per share until Bonus End.
}

interface IBank2 is IBank {
    function banks(address) external view returns(TokenBank memory);
}

interface IFairLaunch2 is IFairLaunch {
    function rabbitPerBlock() external view returns(uint256);
    function poolInfo(uint256) external view returns(PoolInfo memory);
    function totalAllocPoint() external view returns(uint256);
    function userInfo(uint256, address) external view returns(UserInfo memory);
}

contract RabbitCalculator is OwnableUpgradeable {
    using SafeMath for uint256;
    uint256 private constant UNIT = 1e18;
    uint256 private constant SEC_PER_YEAR = 365 days; 
    uint256 private constant BLOCK_PER_DAY = 28800;
    address private constant RABBIT = 0x95a1199EBA84ac5f19546519e287d43D2F0E1b41;
    IBank2 public constant RabbitBank = IBank2(0xc18907269640D11E2A91D7204f33C5115Ce3419e);
    IFairLaunch2 public constant FairLaunch = IFairLaunch2(0x81C1e8A6f8eB226aA7458744c5e12Fc338746571);
    IPriceCalculator public priceCalculator;
    
    function initialize() external initializer {
        __Ownable_init();
    }

    function setPriceCalculator(address addr) external onlyOwner {
        priceCalculator = IPriceCalculator(addr);
    }

    function vaultInterest(address token) public view returns(uint256) {
        token = _toToken(token);
        IBankConfig config = RabbitBank.config();
        TokenBank memory bank = RabbitBank.banks(token);
        uint256 totalDebt = bank.totalDebt;
        uint256 totalBalance = RabbitBank.totalToken(token);
            
        uint256 ratePerSec = config.getInterestRate(totalDebt, totalBalance);
        return ratePerSec;
    }

    function vaultUtilization(address token) public view returns(uint256) {
        token = _toToken(token);
        TokenBank memory bank = RabbitBank.banks(token);
        uint256 totalDebt = bank.totalDebt;
        uint256 totalBalance = RabbitBank.totalToken(token);
        if (totalBalance == 0) {
            return 0;
        }

        return totalDebt.mul(UNIT).div(totalBalance);
    }

    function priceOfRabbit() public view returns(uint256) {
        return priceCalculator.priceOfToken(RABBIT);
    }

    function priceOfToken(address token) public view returns(uint256) {
        return priceCalculator.priceOfToken(token);
    }

    function vaultApr(address token, uint256 pid) public view returns(uint256 _apr, uint256 _rabbitApr) {
        token = _toToken(token);
        uint256 utilization = vaultUtilization(token);
        uint256 interest = vaultInterest(token);
        IBankConfig config = RabbitBank.config();
        uint256 fee = config.getReserveBps();
        _apr = interest.mul(SEC_PER_YEAR).mul(utilization).div(UNIT);
        _apr = _apr.mul(10000 - fee).div(10000);

        (uint256 tokenPerBlock, uint256 supplyOfPool) = rabbitPerBlock(pid);
        uint256 tokenValuePerDay = tokenPerBlock.mul(BLOCK_PER_DAY).mul(priceOfRabbit()).div(UNIT);
        uint256 tvlOfPool = supplyOfPool.mul(priceOfToken(token)).div(UNIT);

        _rabbitApr = 0;
        if (tvlOfPool > 0) {
            _rabbitApr = tokenValuePerDay.mul(365).mul(UNIT).div(tvlOfPool);
        }
    }

    function rabbitPerBlock(uint256 pid) public view returns(uint256 tokenPerBlock, uint256 supplyOfPool) {
        uint256 totalPoint = FairLaunch.totalAllocPoint();
        uint256 perBlock = FairLaunch.rabbitPerBlock();
        PoolInfo memory info = FairLaunch.poolInfo(pid);
        if (totalPoint == 0) {
            return (0,0);
        }

        tokenPerBlock = perBlock.mul(info.allocPoint).div(totalPoint);
        supplyOfPool = IERC20(info.stakeToken).balanceOf(address(FairLaunch));
    }

    function balanceOf(address token, uint256 pid, address account) public view returns(uint256) {
        token = _toToken(token);
        uint256 ibAmt = balanceOfib(pid, account);
        uint256 total = RabbitBank.totalToken(token);
        TokenBank memory bank = RabbitBank.banks(token);
        uint256 supply = IERC20(bank.ibTokenAddr).totalSupply();
        if (supply == 0) {
            return ibAmt;
        }

        uint256 amt = ibAmt.mul(total).div(supply);
        return amt;
    }

    function balanceOfib(uint256 pid, address account) public view returns(uint256) {
        UserInfo memory user = FairLaunch.userInfo(pid, account);
        return user.amount;
    }

    function ibToken(address token) public view returns(address) {
        token = _toToken(token);
        TokenBank memory bank = RabbitBank.banks(token);
        return bank.ibTokenAddr;
    }

    function _toToken(address token) private pure returns(address) {
        return (token == 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c) ? address(0) : token;
    }
}