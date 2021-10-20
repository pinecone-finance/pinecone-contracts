// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/SafeMath.sol";
import "../interfaces/IPIToken.sol";
import "./TokenBase.sol";

contract Escrow is TokenBase {
    using SafeMath for uint256;
    address public auth;

    function initialize(address _auth) external initializer {
        __TokenBase_init();
        auth = _auth;
    }

    modifier onlyAuth() {
        require(auth == msg.sender, "Escrow: no auth");
        _;
    }

    function setAuth(address _auth) external onlyOwner {
        require(_auth != address(0), "Escrow: invalid auth address");
        auth = _auth;
    }

    function transfer(address _token, address _to, uint256 _amount) public onlyAuth {
        require(_amount > 0 && balanceOfToken(_token) >= _amount, "Escrow: invalid amount");
        _safeTransfer(_token, _to, _amount);
    }
}

