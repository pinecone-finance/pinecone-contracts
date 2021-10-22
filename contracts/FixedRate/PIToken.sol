// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../interfaces/IPITokenController.sol";
import "./TokenBase.sol";
import "../interfaces/IDashboard.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract PIToken is TokenBase, ERC20PausableUpgradeable, ReentrancyGuardUpgradeable { 

    address public underlying;
    address public controller;
    address public feeRewardsAccount;
    uint256 public fixedDApr;

    uint256 public minDepositAmt;
    uint256 public maxTotalDepositAmt;

    uint256 public totalDepositAmt;

    bool public enableTransfer;

    struct UserInfo {
        bool auth;
        address referral;
        uint256 depositedAt;
        uint256 depositAmt;
        uint256 redeemedAt;
        uint256 redeemAmt;
        uint256 referralRewards;
    }
    mapping (address=>UserInfo) public userInfo;
    uint256 public refBonusBP;

    bool public needAuth;

    struct InterestRate {
        uint256 startTime;
        uint256 rate;
        uint256 index;
    }
    InterestRate public interestRate;

    uint256 public constant SEC_OF_DAY = 1 days;
    uint256 constant expScale = 1e18;

    IPriceCalculator public constant priceCalculator = IPriceCalculator(0xeCFAd58c39d0108Dc93a07FdBa79A0d0F1286D87);

    event Transfer2(address indexed from, address indexed to, uint256 value, uint256 fee);
    event Deposit(address indexed sender, uint256 underlyingAmount, uint256 piAmount);
    event Redeem(address indexed sender, uint256 piAmount, uint256 underlyingAmount, uint256 referralUnderlyingAmount, uint256 feePiAmount);
    event Withdraw(address indexed sender, uint256 underlyingAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    function initialize (
        string memory _name,
        string memory _symbol,
        address _underlying,
        address _controller
    ) external initializer {
        __ERC20Pausable_init();
        __ERC20_init_unchained(_name, _symbol);
        __ReentrancyGuard_init();
        __TokenBase_init();
        feeRewardsAccount = msg.sender;
        underlying = _underlying;
        controller = _controller;
        fixedDApr = 5*1e14; //0.05%, apy == 20%
        _safeApprove(_underlying, _controller);
        enableTransfer = false;
        needAuth = true;
        refBonusBP = 200; //20%
        userInfo[msg.sender].auth = true;
    }

    modifier onlyAuth() {
        require(isAuthAccount(msg.sender), "PIToken: no auth account");
        _;
    }

    function setController(address _controller) external onlyOwner {
        require(_controller != address(0), "PIToken: invalid address");
        controller = _controller;
        _safeApprove(underlying, _controller);
    }

    function setFeeRewardsAccount(address _account) external onlyOwner {
        require(_account != address(0), "PIToken: invalid address");
        feeRewardsAccount = _account;
    }

    function setFixedDApr(uint256 _dapr) external onlyOwner {
        require(_dapr >= 100000 && _dapr <= 1000000, "PIToken: invalid fixed dapr");
        fixedDApr = _dapr;
    }

    function setAuthAccount(address _authAccont, address _referral, bool _auth) public onlyOwner {
        require(_authAccont != address(0) && _authAccont != _referral, "PITokenController: invalid address");
        userInfo[_authAccont].auth = _auth;
        userInfo[_authAccont].referral = _referral;
    }

    function setNeedAuth(bool _needAuth) public onlyOwner {
        needAuth = _needAuth;
    }

    function isAuthAccount(address _account) public view returns(bool) {
        if (needAuth == false) {
            return true;
        }

        return userInfo[_account].auth;
    }

    function accountInfo(address _account) public view returns(
        bool auth, 
        uint256 balanceOfUnderlying,
        uint256 balanceOfPIToken,
        uint256 depositAmt, 
        uint256 depositedAt,
        uint256 redeemAmt,
        uint256 redeemedAt
    ) {
        UserInfo storage user = userInfo[_account];
        auth = isAuthAccount(_account);
        balanceOfUnderlying = IERC20(underlying).balanceOf(_account);
        balanceOfPIToken = balanceOf(_account);
        depositAmt = user.depositAmt;
        depositedAt = user.depositedAt;
        redeemAmt = user.redeemAmt;
        redeemedAt = user.redeemedAt;
    }

    function tokenInfo() public view returns(
        uint256 fixedDApr_,
        uint256 exchangeRate_, 
        uint256 minDepositAmt_, 
        uint256 maxTotalDepositAmt_,
        uint256 leftDepoistAmt_,
        uint256 totalDepositAmt_,
        uint256 tvl_
    ) {
        fixedDApr_ = fixedDApr;
        exchangeRate_ = exchangeRate();
        minDepositAmt_ = minDepositAmt;
        maxTotalDepositAmt_ = maxTotalDepositAmt;
        leftDepoistAmt_ = leftDepoistAmt();
        totalDepositAmt_ = totalDepositAmt;
        tvl_ = totalDepositAmt_.mul(priceCalculator.priceOfToken(underlying)).div(expScale);
    }

    function setDepositLimit(uint256 _minDepositAmt, uint256 _maxTotalDepositAmt) external onlyOwner {
        require(_minDepositAmt > 0, "PIToken: invalid minDepositAmt");
        require(_maxTotalDepositAmt > 0, "PIToken: invalid maxTotalDepositAmt");
        require(_minDepositAmt <= _maxTotalDepositAmt, "PIToken: minDepositAmt must be less than maxTotalDepositAmt");
        minDepositAmt = _minDepositAmt;
        maxTotalDepositAmt = _maxTotalDepositAmt;
    }

    function setEnableTransfer(bool _enableTransfer) external onlyOwner {
        enableTransfer = _enableTransfer;
    }

    function setRefBonusBP (uint256 _refBonusBP) public onlyOwner {
        require(_refBonusBP <= 300, "_refBonusBP > 300");
        refBonusBP = _refBonusBP;
    }

    function deposit(uint256 _amount) external whenNotPaused nonReentrant onlyAuth {
        require(_amount > 0 && _amount <= IERC20(underlying).balanceOf(msg.sender), "PIToken: invalid amount");
        require(_amount >= minDepositAmt, "PIToken: amount less than minDepositAmt");
        require(_amount <= leftDepoistAmt(), "PIToken: insufficient remaining amount");
        IERC20(underlying).safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        IPITokenController(controller).deposit(_amount);

        accrueInterest();

        uint256 rate = exchangeRate();
        uint256 piAmount = _amount.mul(rate).div(expScale);
        _mint(msg.sender, piAmount);

        UserInfo storage user = userInfo[msg.sender];
        user.depositedAt = block.timestamp;
        user.depositAmt = user.depositAmt.add(_amount);
        totalDepositAmt = totalDepositAmt.add(_amount);
        emit Deposit(msg.sender, _amount, piAmount);
    }

    function redeem(uint256 _amount) external whenNotPaused nonReentrant onlyAuth {
        uint256 bal = balanceOf(msg.sender);
        require(_amount > 0 && _amount <= bal, "PIToken: invalid amount");

        UserInfo storage user = userInfo[msg.sender];
        require(user.redeemAmt == 0, "PIToken: user.redeemAmt > 0");

        accrueInterest();
        uint256 rate = exchangeRate();

        uint256 subDepositAmt = user.depositAmt.mul(_amount).div(bal);
        user.depositAmt = user.depositAmt.sub(subDepositAmt);
        totalDepositAmt = totalDepositAmt.sub(subDepositAmt);

        uint256 underlyingAmount = _amount.mul(expScale).div(rate);
        uint256 rewards = underlyingAmount.sub(subDepositAmt); //收益
        uint256 referralRewards = 0; //邀请奖励的数量
        if (user.referral != address(0)) {
            referralRewards = rewards.mul(refBonusBP).div(1000);
            user.referralRewards = user.referralRewards.add(referralRewards);
        }

        _burn(msg.sender, _amount);

        uint256 fee = IPITokenController(controller).calcTransferFee(address(this), msg.sender, address(0), _amount, user.depositedAt);
        if (fee > 0) {
            // 收取手续费
            _balances[feeRewardsAccount] = _balances[feeRewardsAccount].add(fee);
            _totalSupply = _totalSupply.add(fee);
            _amount = _amount.sub(fee);
        }
        
        underlyingAmount = _amount.mul(expScale).div(rate);
        IPITokenController(controller).redeem(underlyingAmount.add(referralRewards));

        user.redeemAmt = user.redeemAmt.add(underlyingAmount);
        user.redeemedAt = block.timestamp;
        emit Redeem(msg.sender, _amount, underlyingAmount, referralRewards, fee);
    }

    function withdraw() external whenNotPaused nonReentrant onlyAuth {
        UserInfo storage user = userInfo[msg.sender];
        require(user.redeemAmt > 0, "PIToken: invalid amount");
        require(block.timestamp >= user.redeemedAt + SEC_OF_DAY, "PIToken: redemption time not reached");

        IPITokenController(controller).withdraw(msg.sender, user.redeemAmt);
        if (user.referral != address(0) && user.referralRewards > 0) {
            IPITokenController(controller).withdraw(user.referral, user.referralRewards); //发送邀请奖励给邀请人
        }
        
        user.redeemAmt = 0;
        user.redeemedAt = 0;
        user.referralRewards = 0;
        emit Withdraw(msg.sender, user.redeemAmt);
    }

    function leftDepoistAmt() public view returns(uint256) {
        if (totalDepositAmt >= maxTotalDepositAmt) {
            return 0;
        }

        return maxTotalDepositAmt.sub(totalDepositAmt);
    }

    function accrueInterest() public {
        if (interestRate.startTime == 0) {
            interestRate.startTime = block.timestamp;
            interestRate.rate = 0;
            interestRate.index = 0;
        } else {
            uint256 newIndex = block.timestamp.sub(interestRate.startTime).div(SEC_OF_DAY);
            uint256 index = interestRate.index;
            //复利公式 = (1+dapr)^n - 1
            if (newIndex > index) {
                uint256 cap = newIndex.sub(index);
                uint256 unit = expScale;
                uint256 mulRate = unit.add(fixedDApr);
                uint256 accRate = unit.add(interestRate.rate);
                for (uint256 i = 0; i < cap; ++i) {
                    accRate = accRate.mul(mulRate).div(unit);
                }
                interestRate.rate = accRate.sub(unit);
                interestRate.index = newIndex;
            }
        }
    }

    function exchangeRate() public view returns(uint256) {
        //兑换利率公式 = 1 / (1 + ((1+dapr)^n - 1))
        uint256 unit = expScale;
        return unit.mul(unit).div(unit + interestRate.rate);
    }

    function _transfer(address _sender, address _recipient, uint256 _amount) internal override {
        require(enableTransfer == true, "PIToken: disable transfer");
        require(_sender != address(0), "PIToken: transfer from the zero address");
        require(_recipient != address(0), "PIToken: transfer to the zero address");

        _beforeTokenTransfer(_sender, _recipient, _amount);

        _balances[_sender] = _balances[_sender].sub(_amount, "PIToken: transfer amount exceeds balance");

        uint256 fee = IPITokenController(controller).calcTransferFee(address(this), _sender, _recipient, _amount, userInfo[_sender].depositedAt);
        _balances[feeRewardsAccount] = _balances[feeRewardsAccount].add(fee);

        uint256 leftAmount = _amount.sub(fee);
        _balances[_recipient] = _balances[_recipient].add(leftAmount);
        emit Transfer2(_sender, _recipient, leftAmount, fee);
    }
}