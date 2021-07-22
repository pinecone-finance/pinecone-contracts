// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./libraries/SafeMath.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IPineconeConfig.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract VaultBase is OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public govAddress; // timelock contract
    address public devAddress; 

    uint256 public withdrawFeeFactor; // 0.5% fee for withdrawals within 3 days
    uint256 public constant withdrawFeeFactorUL = 50; // 0.5% is the max withdraw fee settable.
    uint256 public minDepositTimeWithNoFee;
    uint256 public commission; // commission on profits for mint pct
    uint256 public constant commissionUL = 3000; // max 30%
    uint256 public constant feeMax = 10000;

    IPineconeConfig public config;
    address public stratAddress;

    function _VaultBase_init(address _config, address _stratAddress) internal initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        withdrawFeeFactor = 50;
        minDepositTimeWithNoFee = 3 days;
        commission = 3000;
        devAddress = msg.sender;
        govAddress = msg.sender;
        config = IPineconeConfig(_config);
        stratAddress = _stratAddress;

        transferOwnership(address(config.pineconeFarm()));
    }

    modifier onlyGov() {
        require(msg.sender == govAddress, "!gov");
        _;
    }

    modifier onlyDev() {
        require(msg.sender == devAddress, "!dev");
        _;
    }

    /* ========== onlyDev ========== */
    function pause() onlyDev external {
        _pause();
    }

    function unpause() onlyDev external {
        _unpause();
    }

    function setDevAddress(address _devAddress) onlyDev public {
        devAddress = _devAddress;
    }

    function setCommission(uint256 _commission) onlyDev public {
        require(_commission <= commissionUL, "too high");
        commission = _commission;
    }

    function setConfig(address _config) onlyDev public {
        config = IPineconeConfig(_config);
    }

    /* ========== onlyGov ========== */
    function setGovAddress(address _govAddress) onlyGov public {
        govAddress = _govAddress;
    }

    function setWithdrawFeeFactor(uint256 _withdrawFeeFactor) onlyGov public {
        require(_withdrawFeeFactor <= withdrawFeeFactorUL, "too high");
        withdrawFeeFactor = _withdrawFeeFactor;
    }

    function setMinDepositTime(uint256 _minDepositTimeWithNoFee) public onlyGov {
        minDepositTimeWithNoFee = _minDepositTimeWithNoFee;
    }

    function performanceFee(uint256 _profit) public view returns(uint256) {
        return _profit.mul(commission).div(feeMax);
    }
}