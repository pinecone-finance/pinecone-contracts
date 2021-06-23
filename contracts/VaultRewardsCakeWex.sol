// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./VaultBase.sol";
import "./Strat.sol";

//Investment strategy
contract VaultRewardsCakeWex is VaultBase, Strat{

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public manageFee; 
    uint256 public constant manageFeeMax = 10000; // 100 = 1%
    uint256 public constant manageFeeUL = 3000; // max 30%
    mapping (address => bool) private _isExcludedFromFee;

    /* ========== public method ========== */
    function initialize  (
        address _config
    ) external initializer {
        address _stratAddress = 0x73feaa1eE314F8c655E354234017bE2193C9E24E;
        address _stakingToken = CAKE; 

        _VaultBase_init(_config, _stratAddress);
        _StratWex_init(_stakingToken, CAKE);

        _safeApprove(_stakingToken, _stratAddress);
        _safeApprove(config.PCT(), ROUTER);
        _isExcludedFromFee[msg.sender] = true;
        manageFee = 3000;
    }

    receive() external payable {}

    function stakeType() public pure returns(StakeType) {
        return StakeType.RewardsCake_Wex;
    }

    function earned0Address() public pure returns(address) {
        return WBNB;
    }

    function earned1Address() public pure returns(address) {
        return address(0);
    }

    function isExcludedFromFee(address account) public view returns(bool) {
        return _isExcludedFromFee[account];
    }

    function excludeFromFee(address account) public onlyDev {
        _isExcludedFromFee[account] = true;
    }
    
    function includeInFee(address account) public onlyDev {
        _isExcludedFromFee[account] = false;
    }

    function setManageFee(uint256 _fee) onlyGov public 
    {
        require(_fee <= manageFeeUL, "too high");
        manageFee = _fee;
    }

    function tvl() public view returns(uint256 priceInUsd) {
        (uint256 wantAmt, uint256 cakeAmt, uint256 wexAmt) = balance();
        wantAmt = wantAmt.add(cakeAmt);

        IPineconeConfig _config = config;
        uint256 wantTvl = wantAmt.mul(_config.priceOfToken(CAKE)).div(UNIT);
        uint256 wexTvl = wexAmt.mul(_config.priceOfToken(WEX)).div(UNIT);
        return wantTvl.add(wexTvl);
    }

    function userInfoOf(address _user, uint256 _addPct) public pure 
        returns(
            uint256 depositedAt, 
            uint256 depositAmt,
            uint256 balanceValue,
            uint256 earned0Amt,
            uint256 earned1Amt,
            uint256 withdrawbaleAmt
        ) 
    {
        _user;
        _addPct;
        return (0,0,0,0,0,0);
    }

    function balance() public view returns(uint256 wantAmt, uint256 cakeAmt, uint256 wexAmt) {
        wantAmt = _stakingCake();
        cakeAmt = _pendingCake();
        wexAmt = _stakingWex();
        uint256 pendingWex = _pendingWex();
        wexAmt = wexAmt.add(pendingWex);
    }

    function balanceOfShares(uint256 shares) public view returns(uint256 wantAmt, uint256 cakeAmt, uint256 wexAmt) {
        if (sharesTotal == 0 || shares == 0) {
            return (0,0,0);
        }

        if (shares > sharesTotal) {
            shares = sharesTotal;
        }

        (wantAmt, cakeAmt, wexAmt) = balance();
        wantAmt = wantAmt.mul(shares).div(sharesTotal);
        cakeAmt = cakeAmt.mul(shares).div(sharesTotal);
        wexAmt = wexAmt.mul(shares).div(sharesTotal);
    }

    function pendingRewardsValue() public view returns(uint256 priceInUsd) {
        uint256 cakeAmt = _pendingCake();
        uint256 wexAmt = _pendingWex();

        IPineconeConfig _config = config;
        uint256 cakeValue = cakeAmt.mul(_config.priceOfToken(CAKE)).div(UNIT);
        uint256 wexValue = wexAmt.mul(_config.priceOfToken(WEX)).div(UNIT);
        return cakeValue.add(wexValue);
    }

    function pendingCake(uint256 _shares, address _user) public view returns(uint256)
    {
        if (sharesTotal == 0 || _shares == 0) {
            return 0;
        }

        (uint256 wantAmt, uint256 cakeAmt, uint256 wexAmt) = balanceOfShares(_shares);
        wantAmt = wantAmt.add(cakeAmt);

        uint256 wexToAmt = config.getAmountsOut(wexAmt, WEX, CAKE);
        wantAmt = wantAmt.add(wexToAmt);

        if (isExcludedFromFee(_user) == false) {
            uint256 fee = wantAmt.mul(manageFee).div(manageFeeMax);
            wantAmt = wantAmt.sub(fee);
        } 

        return wantAmt;
    } 

    function pendingBNB(uint256 _shares, address _user) public view returns(uint256) {
        uint256 cakeAmt = pendingCake(_shares, _user);
        if (cakeAmt == 0) return 0;

        return config.getAmountsOut(cakeAmt, CAKE, WBNB);
    }

    function deposit(uint256 _shares, address _user)
        public
        onlyOwner
        whenNotPaused
        returns (uint256)
    {
        _user;
        IERC20(CAKE).safeTransferFrom(
            address(msg.sender),
            address(this),
            _shares
        );
        sharesTotal = sharesTotal.add(_shares);
        _farm();
        return _shares;
    }

    function farm() public nonReentrant {
        _farm();
    }

    function earn() public whenNotPaused onlyGov
    {
        //auto compounding cake
        if (lastEarnBlock >= block.number) return;
        _reawardCakeToWex();
        _claimWex();
        _farm();
        lastEarnBlock = block.number;
    }

    function claimBNB(uint256 _shares, address _user) 
        public 
        onlyOwner
        nonReentrant
        returns(uint256)
    {
        require(sharesTotal > 0, "sharesTotal is 0");
        require(_shares > 0, "user _shares is 0");

        if (_shares > sharesTotal) {
            _shares = sharesTotal;
        }

        (uint256 wantAmt, uint256 cakeAmt, uint256 wexAmt) = balanceOfShares(_shares);
        _withdrawCake(wantAmt, true);
        _withdrawWex(wexAmt);
        wantAmt = wantAmt.add(cakeAmt);
        uint256 swapAmt = _swap(CAKE, wexAmt, _tokenPath(WEX, CAKE));
        wantAmt = wantAmt.add(swapAmt);

        uint256 earnedCakeAmt = cakeAmt.add(swapAmt);
        if (earnedCakeAmt > dust) {
            IPineconeConfig _config = config;
            IPineconeFarm pineconeFarm = _config.pineconeFarm();
            uint256 profit = _config.getAmountsOut(earnedCakeAmt, CAKE, WBNB);
            pineconeFarm.mintForProfit(address(pineconeFarm), profit, true);
        }

        wantAmt = wantAmt.add(earnedCakeAmt);
        uint256 balanceAmt = IERC20(CAKE).balanceOf(address(this));
        if (wantAmt > balanceAmt) {
            wantAmt = balanceAmt;
        }

        wantAmt = _swap(WBNB, wantAmt, _tokenPath(CAKE, WBNB));

        if (isExcludedFromFee(_user) == false) {
            uint256 fee = _distributeManageFees(wantAmt);
            wantAmt = wantAmt.sub(fee);
        }
        
        sharesTotal = sharesTotal.sub(_shares);
        _safeTransfer(WBNB, _user, wantAmt, config.wNativeRelayer());
        _farm();
        return wantAmt;
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount)
        public
        onlyGov
    {
        require(_token != config.PCT(), "!safe");
        require(_token != CAKE, "!safe");
        require(_token != WEX, "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    /* ========== private method ========== */
    function _farm() private {
        _farmCake();
        _farmWex();
    }

    function _distributeManageFees(uint256 _earnedAmt) private returns (uint256) {
        if (_earnedAmt <= dust) {
            return 0;
        }

        // commission bnb profit to dev group
        uint256 fee = _earnedAmt.mul(manageFee).div(manageFeeMax);
        _swapToPctPair(fee.div(2));
        return fee;
    }

    function _swapToPctPair(uint256 amount) internal {
        if (amount == 0) return;

        uint256 bnbAmount = amount;
        address PCT = config.PCT();
        uint256 pctAmount = _swap(PCT, amount, _tokenPath(WBNB, PCT));

        if (bnbAmount > 0 && pctAmount > 0) {
            IPancakeRouter02(ROUTER).addLiquidity(
                WBNB,
                PCT,
                bnbAmount,
                pctAmount,
                0,
                0,
                devAddress,
                now + 60
            );
        }
    }
}