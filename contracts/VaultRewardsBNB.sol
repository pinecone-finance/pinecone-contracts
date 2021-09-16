// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./VaultBase.sol";
import "./BSWStrat.sol";

//Investment strategy
contract VaultRewardsBNB is VaultBase {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public sharesTotal;

    uint256 public manageFee; 
    uint256 public constant manageFeeMax = 10000; // 100 = 1%
    uint256 public constant manageFeeUL = 5000; // max 50%
    address public constant CAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    uint256 internal constant dust = 1000;
    uint256 internal constant UNIT = 1e18;

    /* ========== public method ========== */
    function initialize  (
        address _config
    ) external initializer {

        _VaultBase_init(_config, address(0));
        _safeApprove(config.PCT(), CAKE_ROUTER);
        _safeApprove(WBNB, CAKE_ROUTER);

        manageFee = 5000;
    }

    receive() external payable {}

    function stakeType() public pure returns(StakeType) {
        return StakeType.RewardsPCT;
    }

    function earned0Address() public pure returns(address) {
        return WBNB;
    }

    function earned1Address() public pure returns(address) {
        return address(0);
    }

    function setManageFee(uint256 _fee) onlyGov public {
        require(_fee <= manageFeeUL, "too high");
        manageFee = _fee;
    }

    function tvl() public view returns(uint256 priceInUsd) {
        (uint256 wantAmt, uint256 bnbAmt) = balance();
        IPineconeConfig _config = config;
        uint256 wantTvl = wantAmt.mul(_config.priceOfToken(_config.PCT())).div(UNIT);
        uint256 bnbTvl = bnbAmt.mul(_config.priceOfToken(WBNB)).div(UNIT);
        return wantTvl.add(bnbTvl);
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

    function balance() public view returns(uint256 wantAmt, uint256 bnbAmt) {
        wantAmt = IERC20(config.PCT()).balanceOf(address(this));
        bnbAmt = IERC20(WBNB).balanceOf(address(this));
    }

    function balanceOfShares(uint256 shares) public view returns(uint256 wantAmt, uint256 bnbAmt) {
        if (sharesTotal == 0 || shares == 0) {
            return (0,0);
        }

        if (shares > sharesTotal) {
            shares = sharesTotal;
        }

        (wantAmt, bnbAmt) = balance();
        wantAmt = wantAmt.mul(shares).div(sharesTotal);
        bnbAmt = bnbAmt.mul(shares).div(sharesTotal);
    }

    function pendingRewardsValue() public view returns(uint256 priceInUsd) {
        (, uint256 bnbAmt) = balance();

        IPineconeConfig _config = config;
        uint256 bnbValue = bnbAmt.mul(_config.priceOfToken(WBNB)).div(UNIT);
        return bnbValue;
    }

    function pendingBNB(uint256 _shares, address _user) public view returns(uint256) {
        _user;
        (uint256 wantAmt, ) = balanceOfShares(_shares);
        if (wantAmt == 0) return 0;

        return config.valueInBNB(config.PCT(), wantAmt);
    }

    function deposit(uint256 _shares, address _user)
        public
        onlyOwner
        whenNotPaused
        returns (uint256)
    {
        _user;
        IERC20(WBNB).safeTransferFrom(
            address(msg.sender),
            address(this),
            _shares
        );
        sharesTotal = sharesTotal.add(_shares);
        return _shares;
    }

    function migrate(uint256 _amount, uint256 _sharesTotal)
        public 
        onlyOwner
        whenNotPaused
    {
        IERC20(WBNB).safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        sharesTotal = _sharesTotal;
    }

    function earn() public whenNotPaused onlyGov
    {
        _earn();
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

        (uint256 wantAmt,) = balanceOfShares(_shares);

        wantAmt = _swap(WBNB, wantAmt, _tokenPath(config.PCT(), WBNB), CAKE_ROUTER);
        
        sharesTotal = sharesTotal.sub(_shares);
        _safeTransfer(WBNB, _user, wantAmt, config.wNativeRelayer());
        return wantAmt;
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount)
        public
        onlyGov
    {
        require(_token != config.PCT(), "!safe");
        require(_token != WBNB, "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    function withdrawAll(address _user)
        public 
        onlyOwner
        nonReentrant
        returns (uint256, uint256, uint256)
     {
         _user;
         require(sharesTotal > 0, "sharesTotal == 0!");
        (, uint256 bnbAmt) = balance();

        address PCT = config.PCT();
        if (bnbAmt > 0) {
            _swap(PCT, bnbAmt, _tokenPath(WBNB, PCT), CAKE_ROUTER);
        }
        
        uint256 balanceAmt = IERC20(PCT).balanceOf(address(this));
        IERC20(PCT).safeTransfer(msg.sender, balanceAmt);
        sharesTotal = 0;
        return (balanceAmt, 0, 0);
    }

    /* ========== private method ========== */
    function _earn() private {
        // WBNB to PCT
        uint256 bnbAmt = IERC20(WBNB).balanceOf(address(this));
        if (bnbAmt > 0) {
            address PCT = config.PCT();
            uint256 pctAmt = _swap(PCT, bnbAmt, _tokenPath(WBNB, PCT), CAKE_ROUTER);
            if (pctAmt > dust) {
                uint256 fee = pctAmt.mul(manageFee).div(manageFeeMax);
                IERC20(PCT).safeTransfer(devAddress, fee);
            }
        }
    }

    function _tokenPath(address _token0, address _token1) private pure returns(address[] memory path) {
        require(_token0 != _token1, "_token0 == _token1");
        if (_token0 == WBNB || _token1 == WBNB) {
            path = new address[](2);
            path[0] = _token0;
            path[1] = _token1;
        } else {
            path = new address[](3);
            path[0] = _token0;
            path[1] = WBNB;
            path[2] = _token1;
        }
    }

    function _swap(address token, uint256 amount, address[] memory path, address router) private returns(uint256) {
        if (amount == 0 || path.length == 0) return 0;

        uint256 amt = IERC20(path[0]).balanceOf(address(this));
        if (amount > amt) {
            amount = amt;
        }

        uint256 beforeAmount = IERC20(token).balanceOf(address(this));
        IPancakeRouter02(router)
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

    function _safeApprove(address token, address spender) internal {
        if (token != address(0) && IERC20(token).allowance(address(this), spender) == 0) {
            IERC20(token).safeApprove(spender, uint256(~0));
        }
    }

    function _safeTransfer(address _token, address _to, uint256 _amount, address wNativeRelayer) internal {
        if (_amount == 0) return;

        if (_token == WBNB) {
            IERC20(WBNB).safeTransfer(wNativeRelayer, _amount);
            IWNativeRelayer(wNativeRelayer).withdraw(_amount);
            SafeERC20.safeTransferETH(_to, _amount);
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }
}