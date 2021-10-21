// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../libraries/SafeMath.sol";
import "../interfaces/IPIToken.sol";
import "./TokenAuth.sol";
import "../interfaces/IDashboard.sol";

interface IEscrow {
    function transfer(address _token, address _to, uint256 _amount) external;
}

interface IVaultCake {
    function userInfoOf(address _user) external view returns(uint256 depositedAt, uint256 depositAmt, uint256 balanceValue, uint256 earnedAmt, uint256 withdrawbaleAmt);
    function tvl() external view returns(uint256 priceInUsd);
    function deposit(uint256 _wantAmt, address _user) external returns(uint256);
    function withdraw(uint256 _wantAmt, address _user) external returns(uint256);
    function withdrawAll(address _user) external returns(uint256, uint256);
    function claim(address _user) external returns(uint256);
}

contract PITokenController is TokenAuth {
    using SafeMath for uint256;

    address public constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    IPriceCalculator public constant priceCalculator = IPriceCalculator(0xeCFAd58c39d0108Dc93a07FdBa79A0d0F1286D87);

    uint256 public feeOf15Days;
    uint256 public feeOf30Days;
    uint256 public constant FEE_MAX = 1000;
    uint256 public constant FEE_UL = 50; //max fee 5%
    uint256 public constant SEC_OF_15DAYS = 15 days; 
    uint256 public constant SEC_OF_30DAYS = 30 days;

    mapping (address=>bool) public isExcludedFromFee;

    address public depositEscrow;
    address public withdrawEscrow;
    address public cakeEscrow;
    address public repayEscrow;

    address public binanceWallet;  //币安交易所充值地址
    address public ftxWallet;  //ftx交易所充值地址

    address public vaultCake;

    struct PITokenInfo {
        bool enable;
        uint256 depositAmt;
        uint256 depositedAt;
        uint256 redeemAmt;
        uint256 redeemedAt;
    }

    mapping (address=>PITokenInfo) public piTokens;

    uint8 public shortLeverage; 

    event WithdrawToCex(address underlyingToken, address indexed escrow, address indexed binanceWallet, uint256 binanceAmount, address indexed ftxWallet, uint256 ftxAmount);
    event DepositCake(address indexed user, uint256 amount);
    event WithdrawCake(address indexed from, address indexed to, uint256 amount);
    event WithdrawAllCake(address indexed from, address indexed to, uint256 amount);
    event ClaimCake(address indexed from, address indexed to, uint256 amount);
    event Repay(address indexed underlyingToken, address indexed from, address indexed to, uint256 amount);

    function initialize(
    ) external initializer {
        __TokenAuth_init();
        feeOf15Days = 10; //1%
        feeOf30Days = 5;  //0.5%
        isExcludedFromFee[address(this)] = true;
        isExcludedFromFee[msg.sender] = true;
        shortLeverage = 2;
    }

    modifier onlyPIToken() {
        require(piTokens[msg.sender].enable == true, "PITokenController: not PIToken");
        _;
    }

    function setFees(uint256 _feeOf15Days, uint256 _feeOf30Days) public onlyOwner {
        require(_feeOf15Days <= FEE_UL, "PITokenController: invalid fee");
        require(_feeOf30Days <= FEE_UL, "PITokenController: invalid fee");

        feeOf15Days = _feeOf15Days;
        feeOf30Days = _feeOf30Days;
    }

    function excludeFromFee(address _account) public onlyOwner {
        require(_account != address(0), "PITokenController: invalid address");
        isExcludedFromFee[_account] = true;
    }
    
    function includeInFee(address _account) public onlyOwner {
        require(_account != address(0), "PITokenController: invalid address");
        isExcludedFromFee[_account] = false;
    }

    function setPIToken(address _piToken, bool _enable) public onlyOwner {
        require(_piToken != address(0), "PITokenController: invalid address");
        piTokens[_piToken].enable = _enable;
    }

    function setDepositEscrow(address _depositEscrow) public onlyOwner {
        require(_depositEscrow != address(0), "PITokenController: invalid address");
        depositEscrow = _depositEscrow;
    }

    function setWithdrawEscrow(address _withdrawEscrow) public onlyOwner {
        require(_withdrawEscrow != address(0), "PITokenController: invalid address");
        withdrawEscrow = _withdrawEscrow;
    }

    function setCakeEscrow(address _cakeEscrow) public onlyOwner {
        require(_cakeEscrow != address(0), "PITokenController: invalid address");
        cakeEscrow = _cakeEscrow;
    }

    function setRepayEscrow(address _repayEscrow) public onlyOwner {
        require(_repayEscrow != address(0), "PITokenController: invalid address");
        repayEscrow = _repayEscrow;
    }

    function setBinanceWallet(address _binanceWallet) public onlyOwner {
        require(_binanceWallet != address(0), "PITokenController: invalid address");
        binanceWallet = _binanceWallet;
    }

    function setFtxWallet(address _ftxWallet) public onlyOwner {
        require(_ftxWallet != address(0), "PITokenController: invalid address");
        ftxWallet = _ftxWallet;
    }

    function setShortLeverage(uint8 _shotLeverage) public onlyOwner {
        require(_shotLeverage > 0 && _shotLeverage <= 5, "PITokenController: invalid short leverage");
        shortLeverage = _shotLeverage;
    }

    function setVaultCake(address _vaultCake) public onlyOwner {
        require(_vaultCake != address(0) && _vaultCake != vaultCake, "PITokenController: invalid vaultCake");
        _safeApprove(CAKE, _vaultCake);
        if (vaultCake != address(0)) {
            //取出质押的cake，抵押到新的cake池子
            uint256 beforeAmt = balanceOfToken(CAKE);
            IVaultCake(vaultCake).withdrawAll(address(this));
            uint256 afterAmt = balanceOfToken(CAKE);
            uint256 cap = afterAmt.sub(beforeAmt);
            IVaultCake(_vaultCake).deposit(cap, address(this));
        }

        vaultCake = _vaultCake;
    }

    function calcTransferFee(address _token, address _sender, address _recipient, uint256 _amount, uint256 _depositedAt) external view returns(uint256) {
        require(_depositedAt <= block.timestamp, "PITokenController: invalid depositedAt");
        if (_token == _sender || 
            _token == _recipient || 
            isExcludedFromFee[_sender] == true || 
            isExcludedFromFee[_recipient] == true) {
            return 0;
        }

        uint256 cap = block.timestamp.sub(_depositedAt);
        if (cap <= SEC_OF_15DAYS) {
            return _amount.mul(feeOf15Days).div(FEE_MAX);
        } else if (cap <= SEC_OF_30DAYS) {
            return _amount.mul(feeOf30Days).div(FEE_MAX);
        } else {
            return 0;
        }
    }

    // 记录用户充入的USDT数量
    function deposit(uint256 _amount) public onlyPIToken {
        require(_amount > 0, "PITokenController: invalid amount");
        address underlying = IPIToken(msg.sender).underlying();
        IERC20(underlying).safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );

        _safeTransfer(underlying, depositEscrow, _amount);
        PITokenInfo storage piToken = piTokens[msg.sender];
        piToken.depositAmt = piToken.depositAmt.add(_amount);
        piToken.depositedAt = block.timestamp;
    }

    // 记录用户赎回USDT的数量
    function redeem(uint256 _amount) public onlyPIToken {
        require(_amount > 0, "PITokenController: invalid amount");
        PITokenInfo storage piToken = piTokens[msg.sender];
        piToken.redeemAmt = piToken.redeemAmt.add(_amount);
        piToken.redeemedAt = block.timestamp;
    }

    // 用户提取USDT本金及收益
    function withdraw(address _to, uint256 _amount) public onlyPIToken {
        address underlying = IPIToken(msg.sender).underlying();
        IEscrow(withdrawEscrow).transfer(underlying, _to, _amount);
    }

    // 交易员将USDT提取到中心化交易所：币安和FTX
    function withdrawToCex(address _piToken, uint256 _amount) public onlyAuthSenders {
        require(piTokens[_piToken].enable == true, "PITokenController: not PIToken");
        require(_amount > 0, "PITokenController: amount == 0");

        PITokenInfo storage piToken = piTokens[_piToken];
        piToken.depositAmt = piToken.depositAmt.sub(_amount);

        address underlying = IPIToken(_piToken).underlying();
        uint256 binanceAmt = _amount.mul(shortLeverage).div(shortLeverage+1);
        uint256 ftxAmt = _amount.sub(binanceAmt);

        IEscrow(depositEscrow).transfer(underlying, binanceWallet, binanceAmt);
        IEscrow(depositEscrow).transfer(underlying, ftxWallet, ftxAmt);

        emit WithdrawToCex(underlying, depositEscrow, binanceWallet, binanceAmt, ftxWallet, ftxAmt);
    }

    // 交易员将Cake质押到Cake池子中
    function depositCake() public onlyAuthSenders {
        uint256 bal = IERC20(CAKE).balanceOf(cakeEscrow);
        require(bal > 0, "PITokenController: cake escrow balance is 0");

        IEscrow(cakeEscrow).transfer(CAKE, address(this), bal);
        IVaultCake(vaultCake).deposit(bal, address(this));
        emit DepositCake(address(this), bal);
    }

    // 交易员提走Cake到币安交易所
    function withdrawCake(uint256 _amount) public onlyAuthSenders {
        require(_amount > 0, "PITokenController: amount == 0");
        uint256 beforeAmt = balanceOfToken(CAKE);
        IVaultCake(vaultCake).withdraw(_amount, address(this));
        uint256 afterAmt = balanceOfToken(CAKE);
        uint256 cap = afterAmt.sub(beforeAmt);
        require(cap == _amount, "PITokenController: withdraw exception");

        _safeTransfer(CAKE, binanceWallet, _amount);
        emit WithdrawCake(vaultCake, binanceWallet, _amount);
    }

    // 交易员提走Cake以及收益到币安交易所
    function withdrawAllCake() public onlyAuthSenders {
        uint256 beforeAmt = balanceOfToken(CAKE);
        IVaultCake(vaultCake).withdrawAll(address(this));
        uint256 afterAmt = balanceOfToken(CAKE);
        uint256 cap = afterAmt.sub(beforeAmt);

        _safeTransfer(CAKE, binanceWallet, cap);
        emit WithdrawAllCake(vaultCake, binanceWallet, cap);
    }

    // 交易员提走cake收益到币安交易所
    function claimCake() public onlyAuthSenders {
        uint256 beforeAmt = balanceOfToken(CAKE);
        IVaultCake(vaultCake).claim(address(this));
        uint256 afterAmt = balanceOfToken(CAKE);
        uint256 cap = afterAmt.sub(beforeAmt);

        _safeTransfer(CAKE, binanceWallet, cap);
        emit ClaimCake(vaultCake, binanceWallet, cap);
    }

    // 交易员将USDT充入提现智能合约
    function repay(address _piToken, uint256 _amount) public onlyAuthSenders {
        PITokenInfo storage piToken = piTokens[_piToken];
        require(piToken.enable == true, "PITokenController: not PIToken");
        address underlying = IPIToken(_piToken).underlying();
        require(_amount > 0 && _amount <= IERC20(underlying).balanceOf(repayEscrow), "PITokenController: invalid amount");

        if (_amount > piToken.redeemAmt) {
            _amount = piToken.redeemAmt;
        } 
        
        IEscrow(repayEscrow).transfer(underlying, withdrawEscrow, _amount);
        piToken.redeemAmt = piToken.redeemAmt.sub(_amount);

        emit Repay(underlying, repayEscrow, withdrawEscrow, _amount);
    }

    // 提现RepayEscrow token到中心化交易所
    function withdrawRepayEscrowToCex(address _piToken, uint256 _amount) public onlyAuthSenders {
        PITokenInfo storage piToken = piTokens[_piToken];
        require(piToken.enable == true, "PITokenController: not PIToken");
        address underlying = IPIToken(_piToken).underlying();
        require(_amount > 0 && _amount <= IERC20(underlying).balanceOf(repayEscrow), "PITokenController: invalid amount");

        uint256 binanceAmt = _amount.mul(shortLeverage).div(shortLeverage+1);
        uint256 ftxAmt = _amount.sub(binanceAmt);

        IEscrow(repayEscrow).transfer(underlying, binanceWallet, binanceAmt);
        IEscrow(repayEscrow).transfer(underlying, ftxWallet, ftxAmt);

        emit WithdrawToCex(underlying, repayEscrow, binanceWallet, binanceAmt, ftxWallet, ftxAmt);
    }

    // 提先CakeEscrow的Cake到中心化交易所
    function withdrawCakeEscrowToCex(uint256 _amount) public onlyAuthSenders {
        require(_amount > 0 && _amount <= IERC20(CAKE).balanceOf(cakeEscrow), "PITokenController: invalid amount");
        IEscrow(cakeEscrow).transfer(CAKE, binanceWallet, _amount);
        emit WithdrawCake(cakeEscrow, binanceWallet, _amount);
    }

    // 返回合约账户数据给交易员
    function piTokenInfo(address _piToken) public view returns(
        uint256 depositAmt, 
        uint256 depositedAt,
        uint256 redeemAmt,
        uint256 redeemedAt,
        uint256 walletBalanceOfUSD,
        uint256 walletBalanceOfCake,
        uint256 cakeDepositAmt,
        uint256 cakeDepositedAt,
        uint256 cakeEarnedAmt,
        uint256 cakeBalanceInUSD,
        uint256 cakePriceInUSD
    ) {
        PITokenInfo storage piToken = piTokens[_piToken];
        depositAmt = piToken.depositAmt;
        depositedAt = piToken.depositedAt;
        redeemAmt = piToken.redeemAmt;
        redeemedAt = piToken.redeemedAt;

        address underlying = IPIToken(_piToken).underlying();
        walletBalanceOfUSD = IERC20(underlying).balanceOf(repayEscrow);
        walletBalanceOfCake = IERC20(CAKE).balanceOf(cakeEscrow);

        (uint256 depositedAt, uint256 depositAmt, uint256 balanceValue, uint256 earnedAmt,) = IVaultCake(vaultCake).userInfoOf(address(this));
        cakeDepositAmt = depositAmt;
        cakeDepositedAt = depositedAt;
        cakeEarnedAmt = earnedAmt;
        cakeBalanceInUSD = balanceValue;
        cakePriceInUSD = priceCalculator.priceOfCake();
    }

    // 返回费率信息
    function feeInfo() public view returns(
        uint256 feeOf15Days_,
        uint256 feeOf30Days_,
        uint256 SEC_OF_15DAYS_,
        uint256 SEC_OF_30DAYS_
    ) {
        feeOf15Days_ = feeOf15Days;
        feeOf30Days_ = feeOf30Days;
        SEC_OF_15DAYS_ = SEC_OF_15DAYS;
        SEC_OF_30DAYS_ = SEC_OF_30DAYS;
    }
}

