// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "../interfaces/IMasterChef.sol";

import "../libraries/SafeMath.sol";
import "../libraries/SafeERC20.sol";
import "../interfaces/IPineconeConfig.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

//Investment strategy
contract VaultCake is OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct UserAssetInfo
    {
        uint256 depositAmt;
        uint256 depositedAt;
        uint256 shares;
    }

    uint256 public sharesTotal;
    mapping (address=>UserAssetInfo) users;

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant stratAddress = 0x73feaa1eE314F8c655E354234017bE2193C9E24E; 
    uint256 public constant pid = 0;
    IPineconeConfig public constant config = IPineconeConfig(0x03fE99931FB3B57F787A2e87bf93cD1a4CeFE1Cb);

    uint256 internal constant dust = 1000;
    uint256 internal constant UNIT = 1e18;

    address public stakingToken;
    address public devAddress;
    address public govAddress;

    function initialize (
    ) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        stakingToken = CAKE;
        devAddress = msg.sender;
        govAddress = 0x44c81c726a26f060AB683774404c47bc70De7C26;
        sharesTotal = 0;

        _safeApprove(CAKE, stratAddress);
    }

    modifier onlyGov() {
        require(msg.sender == govAddress, "! not gov");
        _;
    }

    modifier onlyDev() {
        require(msg.sender == devAddress, "! not dev");
        _;
    }

    /* ========== onlyGov ========== */
    function setGovAddress(address _govAddress) onlyGov public {
        govAddress = _govAddress;
    }

    /* ========== onlyDev ========== */
    function pause() onlyDev external {
        _pause();
    }

    function unpause() onlyDev external {
        _unpause();
    }

    function setDevAddress(address _devAddress) onlyDev public {
        devAddress = _devAddress;
    }


    /* ========== public view ========== */
    function sharesOf(address _user) public view returns(uint256) {
        return users[_user].shares;
    }

    function withdrawableBalanceOf(address _user) public virtual view returns(uint256) {
        return users[_user].depositAmt;
    }

    function userOf(address _user) public view returns(
        uint256 _depositAmt, 
        uint256 _depositedAt, 
        uint256 _shares
    ) {
        UserAssetInfo storage user = users[_user];
        _depositAmt = user.depositAmt;
        _depositedAt = user.depositedAt;
        _shares = user.shares;
    }

    function farmPid() public pure returns(uint256) {
        return pid;
    }

    function stakeType() public pure returns(StakeType) {
        return StakeType.CakeOnly;
    }

    function earnedAddress() public view returns(address) {
        return stakingToken;
    }

    function userInfoOf(address _user) public view 
        returns(
            uint256 depositedAt, 
            uint256 depositAmt,
            uint256 balanceValue,
            uint256 earnedAmt,
            uint256 withdrawbaleAmt
        ) 
    {
        UserAssetInfo storage user = users[_user];
        depositedAt = user.depositedAt;
        depositAmt = user.depositAmt;
        earnedAmt = pendingRewards(_user);
        withdrawbaleAmt = withdrawableBalanceOf(_user);
        uint256 wantAmt = depositAmt.add(earnedAmt);

        IPineconeConfig _config = config;
        balanceValue = wantAmt.mul(_config.priceOfToken(stakingToken)).div(UNIT);
    }

    function tvl() public view returns(uint256 priceInUsd) {
        (uint256 wantAmt, uint256 pendingAmt) = balance();
        wantAmt = wantAmt.add(pendingAmt);
        IPineconeConfig _config = config;
        uint256 wantTvl = wantAmt.mul(_config.priceOfToken(stakingToken)).div(UNIT);
        return wantTvl;
    }

    function balance() public view returns(uint256 wantAmt, uint256 pendingAmt) {
        wantAmt = stakingAmount();
        pendingAmt = pendingAmount();
    }

    function balanceOf(address _user) public view returns(uint256 wantAmt, uint256 pendingAmt) {
        if (sharesTotal == 0) {
            return (0,0);
        }

        uint256 shares = sharesOf(_user);
        (wantAmt, pendingAmt) = balance();
        wantAmt = wantAmt.mul(shares).div(sharesTotal);
        pendingAmt = pendingAmt.mul(shares).div(sharesTotal);
    }

    function earnedOf(address _user) public view returns(uint256) {
        UserAssetInfo storage user = users[_user];
        (uint256 wantAmt, uint256 pendingAmt) = balanceOf(_user);
        if (wantAmt > user.depositAmt) {
            wantAmt = wantAmt.sub(user.depositAmt);
        } else {
            wantAmt = 0;
        }
        wantAmt = wantAmt.add(pendingAmt);
        return wantAmt;
    }

    function pendingRewardsValue() public view returns(uint256 priceInUsd) {
        uint256 pendingAmt = pendingAmount();
        return pendingAmt.mul(config.priceOfToken(stakingToken)).div(UNIT);
    }

    function pendingRewards(address _user) public view returns(uint256)
    {
        if (sharesTotal == 0) {
            return 0;
        }

        return earnedOf(_user);
    }

    function stakingAmount() public view returns(uint256) {
        (uint amount,) = IMasterChef(stratAddress).userInfo(pid, address(this));
        return amount;
    }

    function pendingAmount() public view returns(uint256) {
        return IMasterChef(stratAddress).pendingCake(pid, address(this));
    }

    /* ========== public write ========== */
    function deposit(uint256 _wantAmt, address _user)
        public
        onlyOwner
        whenNotPaused
        returns(uint256)
    {
         _earn();
        IERC20(stakingToken).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );

        UserAssetInfo storage user = users[_user];
        user.depositedAt = block.timestamp;
        user.depositAmt = user.depositAmt.add(_wantAmt);
        uint256 sharesAdded = _wantAmt;
        (uint256 wantTotal,) = balance();
        if (wantTotal > 0 && sharesTotal > 0) {
            sharesAdded = sharesAdded
                .mul(sharesTotal)
                .div(wantTotal);
        }
        
        sharesTotal = sharesTotal.add(sharesAdded);
        user.shares = user.shares.add(sharesAdded);

        _farmStakingToken();
        return sharesAdded;
    }

    function earn() public whenNotPaused onlyGov
    {
        _earn();
    }

    function withdrawAll(address _user)
        public 
        onlyOwner
        nonReentrant
        returns (uint256, uint256)
    {
        require(sharesTotal > 0, "sharesTotal is 0");

        UserAssetInfo storage user = users[_user];
        require(user.depositAmt > 0 || user.shares > 0, "depositAmt <= 0 && shares <= 0");

        uint256 wantAmt = user.depositAmt;
        uint256 earnedWantAmt = earnedOf(_user);

        _withdrawStakingToken(wantAmt.add(earnedWantAmt));
        wantAmt = wantAmt.add(earnedWantAmt);

        {
            uint256 balanceAmt = IERC20(stakingToken).balanceOf(address(this));
            if (wantAmt > balanceAmt) {
                wantAmt = balanceAmt;
            }
            _safeTransfer(stakingToken, _user, wantAmt);
        }

        if (user.shares > sharesTotal) {
            sharesTotal = 0;
        } else {
            sharesTotal = sharesTotal.sub(user.shares);
        }
        user.shares = 0;
        user.depositAmt = 0;
        user.depositedAt = 0;
        _earn();
        return (wantAmt, earnedWantAmt);
    }

    function withdraw(uint256 _wantAmt, address _user)
        public 
        onlyOwner
        nonReentrant
        returns (uint256, uint256)
    {
        require(_wantAmt > 0, "_wantAmt <= 0");
        require(sharesTotal > 0, "sharesTotal is 0");

        UserAssetInfo storage user = users[_user];
        require(user.shares > 0, "user.shares is 0");
        require(user.depositAmt >= _wantAmt, "depositAmt < _wantAmt");

        (uint256 wantAmt, uint256 sharesRemoved) = _withdraw(_wantAmt, _user);
        sharesTotal = sharesTotal.sub(sharesRemoved);
        user.shares = user.shares.sub(sharesRemoved);
        _earn();
        return (wantAmt, sharesRemoved);
    }

    function claim(address _user) 
        public 
        onlyOwner
        nonReentrant
        returns(uint256)
    {
        uint256 rewardAmt = _claim(_user);
        _earn();
        return rewardAmt;
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount)
        public
        onlyGov
    {
        require(_token != stakingToken, "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    /* ========== private method ========== */
    function _earn() private {
        _claimStakingToken();
        _farmStakingToken();
    }

    function _withdraw(uint256 _wantAmt, address _user) private returns(uint256, uint256) {
        UserAssetInfo storage user = users[_user];
        (uint256 wantTotal,) = balance();
        if (_wantAmt > user.depositAmt) {
            _wantAmt = user.depositAmt;
        }
        user.depositAmt = user.depositAmt.sub(_wantAmt);
        uint256 sharesRemoved = _wantAmt.mul(sharesTotal).div(wantTotal);
        if (sharesRemoved > user.shares) {
            sharesRemoved = user.shares;
        }
        
        _withdrawStakingToken(_wantAmt);
        uint256 wantAmt = IERC20(stakingToken).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        _safeTransfer(stakingToken, _user, _wantAmt);

        return (_wantAmt, sharesRemoved);
    }

    function _claim(address _user) private returns(uint256) {
        uint256 wantAmt = earnedOf(_user);
        if (wantAmt == 0) {
            return 0;
        }
        UserAssetInfo storage user = users[_user];
        (uint256 wantTotal,) = balance();
        uint256 sharesRemoved = wantAmt.mul(sharesTotal).div(wantTotal);
        if (sharesRemoved > user.shares) {
            sharesRemoved = user.shares;
        }
        sharesTotal = sharesTotal.sub(sharesRemoved);
        user.shares = user.shares.sub(sharesRemoved);
        //clean dust shares
        if (user.shares > 0 && user.shares < dust) {
            sharesTotal = sharesTotal.sub(user.shares);
            user.shares = 0;
        } 

        _withdrawStakingToken(wantAmt);

        uint256 balanceAmt = IERC20(stakingToken).balanceOf(address(this));
        if (wantAmt > balanceAmt) {
            wantAmt = balanceAmt;
        }

        _safeTransfer(stakingToken, _user, wantAmt);
        return wantAmt;
    }

    function _safeApprove(address token, address spender) internal {
        if (token != address(0) && IERC20(token).allowance(address(this), spender) == 0) {
            IERC20(token).safeApprove(spender, uint256(~0));
        }
    }

    function _safeTransfer(address _token, address _to, uint256 _amount) internal {
        if (_amount == 0) return;
        IERC20(_token).safeTransfer(_to, _amount);
    }

    function _withdrawStakingToken(uint256 _amount) internal {
        if (_amount == 0 || IERC20(stakingToken).balanceOf(address(this)) >= _amount) return;
        uint256 _amt = stakingAmount();
        if (_amount > _amt) {
            _amount = _amt;
        }
        IMasterChef(stratAddress).leaveStaking(_amount);
    }

    function _farmStakingToken() internal {
        uint256 amount = IERC20(stakingToken).balanceOf(address(this));
        if (amount > 0) {
            IMasterChef(stratAddress).enterStaking(amount);
        }
    }

    function _claimStakingToken() internal {
        IMasterChef(stratAddress).leaveStaking(0);
    }
}