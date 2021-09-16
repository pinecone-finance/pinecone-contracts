// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./interfaces/IAlpaca.sol";
import "./interfaces/IStakePool.sol";
import "./VaultBase.sol";
import "./interfaces/IPancakeRouter02.sol";

//Investment strategy
contract VaultAlpacaSCIX is VaultBase {

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

    address public constant ALPACA = 0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F;
    address public constant ibALPACA = 0xf1bE8ecC990cBcb90e166b71E368299f0116d421;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant SCIX = 0x2CFC48CdFea0678137854F010b5390c5144C0Aa5;
    address public constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;

    uint256 internal constant dust = 1000;
    uint256 internal constant UNIT = 1e18;

    address public stakingToken;

    IStakePool public constant stakingPool = IStakePool(0x68145F3319F819b8E01Dfa3c094fa8205E9EfB9a);

    function initialize (
        address _config
    ) external initializer {
        stakingToken = ALPACA;
        _VaultBase_init(_config, ibALPACA);

        _safeApprove(ALPACA, ibALPACA);
        _safeApprove(ALPACA, ROUTER);
        _safeApprove(SCIX, ROUTER);
        _safeApprove(WBNB, ROUTER);
        _safeApprove(ibALPACA, address(stakingPool));

        IPineconeFarm pineconeFarm = config.pineconeFarm();
        _safeApprove(WBNB, address(pineconeFarm));
    }

    receive() external payable {}

    /* ========== public view ========== */
    function farmPid() public pure returns(uint256) {
        return 3;
    }

    function stakeType() public pure returns(StakeType) {
        return StakeType.Alpaca_SCIX;
    }

    function earned0Address() public pure returns(address) {
        return ALPACA;
    }

    function earned1Address() public view returns(address) {
        return config.PCT();
    }

    function sharesOf(address _user) public view returns(uint256) {
        return users[_user].shares;
    }

    function depositAmtOf(address _user) public view returns(uint256) {
        return users[_user].depositAmt;
    }

    function depositedAt(address _user) public view returns(uint256) {
        return users[_user].depositedAt;
    }

    function alpacaStakingAmount() public view returns(uint256) {
        uint256 ibAmt = stakingPool.getStakeTotalDeposited(address(this), farmPid());
        address vault = ibALPACA;
        uint256 total = IVault(vault).totalToken();
        uint256 supply = IERC20(address(vault)).totalSupply();
        if (supply == 0) {
            return ibAmt;
        }

        return ibAmt.mul(total).div(supply);
    }

    function scixPendingAmount() public view returns(uint256) {
        return stakingPool.getStakeTotalUnclaimed(address(this), farmPid());
    }

    function userInfoOf(address _user, uint256 _addPct) public view 
        returns(
            uint256 depositAt, 
            uint256 depositAmt,
            uint256 balanceValue,
            uint256 earned0Amt,
            uint256 earned1Amt,
            uint256 withdrawbaleAmt
        ) 
    {
        UserAssetInfo storage user = users[_user];
        depositAt = user.depositedAt;
        depositAmt = user.depositAmt;
        (earned0Amt, earned1Amt) = pendingRewards(_user);
        earned1Amt = earned1Amt.add(_addPct);
        withdrawbaleAmt = depositAmtOf(_user);
        uint256 wantAmt = depositAmt.add(earned0Amt);

        IPineconeConfig _config = config;
        uint256 wantValue = wantAmt.mul(_config.priceOfToken(stakingToken)).div(UNIT);
        uint256 earned1Value = earned1Amt.mul(_config.priceOfPct()).div(UNIT);
        balanceValue = wantValue.add(earned1Value);
    }

    function tvl() public view returns(uint256 priceInUsd) {
        (uint256 wantAmt, uint256 scixAmt) = balance();
        IPineconeConfig _config = config;
        uint256 wantTvl = wantAmt.mul(_config.priceOfToken(stakingToken)).div(UNIT);
        uint256 scixTvl = scixAmt.mul(_config.priceOfToken(SCIX)).div(UNIT);
        return wantTvl.add(scixTvl);
    }

    function balance() public view returns(uint256 wantAmt, uint256 scixAmt) {
        wantAmt = alpacaStakingAmount();
        scixAmt = scixPendingAmount();
    }

    function balanceOf(address _user) public view returns(uint256 wantAmt, uint256 scixAmt) {
        if (sharesTotal == 0) {
            return (0,0);
        }
        uint256 shares = sharesOf(_user);
        (wantAmt,scixAmt) = balance();
        wantAmt = wantAmt.mul(shares).div(sharesTotal);
        scixAmt = scixAmt.mul(shares).div(sharesTotal);
    }

    function earnedOf(address _user) public view returns(uint256 wantAmt, uint256 scixAmt) {
        UserAssetInfo storage user = users[_user];
        (wantAmt, scixAmt) = balanceOf(_user);
        if (wantAmt > user.depositAmt) {
            wantAmt = wantAmt.sub(user.depositAmt);
        } else {
            wantAmt = 0;
        }
    }

    function pendingRewardsValue() public view returns(uint256 priceInUsd) {
        uint256 pendingSCIX = scixPendingAmount();

        IPineconeConfig _config = config;
        uint256 value = pendingSCIX.mul(_config.priceOfToken(SCIX)).div(UNIT);
        return value;
    }

    function pendingRewards(address _user) public view returns(uint256 wantAmt, uint256 pctAmt)
    {
        if (sharesTotal == 0) {
            return (0, 0);
        }

        (uint256 wantAmt0, uint256 scixAmt) = earnedOf(_user);
        wantAmt = wantAmt0;
        IPineconeConfig _config = config;
        uint256 scixToAmt = _config.getAmountsOut(scixAmt, SCIX, stakingToken);
        wantAmt = wantAmt.add(scixToAmt);
        uint256 fee = performanceFee(wantAmt);
        pctAmt = config.tokenAmountPctToMint(stakingToken, fee);
        wantAmt = wantAmt.sub(fee);
    }

    /* ========== public write ========== */
    function deposit(uint256 _wantAmt, address _user)
        public
        onlyOwner
        whenNotPaused
        returns(uint256)
    {
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
        if (wantTotal > 0 && sharesTotal >0) {
            sharesAdded = sharesAdded
                .mul(sharesTotal)
                .div(wantTotal);
        }

        _farmAlpaca();

        sharesTotal = sharesTotal.add(sharesAdded);
        user.shares = user.shares.add(sharesAdded);
        return sharesAdded;
    }

    function farm() public nonReentrant 
    {
        _farmAlpaca();
    }

    function earn() public whenNotPaused onlyGov
    {   
        _earn();
    }

    function withdrawAll(address _user)
        public 
        onlyOwner
        nonReentrant
        returns (uint256, uint256, uint256)
    {
        require(sharesTotal > 0, "sharesTotal == 0");

        UserAssetInfo storage user = users[_user];
        require(user.shares > 0, "user.shares == 0");
        require(user.depositAmt > 0, "user.depositAmt == 0");

        uint256 wantAmt = user.depositAmt;
        (uint256 earnedWantAmt, uint256 scixAmt) = earnedOf(_user);

        _withdrawWant(wantAmt.add(earnedWantAmt));
        _claimSCIX();

        uint256 swapAmt = _swap(stakingToken, scixAmt, _scixToAlpacaPath());
        earnedWantAmt = earnedWantAmt.add(swapAmt);

        //withdraw fee
        {
            uint256 withdrawFeeAmt = 0;
            bool hasFee = (user.depositedAt.add(minDepositTimeWithNoFee) > block.timestamp) ? true : false;
            if (hasFee) {
                withdrawFeeAmt = wantAmt.mul(withdrawFeeFactor).div(feeMax);
                _safeTransfer(stakingToken, devAddress, withdrawFeeAmt);
                wantAmt = wantAmt.sub(withdrawFeeAmt);
            }
        }

        //performace fee
        (uint256 fee, uint256 pctAmt) = _distributePerformanceFees(earnedWantAmt, _user);
        earnedWantAmt = earnedWantAmt.sub(fee);
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
        return (wantAmt, earnedWantAmt, pctAmt);
    }

    function withdraw(uint256 _wantAmt, address _user)
        public 
        onlyOwner
        nonReentrant
        returns (uint256, uint256)
    {
        require(_wantAmt > 0, "_wantAmt == 0");
        require(sharesTotal > 0, "sharesTotal == 0");

        UserAssetInfo storage user = users[_user];
        require(user.shares > 0, "user.shares == 0");
        require(user.depositAmt >= _wantAmt, "user.depositAmt < _wantAmt");

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
        returns(uint256, uint256)
    {
        (uint256 rewardAmt, uint256 pct) = _claim(_user);
        _earn();
        return (rewardAmt, pct);
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount)
        public
        onlyGov
    {
        require(_token != config.PCT() && _token != stakingToken && _token != SCIX, "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    /* ========== private methord ========== */
    function _farmAlpaca() private {
        uint256 wantAmt = IERC20(stakingToken).balanceOf(address(this));
        if (wantAmt > 0) {
            IVault(ibALPACA).deposit(wantAmt);
        }

        uint256 ibAmt = IERC20(ibALPACA).balanceOf(address(this));
        if (ibAmt > 0) {
            stakingPool.deposit(farmPid(), ibAmt);
        }
    }

    function _claimSCIX() private {
        stakingPool.claim(farmPid());
    }

    function _earn() private {
        _claimSCIX();
        _scixToAlpaca();
        _farmAlpaca();
    }

    function _scixToAlpaca() internal returns(uint256) {
        uint256 amount = IERC20(SCIX).balanceOf(address(this));
        if (amount > dust) {
            return _swap(ALPACA, amount, _scixToAlpacaPath());
        }
        return 0;
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

        _withdrawWant(_wantAmt);
        uint256 wantAmt = IERC20(stakingToken).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        bool hasFee = (user.depositedAt.add(minDepositTimeWithNoFee) > block.timestamp) ? true : false;
        if (hasFee) {
            uint256 withdrawFeeAmt = _wantAmt.mul(withdrawFeeFactor).div(feeMax);
            _safeTransfer(stakingToken, devAddress, withdrawFeeAmt);
            _wantAmt = _wantAmt.sub(withdrawFeeAmt);
        }
        _safeTransfer(stakingToken, _user, _wantAmt);

        return (_wantAmt, sharesRemoved);
    }

    function _withdrawWant(uint256 amount) private  {
        if (amount == 0) return;
        IAlpacaCalculator alpacaCalculator = config.alpacaCalculator();
        amount = alpacaCalculator.ibTokenCalculation(ibALPACA, amount);
        uint256 amt = stakingPool.getStakeTotalDeposited(address(this), farmPid());
        if (amount > amt) {
            amount = amt;
        }
        stakingPool.withdraw(farmPid(), amount);
        amt = IERC20(ibALPACA).balanceOf(address(this));
        if (amount > amt) {
            amount = amt;
        }

        IVault(ibALPACA).withdraw(amount);
    }

    function _claim(address _user) private returns(uint256, uint256) {
        (uint256 wantAmt, uint256 scixAmt) = earnedOf(_user);
        if (wantAmt == 0 && scixAmt == 0) {
            return(0,0);
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

        _withdrawWant(wantAmt);
        _claimSCIX();

        uint256 swapAmt = _swap(stakingToken, scixAmt, _scixToAlpacaPath());
        wantAmt = wantAmt.add(swapAmt);

        uint256 balanceAmt = IERC20(stakingToken).balanceOf(address(this));
        if (wantAmt > balanceAmt) {
            wantAmt = balanceAmt;
        }

        //performance fee
        (uint256 fee, uint256 pctAmt) = _distributePerformanceFees(wantAmt, _user);
        wantAmt = wantAmt.sub(fee);
        _safeTransfer(stakingToken, _user, wantAmt);
        return (wantAmt, pctAmt);
    }

    function _distributePerformanceFees(uint256 _wantAmt, address _user) private returns(uint256 fee, uint256 pct) {
        if (_wantAmt <= dust) {
            return (0, 0);
        }

        pct = 0;
        fee = performanceFee(_wantAmt);
        if (fee > 0) {
            IPineconeFarm pineconeFarm = config.pineconeFarm();
            uint256 profit = config.valueInBNB(stakingToken, fee);
            pct = pineconeFarm.mintForProfit(_user, profit, false);

            uint256 bnbAmt = _swap(WBNB, fee, _alpacaToWBNBPath());
            if (bnbAmt > 0) {
                pineconeFarm.stakeRewardsTo(address(pineconeFarm), bnbAmt);
            }
        }
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

    function _swap(address token, uint256 amount, address[] memory path) internal returns(uint256) {
        if (amount == 0 || path.length == 0) return 0;

        uint256 amt = IERC20(path[0]).balanceOf(address(this));
        if (amount > amt) {
            amount = amt;
        }

        uint256 beforeAmount = IERC20(token).balanceOf(address(this));
        IPancakeRouter02(ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount,
            0,
            path,
            address(this),
            now + 60
        );

        uint256 afterAmount = IERC20(token).balanceOf(address(this));
        if (afterAmount > beforeAmount) {
            return afterAmount.sub(beforeAmount);
        }
        return 0;
    }

    function _scixToAlpacaPath() private pure returns(address[] memory path) {
        path = new address[](3);
        path[0] = SCIX;
        path[1] = BUSD;
        path[2] = ALPACA;
    }

    function _alpacaToWBNBPath() private pure returns(address[] memory path) {
        path = new address[](3);
        path[0] = ALPACA;
        path[1] = BUSD;
        path[2] = WBNB;
    }
}