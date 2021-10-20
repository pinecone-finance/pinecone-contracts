// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "../libraries/SafeMath.sol";
import "../libraries/SafeERC20.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/IPancakeRouter02.sol";
import "../interfaces/IWNativeRelayer.sol";
import "../interfaces/IPineconeConfig.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract GridTrading is OwnableUpgradeable, PausableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    mapping(address => bool) public traderList;
    mapping(address => bool) public whiteList;

    address public constant wNativeRelayer = 0xdCBd8c36FE9542DbadD347d6170d3FD415C5aef5;
    IPineconeConfig public constant config = IPineconeConfig(0x03fE99931FB3B57F787A2e87bf93cD1a4CeFE1Cb);

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address private constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    uint256 public depositBNBAmt;

    event Swap(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _amountOut);

    modifier onlyWhiteList {
        require(whiteList[msg.sender] == true, "no auth sender!");
        _;
    }

    modifier onlyTraderList {
        require(traderList[msg.sender] == true, "no auth trader!");
        _;
    }

    function initialize() external initializer {
        __Ownable_init();
        whiteList[msg.sender] = true;
        traderList[msg.sender] = true;
        safeApprove(WBNB, ROUTER);
        safeApprove(CAKE, ROUTER);
        safeApprove(BUSD, ROUTER);

        depositBNBAmt = 0;
    }

    function safeApprove(address _token, address _router) public {
        _safeApprove(_token, _router);
    }

    function balanceOf(address _token) public view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }
    
    function setWhiteList(address _account, bool _enable) external onlyOwner {
        whiteList[_account] = _enable;
    }

    function setTraderList(address _account, bool _enable) external onlyOwner {
        traderList[_account] = _enable;
    }

    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    function depositBNB(uint256 _amount) public payable onlyWhiteList {
        require(msg.value == _amount, "_amount != msg.value");
        IWETH(WBNB).deposit{value: msg.value}();
        depositBNBAmt = depositBNBAmt.add(_amount);
    }

    function depositWBNB(uint256 _amount) public onlyWhiteList {
        IERC20(WBNB).safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        depositBNBAmt = depositBNBAmt.add(_amount);
    }

    function withdrawBNB(address payable _to, uint256 _amount) public payable onlyWhiteList {
        depositBNBAmt = depositBNBAmt.sub(_amount);

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
    }

    function withdrawBEP20(address _tokenAddress, address _to, uint256 _amount) public payable onlyWhiteList {
        if (_tokenAddress == WBNB) {
            depositBNBAmt = depositBNBAmt.sub(_amount);
        }

        uint256 tokenBal = IERC20(_tokenAddress).balanceOf(address(this));
        if (_amount > tokenBal) {
            _amount = tokenBal;
        }
        IERC20(_tokenAddress).transfer(_to, _amount);
    }

    function swap(address _tokenIn, address _tokenOut, uint256 _amountIn) public whenNotPaused onlyTraderList {
        require(_tokenIn == WBNB  || _tokenIn == CAKE || _tokenIn == BUSD, "invalid tokenIn");
        require(_tokenOut == WBNB || _tokenOut == CAKE || _tokenOut == BUSD, "invalid tokenOut");

        uint256 amt = balanceOf(_tokenIn);
        if (_amountIn > amt) {
            _amountIn = amt;
        }
        require(_amountIn > 0, "_amountIn == 0");
        
        address[] memory  path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;

        uint256 before = balanceOf(_tokenOut);

        IPancakeRouter02(ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amountIn,
            0,
            path,
            address(this),
            now + 60
        );

        uint256 amountOut = balanceOf(_tokenOut).sub(before);
        emit Swap(_tokenIn, _tokenOut, _amountIn, amountOut);
    }

    function balance() public view returns(uint256 bnbAmt, uint256 cakeAmt, uint256 busdAmt) {
        bnbAmt = address(this).balance;
        bnbAmt = bnbAmt.add(balanceOf(WBNB));
        cakeAmt = balanceOf(CAKE);
        busdAmt = balanceOf(BUSD);
    }

    function info() public view returns(
        uint256 depositedBNB,
        uint256 bnbAmt, 
        uint256 cakeAmt, 
        uint256 busdAmt,
        uint256 swapBnbAmt

    ) {
        (bnbAmt, cakeAmt, busdAmt) = balance();
        depositedBNB = depositBNBAmt;
        swapBnbAmt = config.getAmountsOut(cakeAmt, CAKE, WBNB);
        swapBnbAmt = swapBnbAmt.add(config.getAmountsOut(busdAmt, BUSD, WBNB));
    }

    function _safeApprove(address _token, address _spender) internal {
        if (_token != address(0) && IERC20(_token).allowance(address(this), _spender) == 0) {
            IERC20(_token).safeApprove(_spender, uint256(~0));
        }
    }

    function _safeTransfer(address _token, address _to, uint256 _amount) internal {
        if (_amount == 0) return;
        IERC20(_token).safeTransfer(_to, _amount);
    }

    receive() external payable {}
}