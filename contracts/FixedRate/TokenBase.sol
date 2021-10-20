// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/SafeERC20.sol";
import "../interfaces/IWNativeRelayer.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract TokenBase is OwnableUpgradeable {
    using SafeERC20 for IERC20;

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public wNativeRelayer;

    event WithdrawBNB(address indexed _to, uint256 _amount);
    event WithdrawBEP20(address indexed _token, address indexed _to, uint256 _amount); 

    function __TokenBase_init() internal initializer {
        __Ownable_init();
    }

    function balanceOfToken(address _token) public view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    function withdrawBNB(address payable _to, uint256 _amount) public payable onlyOwner {
        if (address(this).balance >= _amount) {
            SafeERC20.safeTransferETH(_to, _amount);
            return;
        }

        uint256 amount = IERC20(WBNB).balanceOf(address(this));
        if (_amount > amount) {
            _amount = amount;
        }

        IERC20(WBNB).safeTransfer(wNativeRelayer, _amount);
        IWNativeRelayer(wNativeRelayer).withdraw(_amount);
        SafeERC20.safeTransferETH(_to, _amount);
        emit WithdrawBNB(_to, _amount);
    }

    function withdrawBEP20(address _token, address _to, uint256 _amount) public payable onlyOwner {
        uint256 tokenBal = IERC20(_token).balanceOf(address(this));
        if (_amount > tokenBal) {
            _amount = tokenBal;
        }
        IERC20(_token).transfer(_to, _amount);
        emit WithdrawBEP20(_token, _to, _amount);
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
}