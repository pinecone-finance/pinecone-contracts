// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./TokenBase.sol";

contract TokenAuth is TokenBase {
    mapping(address => bool) public authSenders;
    mapping(address => bool) public authRecipients;

    function __TokenAuth_init() internal initializer {
        __TokenBase_init();
        authSenders[msg.sender] = true;
        authRecipients[msg.sender] = true;
    }

    modifier onlyAuthSenders() {
        require(authSenders[msg.sender] == true, "TokenAuth: no auth sender");
        _;
    }

    function setAuthSender(address _account, bool _enable) external onlyOwner {
        authSenders[_account] = _enable;
    }

    function setAuthReceipients(address _account, bool _enable) external onlyOwner {
        authRecipients[_account] = _enable;
    }
}   