// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./libraries/SafeMath.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IWexMaster.sol";
import "./interfaces/IMasterChef.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IWNativeRelayer.sol";

contract Strat {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct UserAssetInfo
    {
        uint256 depositAmt;
        uint256 depositedAt;
        uint256 shares;
        uint256 pending;
        uint256 rewardPaid;
    }

    uint256 public sharesTotal;
    mapping (address=>UserAssetInfo) users;

    address public constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant WEX = 0xa9c41A46a6B3531d28d5c32F6633dd2fF05dFB90;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E; 

    IWexMaster public constant wexMaster = IWexMaster(0x22fB2663C7ca71Adc2cc99481C77Aaf21E152e2D);
    uint256 public constant wpid = 3;

    IMasterChef public constant cakeMaster = IMasterChef(0x73feaa1eE314F8c655E354234017bE2193C9E24E);
    uint256 public constant cpid = 0;

    address public stakingToken;
    address public reawardToken;

    uint256 internal constant dust = 1000;
    uint256 internal constant UNIT = 1e18;

    uint256 public totalStakingWexAmount;

    uint256 public accPerShareOfWex;

    /* ========== public view ========== */
    function sharesOf(address _user) public view returns(uint256) {
        return users[_user].shares;
    }

    function depositAmtOf(address _user) public view returns(uint256) {
        return users[_user].depositAmt;
    }

    function depositedAt(address _user) public view returns(uint256) {
        return users[_user].depositedAt;
    }

    function withdrawableBalanceOf(address _user) public virtual view returns(uint256) {
        return users[_user].depositAmt;
    }

    /* ========== internal method ========== */

    function _StratWex_init(address _stakingToken, address _reawardToken) internal {
        stakingToken = _stakingToken;
        reawardToken = _reawardToken;
        sharesTotal = 0;
        totalStakingWexAmount = 0;
        accPerShareOfWex = 0;

        _safeApprove(stakingToken, ROUTER);
        _safeApprove(reawardToken, ROUTER);
        _safeApprove(WEX, ROUTER);
        _safeApprove(WBNB, ROUTER);
        _safeApprove(CAKE, ROUTER);
        _safeApprove(WEX, address(wexMaster));
    }

    function _tokenPath(address _token0, address _token1) internal pure returns(address[] memory path) {
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

    function _stakingWex() internal view returns(uint256) {
        return totalStakingWexAmount;
    }

    function _pendingWex() internal view returns(uint256) {
        return wexMaster.pendingWex(wpid, address(this));
    }

    function _pendingWex(address _user) internal view returns(uint256) {
        UserAssetInfo storage user = users[_user];
        uint256 pending = user.pending.add(user.shares.mul(accPerShareOfWex).div(1e12).sub(user.rewardPaid));
        return pending;
    }

    function _reawardTokenToWex() internal returns(uint256) {
        uint256 amount = IERC20(reawardToken).balanceOf(address(this));
        if (amount > dust) {
            return _swap(WEX, amount, _tokenPath(reawardToken, WEX));
        }
        return 0;
    }

    function _farmWex() internal {
        uint256 amount = IERC20(WEX).balanceOf(address(this));
        if (amount > dust) {
            wexMaster.deposit(wpid, amount, false);
            totalStakingWexAmount = totalStakingWexAmount.add(amount);

            if (sharesTotal > 0) {
                accPerShareOfWex = accPerShareOfWex.add(amount.mul(1e12).div(sharesTotal));
            }
        }
    }

    function _withdrawWex(uint256 _amount) internal {
        if (_amount == 0 || IERC20(WEX).balanceOf(address(this)) >= _amount) return;
        uint256 _amt = _stakingWex();
        if (_amount > _amt) {
            _amount = _amt;
        }
        wexMaster.withdraw(wpid, _amount, true);
        totalStakingWexAmount = totalStakingWexAmount.sub(_amount);
    }

    function _claimWex() internal {
        wexMaster.claim(wpid);
    }

    function _stakingCake() internal view returns(uint256) {
        (uint amount,) = cakeMaster.userInfo(cpid, address(this));
        return amount;
    }

    function _pendingCake() internal view returns(uint256) {
        return cakeMaster.pendingCake(cpid, address(this));
    }

    function _reawardCakeToWex() internal returns(uint256) {
        uint256 before = IERC20(CAKE).balanceOf(address(this));
        _claimCake();
        uint256 amount = IERC20(CAKE).balanceOf(address(this)).sub(before);
        if (amount > dust) {
            _swap(WEX, amount, _tokenPath(CAKE, WEX));
        }
    }

    function _farmCake() internal {
        uint256 wantAmt = IERC20(CAKE).balanceOf(address(this));
        if (wantAmt > 0) {
            cakeMaster.enterStaking(wantAmt);
        }
    }

    function _claimCake() internal {
        cakeMaster.leaveStaking(0);
    }

    function _withdrawCake(uint256 amount, bool claim) internal {
        uint cakeBalance = IERC20(CAKE).balanceOf(address(this));
        if (cakeBalance < amount) {
            cakeMaster.leaveStaking(amount.sub(cakeBalance));
        } else {
            if (claim) {
                _claimCake();
            }
        }
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
}