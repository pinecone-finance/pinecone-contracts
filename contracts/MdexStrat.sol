// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./libraries/SafeMath.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IBoardRoomMDX.sol";
import "./interfaces/IMasterChef.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IWNativeRelayer.sol";

contract MdexStrat {
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
    address public constant MDEX = 0x9C65AB58d8d978DB963e63f2bfB7121627e3a739;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant ROUTER = 0x7DAe51BD3E3376B8c7c4900E9107f12Be3AF1bA8; 

    IBoardRoomMDX public constant mdexMaster = IBoardRoomMDX(0x6aEE12e5Eb987B3bE1BA8e621BE7C4804925bA68);
    uint256 public constant mpid = 4;

    IMasterChef public constant cakeMaster = IMasterChef(0x73feaa1eE314F8c655E354234017bE2193C9E24E);
    uint256 public constant cpid = 0;

    address public stakingToken;
    address public reawardToken;

    uint256 internal constant dust = 1000;
    uint256 internal constant UNIT = 1e18;

    uint256 public totalStakingMdexAmount;
    uint256 public accPerShareOfMdex;

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

    function userOf(address _user) public view returns(
        uint256 _depositAmt, 
        uint256 _depositedAt, 
        uint256 _shares,
        uint256 _pending,
        uint256 _rewardPaid
    ) {
        UserAssetInfo storage user = users[_user];
        _depositAmt = user.depositAmt;
        _depositedAt = user.depositedAt;
        _shares = user.shares;
        _pending = user.pending;
        _rewardPaid = user.rewardPaid;
    }

    function pendingMdex() public view returns(uint256) {
        return _pendingMdex();
    }

    function pendingMdexPerShare() public view returns(uint256) {
        if (sharesTotal == 0) {
            return 0;
        }

        uint256 perShare = _pendingMdex().mul(1e12).div(sharesTotal);
        return perShare;
    }

    /* ========== internal method ========== */

    function _StratMdex_init(address _stakingToken, address _reawardToken) internal {
        stakingToken = _stakingToken;
        reawardToken = _reawardToken;
        sharesTotal = 0;
        totalStakingMdexAmount = 0;
        accPerShareOfMdex = 0;

        _safeApprove(stakingToken, ROUTER);
        _safeApprove(reawardToken, ROUTER);
        _safeApprove(MDEX, ROUTER);
        _safeApprove(WBNB, ROUTER);
        _safeApprove(CAKE, ROUTER);
        _safeApprove(MDEX, address(mdexMaster));
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

    function _stakingMdex() internal view returns(uint256) {
        return totalStakingMdexAmount;
    }

    function _pendingMdex() internal view returns(uint256) {
        return mdexMaster.pending(mpid, address(this));
    }

    function _pendingMdex(address _user) internal view returns(uint256) {
        UserAssetInfo storage user = users[_user];
        uint256 perShare = pendingMdexPerShare();
        perShare = perShare.add(accPerShareOfMdex);
        uint256 pending = user.pending.add(user.shares.mul(perShare).div(1e12).sub(user.rewardPaid));
        return pending;
    }

    function _reawardTokenToMdex() internal returns(uint256) {
        uint256 amount = IERC20(reawardToken).balanceOf(address(this));
        if (amount > dust) {
            return _swap(MDEX, amount, _tokenPath(reawardToken, MDEX), ROUTER);
        }
        return 0;
    }

    function _farmMdex() internal {
        uint256 amount = IERC20(MDEX).balanceOf(address(this));
        if (amount > dust) {
            mdexMaster.deposit(mpid, amount);
            totalStakingMdexAmount = totalStakingMdexAmount.add(amount);

            if (sharesTotal > 0) {
                accPerShareOfMdex = accPerShareOfMdex.add(amount.mul(1e12).div(sharesTotal));
            }
        }
    }

    function _withdrawMdex(uint256 _amount) internal {
        if (_amount == 0 || IERC20(MDEX).balanceOf(address(this)) >= _amount) return;
        uint256 _amt = _stakingMdex();
        if (_amount > _amt) {
            _amount = _amt;
        }
        mdexMaster.withdraw(mpid, _amount);
        totalStakingMdexAmount = totalStakingMdexAmount.sub(_amount);
    }

    function _claimMdex() internal {
        mdexMaster.withdraw(mpid, 0);
    }

    function _stakingCake() internal view returns(uint256) {
        (uint amount,) = cakeMaster.userInfo(cpid, address(this));
        return amount;
    }

    function _pendingCake() internal view returns(uint256) {
        return cakeMaster.pendingCake(cpid, address(this));
    }

    function _reawardCakeToMdex() internal returns(uint256) {
        uint256 amount = IERC20(CAKE).balanceOf(address(this));
        if (amount > dust) {
            _swap(MDEX, amount, _tokenPath(CAKE, MDEX), ROUTER);
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
        uint256 stakingAmount = _stakingCake();
        if (amount > stakingAmount) {
            amount = stakingAmount;
        }
        uint256 cakeBalance = IERC20(CAKE).balanceOf(address(this));
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

    function _swap(address token, uint256 amount, address[] memory path, address router) internal returns(uint256) {
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
}