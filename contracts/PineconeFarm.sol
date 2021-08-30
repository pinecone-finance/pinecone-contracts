// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
import "./helpers/ERC20.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IPinecone.sol";
import "./interfaces/IPineconeToken.sol";
import "./interfaces/IWETH.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

struct UserInfo {
    uint256 shares;
    uint256 pending; 
    uint256 rewardPaid;
}

struct UserRewardBNB {
    uint256 shares;
    uint256 pending; 
    uint256 rewardPaid;
    uint256 lastRewardTime;
    uint256 claimed;
}

struct PoolInfo {
    IERC20 want; 
    uint256 allocPCTPoint; 
    uint256 accPCTPerShare; 
    uint256 lastRewardBlock;
    address strat;
}

struct RewardToken {
    uint256 startTime;
    uint256 accAmount;
    uint256 totalAmount;
}

struct CakeRewardToken {
    uint256 startTime;
    uint256 accAmount;
    uint256 totalAmount;
    uint256 accPerShare;
}

contract PineconeFarm is OwnableUpgradeable, ReentrancyGuardUpgradeable, IPineconeTokenCallee {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public PCTPerBlock;
    uint256 public startBlock;
    PoolInfo[] public poolInfo; 
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    uint256 public totalPCTAllocPoint; // Total allocation points. Must be the sum of all allocation points in all pools.

    RewardToken public pctTokenReward;
    CakeRewardToken public cakeTokenReward;
    mapping(address => UserRewardBNB) public userRewardBNB;

    address public pctAddress; //address of pct token
    address public pctPairAddress; //address of pct-bnb lp token

    mapping(address => bool) minters;
    uint256 public pctPerProfitBNB;
    uint256 public constant teamPCTReward = 250; //20%
    address public devAddress;
    address public teamRewardsAddress;

    uint256 public cakeRewardsStakingPid;

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    uint256 public claimCoolDown;
    uint256 public calcDuration;
    uint256 public constant SEC_PER_DAY = 1 days;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    mapping(address => bool) public whiteListContract;

    uint256 public pctStakingPid;
    uint256 public cakeRewardsStakingNewPid;

    //optimize gas fee
    uint256 public balanceOfPct; 
    uint256 public optimizeStartBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    event WithdrawAll(
        address indexed user, 
        uint256 indexed pid, 
        uint256 amount, 
        uint256 earnedToken0Amt, 
        uint256 earnedToken1Amt
    );

    event Claim(
        address indexed user, 
        uint256 indexed pid, 
        uint256 earnedToken0Amt, 
        uint256 earnedToken1Amt
    );

    event ClaimBNB(
        address indexed user,
        uint256 earnedAmt
    );

    function initialize(
        address _pctAddress
    ) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        pctAddress = _pctAddress;
        pctPairAddress = IPineconeToken(_pctAddress).pctPair();
        PCTPerBlock = 0;
        startBlock = 0;
        totalPCTAllocPoint = 0; 
        pctPerProfitBNB = 4000e18;
        devAddress = 0xc32Eb3766986f5E1E0b7F13b0Fc8eB2613d34720;
        teamRewardsAddress = 0x2F568Ddea18582C3A36BD21514226eD203eF606a;
        calcDuration = 5 days;
        claimCoolDown = 5 days;
    }

    receive() external payable {}
    
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    modifier onlyDev {
        require(devAddress == msg.sender, "caller is not the dev");
        _;
    }

    modifier onlyEOAOrAuthContract {
        if (whiteListContract[msg.sender] == false) {
            require(!isContract(msg.sender), "contract not allowed");
            require(msg.sender == tx.origin, "proxy contract not allowed");
        }
        _;
    }

    // set minter
    function setMinter(
        address _minter,
        bool _canMint
    ) public onlyOwner {

        if (_canMint) {
            minters[_minter] = _canMint;
        } else {
            delete minters[_minter];
        }
    }

    function isMinter(address account) public view returns (bool) {
        if (IPineconeToken(pctAddress).isMinter(address(this)) == false) {
            return false;
        }
        return minters[account];
    }

    modifier onlyMinter {
        require(isMinter(msg.sender) == true, "caller is not the minter");
        _;
    }

    function setAuthContract(address _contract, bool _auth) public onlyDev {
        whiteListContract[_contract] = _auth;
    }

    function setClaimCoolDown(uint256 _duration) public onlyDev {
        claimCoolDown = _duration;
    }

    function setCalDuration(uint256 _duration) public onlyOwner {
        require(_duration > SEC_PER_DAY, "duration less than 1 days");
        calcDuration = _duration;
    }

    function dailyEarnedAmount(uint256 _pid) public view returns(uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.allocPCTPoint == 0 || totalPCTAllocPoint == 0) {
            return 0;
        } else {
            uint256 earned0 = pctDailyReward().mul(pool.allocPCTPoint).div(totalPCTAllocPoint);
            uint256 earned1 = PCTPerBlock.mul(pool.allocPCTPoint).div(totalPCTAllocPoint).mul(28800);
            return earned0 + earned1;
        }
    }

    function poolInfoOf(uint256 _pid) public view returns(address want, address strat) {
        PoolInfo storage pool = poolInfo[_pid];
        want = address(pool.want);
        strat = pool.strat;
    }

    function userInfoOfPool(uint256 _pid, address _user) external view 
        returns(
            uint256 depositedAt, 
            uint256 depositAmt,
            uint256 balanceValue,
            uint256 earned0Amt,
            uint256 earned1Amt,
            uint256 withdrawbaleAmt
        )
    {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.strat == address(0)) {
            return (0,0,0,0,0,0);
        }

        uint256 pctAmt = pendingPCT(_pid, _user);    
        (depositedAt, depositAmt, balanceValue, earned0Amt, earned1Amt, withdrawbaleAmt) = IPineconeStrategy(pool.strat).userInfoOf(_user, pctAmt);
        if (_pid == pctStakingPid && pctStakingPid > 0) {
            earned0Amt = pendingBNB2(_user);
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPCTPoint,
        address _want,
        bool _withUpdate,
        address _strat
    ) public onlyOwner returns (uint256)
    {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number;
        totalPCTAllocPoint = totalPCTAllocPoint.add(_allocPCTPoint);

        poolInfo.push(
            PoolInfo({
                want: IERC20(_want),
                allocPCTPoint: _allocPCTPoint,
                lastRewardBlock: lastRewardBlock,
                accPCTPerShare: 0,
                strat: _strat
            })
        );
        return poolInfo.length - 1;
    }

    // Update the given pool's PCT allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPCTPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalPCTAllocPoint = totalPCTAllocPoint.sub(poolInfo[_pid].allocPCTPoint).add(_allocPCTPoint);
        poolInfo[_pid].allocPCTPoint = _allocPCTPoint;
    }

    // set pctPerProfitBNB
    function setPctPerProfitBNB(uint256 _pctPerProfitBNB) public onlyOwner {
        pctPerProfitBNB = _pctPerProfitBNB;
    }

    function amountPctToMint(uint256 _bnbProfit) public view returns (uint256) {
        return _bnbProfit.mul(pctPerProfitBNB).div(1e18);
    }

    function setDevAddress(address _addr) external {
        require(devAddress == msg.sender, "no auth");
        devAddress = _addr;
    }

    function setTeamRewardsAddress(address _addr) external {
        require(teamRewardsAddress == msg.sender, "no auth");
        teamRewardsAddress = _addr;
    }

    function setPctPerBlock(uint256 _PCTPerBlock, uint256 _startBlock) public onlyOwner {
        if (_startBlock == 0) {
            _startBlock = block.number;
        }
        PCTPerBlock = _PCTPerBlock;
        startBlock = _startBlock;
    }

    function setCakeRewardsPid(
        uint256 _cakeRewardsPid
    ) public onlyOwner {
        cakeRewardsStakingPid = _cakeRewardsPid;
    }

    function setCakeRewardsNewPid(
        uint256 _cakeRewardPid
    ) public onlyDev {
        cakeRewardsStakingNewPid = _cakeRewardPid;
    }

    function setPCTStakingPid(uint256 _pid) public onlyDev {
        pctStakingPid = _pid;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        if (PCTPerBlock == 0) {
            return 0;
        }

        if (IPineconeToken(pctAddress).mintAvailable() == false) {
            return 0;
        }

        if (_from < startBlock) {
            _from = startBlock;
        }

        if (_to < startBlock) {
            _to = startBlock;
        }

        if (_to < _from) {
            _to = _from;
        }

        return _to.sub(_from);
    }

    function pendingPCT(uint256 _pid, address _user)
        public 
        view
        returns (uint256) 
    {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.allocPCTPoint == 0) {
            return 0;
        }

        UserInfo storage user = userInfo[_pid][_user];
        uint256 accPCTPerShare = pool.accPCTPerShare;
        uint256 sharesTotal = IPineconeStrategy(pool.strat).sharesTotal();
        if (block.number > pool.lastRewardBlock && sharesTotal != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 PCTReward = multiplier.mul(PCTPerBlock).mul(pool.allocPCTPoint).div(totalPCTAllocPoint);
            accPCTPerShare = accPCTPerShare.add(PCTReward.mul(1e12).div(sharesTotal));
        }

        uint256 shares = user.shares;
        uint256 pending = user.pending.add(shares.mul(accPCTPerShare).div(1e12).sub(user.rewardPaid));

        return pending;
    }

    function pendingBNB(address _user) public view returns(
        uint256 pending, 
        uint256 lastRewardTime,
        uint256 claimed
    ) {
        UserRewardBNB storage user = userRewardBNB[_user];
        uint256 accPerShare = cakeTokenReward.accPerShare;
        uint256 shares = user.shares;
        pending = user.pending.add(shares.mul(accPerShare).div(1e12).sub(user.rewardPaid));
        PoolInfo storage cakePool = poolInfo[cakeRewardsStakingPid];
        pending = IPineconeStrategy(cakePool.strat).pendingBNB(pending, _user);
        lastRewardTime = user.lastRewardTime;
        claimed = user.claimed;
    }

    function pendingBNB2(address _user) public view returns(uint256) {
        PoolInfo storage pool = poolInfo[pctStakingPid];
        (uint256 bnbAmt, ) = IPineconeStrategy(pool.strat).pendingRewards(_user);
        PoolInfo storage cakePool = poolInfo[cakeRewardsStakingNewPid];
        return IPineconeStrategy(cakePool.strat).pendingBNB(bnbAmt, _user);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public 
    {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public 
    {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        if (pool.allocPCTPoint == 0 || PCTPerBlock == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 sharesTotal = IPineconeStrategy(pool.strat).sharesTotal();
        if (sharesTotal == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        if (multiplier <= 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 PCTReward = multiplier.mul(PCTPerBlock).mul(pool.allocPCTPoint).div(totalPCTAllocPoint);
        
        //optimize gas fee
        if (optimizeStartBlock == 0) {
            optimizeStartBlock = block.number;
            balanceOfPct = IERC20(pctAddress).balanceOf(address(this));
        }
        //_mint(address(this), PCTReward); 

        _mintForTeam(PCTReward);

        pool.accPCTPerShare = pool.accPCTPerShare.add(PCTReward.mul(1e12).div(sharesTotal));
        pool.lastRewardBlock = block.number;
    }

    function _mint(address _to, uint256 _amount) private {
        if (IPineconeToken(pctAddress).mintAvailable() == false) {
            return;
        }

        IPineconeToken(pctAddress).mint(_to, _amount);
    }

    function deposit(uint256 _pid, uint256 _wantAmt) public payable nonReentrant onlyEOAOrAuthContract {
        require(_wantAmt > 0, "_wantAmt <= 0");
        require(_pid != cakeRewardsStakingPid, "no auth");
        if (cakeRewardsStakingNewPid > 0) {
            require(_pid != cakeRewardsStakingNewPid, "no auth");
        }

        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        if (address(pool.want) == WBNB) {
            require(_wantAmt == msg.value, "_wantAmt != msg.value");
            IWETH(WBNB).deposit{value: msg.value}();
        } else {
            require(_wantAmt <= IERC20(pool.want).balanceOf(msg.sender), "invalid wantAmt");
            pool.want.safeTransferFrom(
                address(msg.sender),
                address(this),
                _wantAmt
            );
        } 
        pool.want.safeIncreaseAllowance(pool.strat, _wantAmt);
        uint256 sharesAdded = IPineconeStrategy(pool.strat).deposit(_wantAmt, msg.sender);
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 pending = user.shares.mul(pool.accPCTPerShare).div(1e12).sub(user.rewardPaid);
        user.pending = user.pending.add(pending);
        user.shares = user.shares.add(sharesAdded);
        user.rewardPaid = user.shares.mul(pool.accPCTPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _wantAmt);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _wantAmt) public nonReentrant onlyEOAOrAuthContract {
        require(_wantAmt > 0, "_wantAmt <= 0");
        require(_pid != cakeRewardsStakingPid, "no auth");
        if (cakeRewardsStakingNewPid > 0) {
            require(_pid != cakeRewardsStakingNewPid, "no auth");
        }

        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        // Withdraw want tokens
        (uint256 wantAmt, uint256 sharesRemoved) = IPineconeStrategy(pool.strat).withdraw(_wantAmt, msg.sender);
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 pending = user.shares.mul(pool.accPCTPerShare).div(1e12).sub(user.rewardPaid);
        user.pending = user.pending.add(pending);
        user.shares = user.shares.sub(sharesRemoved);
        user.rewardPaid = user.shares.mul(pool.accPCTPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, wantAmt);
    }

    function withdrawAll(uint256 _pid) public nonReentrant onlyEOAOrAuthContract {
        require(_pid != cakeRewardsStakingPid, "no auth");
        if (cakeRewardsStakingNewPid > 0) {
            require(_pid != cakeRewardsStakingNewPid, "no auth");
        }

        updatePool(_pid);
        (uint256 amount, uint256 reward, uint256 rewardPct) = IPineconeStrategy(poolInfo[_pid].strat).withdrawAll(msg.sender);
        uint256 pct = _claimPendingPCT(_pid, msg.sender);
        pct = pct.add(rewardPct);
        if (_pid == pctStakingPid && pctStakingPid > 0) {
            if (reward > 0) {
                PoolInfo storage cakePool = poolInfo[cakeRewardsStakingNewPid];
                reward = IPineconeStrategy(cakePool.strat).claimBNB(reward, msg.sender);
            }
        }
        UserInfo storage user = userInfo[_pid][msg.sender];
        user.shares = 0;
        user.pending = 0;
        user.rewardPaid = 0;
        emit WithdrawAll(msg.sender, _pid, amount, reward, pct);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant onlyEOAOrAuthContract {
        require(_pid != cakeRewardsStakingPid, "no auth");
        if (cakeRewardsStakingNewPid > 0) {
            require(_pid != cakeRewardsStakingNewPid, "no auth");
        }
        (uint256 amount,,) = IPineconeStrategy(poolInfo[_pid].strat).withdrawAll(msg.sender);
        UserInfo storage user = userInfo[_pid][msg.sender];
        user.shares = 0;
        user.pending = 0;
        user.rewardPaid = 0;
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function claim(uint256 _pid) public nonReentrant onlyEOAOrAuthContract {
        require(_pid != cakeRewardsStakingPid, "no auth");
        if (cakeRewardsStakingNewPid > 0) {
            require(_pid != cakeRewardsStakingNewPid, "no auth");
        }
        _claim(_pid);
    }

    function _claim(uint256 _pid) private {
        updatePool(_pid);
        (uint256 reward, uint256 rewardPct) = IPineconeStrategy(poolInfo[_pid].strat).claim(msg.sender);
        uint256 pct = _claimPendingPCT(_pid, msg.sender);
        pct = pct.add(rewardPct);
        emit Claim(msg.sender, _pid, reward, pct);
    }

    function _claimPendingPCT(uint256 _pid, address _user) private returns(uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.allocPCTPoint == 0) {
            return 0;
        }

        UserInfo storage user = userInfo[_pid][_user];
        uint256 accPCTPerShare = pool.accPCTPerShare;
        uint256 pending = user.shares.mul(accPCTPerShare).div(1e12).sub(user.rewardPaid);
        uint256 amount = user.pending.add(pending);
        user.pending = 0;
        user.rewardPaid = user.shares.mul(accPCTPerShare).div(1e12);
        _safePCTTransfer(_user, amount);
        return amount;
    }

    function claimBNB() public nonReentrant onlyEOAOrAuthContract {
        _claimBNB(msg.sender, msg.sender);
    }

    function _claimBNB(address _user, address _to) private{
        UserRewardBNB storage user = userRewardBNB[_user];
        require(user.lastRewardTime + claimCoolDown <= block.timestamp, "cool down!");
        uint256 accPerShare = cakeTokenReward.accPerShare;
        uint256 pending = user.shares.mul(accPerShare).div(1e12).sub(user.rewardPaid);
        uint256 amount = user.pending.add(pending);
        require(amount > 0, "no shares!");
        user.pending = 0;
        user.rewardPaid = user.shares.mul(accPerShare).div(1e12);

        PoolInfo storage cakePool = poolInfo[cakeRewardsStakingPid];
        amount = IPineconeStrategy(cakePool.strat).claimBNB(amount, _to);
        user.claimed = user.claimed.add(amount);
        user.lastRewardTime = block.timestamp;
        emit ClaimBNB(_to, amount);
    }

    function claimPCTPairDustBNB(address _to) public onlyDev {
        _claimBNB(pctPairAddress, _to);
    }

    function claimPCTDustBNB(address _to) public onlyDev {
        _claimBNB(pctAddress, _to);
    }

    function claimDeadDustBNB(address _to) public onlyDev {
        _claimBNB(DEAD, _to);
    }

    function claimBNB2() public nonReentrant onlyEOAOrAuthContract {
        _claimBNB2(msg.sender);
    }

    function _claimBNB2(address _user) private returns(uint256) {
        PoolInfo storage pool = poolInfo[pctStakingPid];
        uint256 bnbAmt = IVaultPCT(pool.strat).claimBNB(_user);
        if (bnbAmt > 0) {
            PoolInfo storage cakePool = poolInfo[cakeRewardsStakingNewPid];
            bnbAmt = IPineconeStrategy(cakePool.strat).claimBNB(bnbAmt, _user);
            emit ClaimBNB(_user, bnbAmt);
        }

        return bnbAmt;
    }

    // Safe PCT transfer function, just in case if rounding error causes pool to not have enough
    function _safePCTTransfer(address _to, uint256 _PCTAmt) private {
        if (_PCTAmt == 0) return;

        if (optimizeStartBlock > 0) {
            if (balanceOfPct > 0) {
                if (_PCTAmt > balanceOfPct) {
                    IERC20(pctAddress).safeTransfer(_to, balanceOfPct);
                    uint256 mintAmt = _PCTAmt - balanceOfPct;
                    balanceOfPct = 0;
                    _mint(_to, mintAmt);
                } else {
                    balanceOfPct = balanceOfPct - _PCTAmt;
                    IERC20(pctAddress).safeTransfer(_to, _PCTAmt);
                }
            } else {
                _mint(_to, _PCTAmt);
            }
        } else {
            uint256 PCTBal = IERC20(pctAddress).balanceOf(address(this));
            if (PCTBal == 0) return;
        
            if (_PCTAmt > PCTBal) {
                _PCTAmt = PCTBal;
            }
            IERC20(pctAddress).safeTransfer(_to, _PCTAmt);
        }
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount)
        public
        onlyOwner
    {
        require(_token != pctAddress, "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    function mintForProfit(address _to, uint256 _Profit, bool updatePCTRewards) public onlyMinter returns(uint256) {
        uint256 mintPct = amountPctToMint(_Profit);
        if (mintPct == 0) return 0;
        _mint(_to, mintPct);
        _mintForTeam(mintPct);
        if (_to == address(this) && updatePCTRewards) {
            _updatePCTRewards(mintPct);
        }
        return mintPct;
    }

    function _mintForTeam(uint256 _amount) private {
        uint256 pctForTeam = _amount.mul(teamPCTReward).div(1000);
        //optimize gas fee
        //_mint(teamRewardsAddress, pctForTeam);
        UserInfo storage user = userInfo[pctStakingPid][teamRewardsAddress];
        user.pending = user.pending.add(pctForTeam);
    }

    function stakeRewardsTo(address _to, uint256 _amount) public onlyMinter {
        _stakeRewardsTo(_to, _amount);
    }

    function _stakeRewardsTo(address _to, uint256 _amount) private {
        if (_amount == 0) return;

        if (_to == address(0)) {
            _to = teamRewardsAddress;
        }

        uint256 _pid = cakeRewardsStakingNewPid > 0 ? cakeRewardsStakingNewPid : cakeRewardsStakingPid;
        PoolInfo storage pool = poolInfo[_pid];
        pool.want.safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );

        pool.want.safeIncreaseAllowance(pool.strat, _amount);
        IPineconeStrategy(pool.strat).deposit(_amount, _to);
        if (cakeRewardsStakingNewPid > 0) {
            _upateCakeRewards2(_amount);
        } else {
            _upateCakeRewards(_amount);
        }
    }

    function pctDailyReward() public view returns(uint256) {
        if (pctTokenReward.startTime == 0) {
            return 0;
        }

        uint256 cap = block.timestamp.sub(pctTokenReward.startTime);
        uint256 rewardAmt = 0;
        if (cap <= SEC_PER_DAY) {
            rewardAmt = pctTokenReward.accAmount;
        } else {
            rewardAmt = pctTokenReward.accAmount.mul(SEC_PER_DAY).div(cap);
        }
        return rewardAmt;
    }

    function cakeDailyReward() public view returns(uint256) {
        if (cakeTokenReward.startTime == 0) {
            return 0;
        }

        uint256 cap = block.timestamp.sub(cakeTokenReward.startTime);
        if (cap <= SEC_PER_DAY) {
            return cakeTokenReward.accAmount;
        } else {
            return cakeTokenReward.accAmount.mul(SEC_PER_DAY).div(cap);
        }
    }

    function _updatePCTRewards(uint256 _amount) private {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            _updatePCTRewards(_amount, pid);
        }

        if (pctTokenReward.startTime == 0) {
            pctTokenReward.startTime = block.timestamp;
        } else {
            uint256 cap = block.timestamp.sub(pctTokenReward.startTime);
            if (cap >= calcDuration) {
                pctTokenReward.startTime = block.timestamp;
                pctTokenReward.accAmount = 0;
            }
        }
        pctTokenReward.accAmount = pctTokenReward.accAmount.add(_amount);
        pctTokenReward.totalAmount = pctTokenReward.totalAmount.add(_amount);
    } 

    function _updatePCTRewards(uint256 _amount, uint256 _pid) private {
        if (totalPCTAllocPoint == 0) {
            return;
        }

        PoolInfo storage pool = poolInfo[_pid];
        if (pool.allocPCTPoint == 0) {
            return;
        }

        uint256 sharesTotal = IPineconeStrategy(pool.strat).sharesTotal();
        if (sharesTotal == 0) {
            return;
        }

        uint256 PCTReward = _amount.mul(pool.allocPCTPoint).div(totalPCTAllocPoint);
        pool.accPCTPerShare = pool.accPCTPerShare.add(PCTReward.mul(1e12).div(sharesTotal));
    }

    function _upateCakeRewards(uint256 _amount) private {
        if (cakeTokenReward.startTime == 0) {
            cakeTokenReward.startTime = block.timestamp;
        } else {
            uint256 cap = block.timestamp.sub(cakeTokenReward.startTime);
            if (cap >= calcDuration) {
                cakeTokenReward.startTime = block.timestamp;
                cakeTokenReward.accAmount = 0;
            }
        }
        cakeTokenReward.accAmount = cakeTokenReward.accAmount.add(_amount);
        cakeTokenReward.totalAmount = cakeTokenReward.totalAmount.add(_amount);

        uint256 totalSupply = IERC20(pctAddress).totalSupply();
        cakeTokenReward.accPerShare = cakeTokenReward.accPerShare.add(_amount.mul(1e12).div(totalSupply));
    }

    function _upateCakeRewards2(uint256 _amount) private {
        uint256 _pid = pctStakingPid;
        PoolInfo storage pool = poolInfo[_pid];
        IVaultPCT(pool.strat).updateCakeRewards(_amount);
    }

    function mintForPresale(address _to, uint256 _amount) public onlyMinter returns(uint256) {
        require(_amount > 0, "_amount == 0");

        uint256 mintPct = amountPctToMint(_amount);
        if (mintPct == 0) return 0;
        _mint(_to, mintPct);

        uint256 pctForTeam = mintPct.mul(teamPCTReward).div(1000);
        _mint(teamRewardsAddress, pctForTeam);

        return mintPct;
    }

    function stakeForPresale(address _to, uint256 _amount) public onlyMinter {
        _stakeRewardsTo(_to, _amount);
    }

    function transferCallee(address from, address to) override public {
        require(msg.sender == pctAddress, "not PCT!");
        _adjustCakeRewardTo(from);
        _adjustCakeRewardTo(to);
    }

    function _adjustCakeRewardTo(address _user) private {
        if (_user == address(0) || 
            _user == address(this) ||
            _user == address(0x000000000000000000000000000000000000dEaD)
           )
            return;
            
        if (isContract(_user)) return;

        if (cakeTokenReward.accPerShare == 0) return;

        uint256 shares = IERC20(pctAddress).balanceOf(_user);
        UserRewardBNB storage user = userRewardBNB[_user];
        if (user.lastRewardTime == 0) {
            user.lastRewardTime = block.timestamp;
        }
        uint256 pending = user.shares.mul(cakeTokenReward.accPerShare).div(1e12).sub(user.rewardPaid);
        user.pending = user.pending.add(pending);
        user.shares = shares;
        user.rewardPaid = user.shares.mul(cakeTokenReward.accPerShare).div(1e12);
    }

    function isContract(address account) public view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    function migrateCakeRewardsPool(uint256 fromId, uint toId) public onlyDev {
        PoolInfo storage fromPool = poolInfo[fromId];
        PoolInfo storage toPool = poolInfo[toId];
        (uint256 wantAmt,,) = IPineconeStrategy(fromPool.strat).withdrawAll(address(this));
        _safeApprove(address(toPool.want), toPool.strat);
        IPineconeStrategy(toPool.strat).deposit(wantAmt, address(this));
        cakeRewardsStakingNewPid = toId;
    }

    function _safeApprove(address token, address spender) internal {
        if (token != address(0) && IERC20(token).allowance(address(this), spender) == 0) {
            IERC20(token).safeApprove(spender, uint256(~0));
        }
    }
}