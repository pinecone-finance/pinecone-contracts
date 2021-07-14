// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;
import "./libraries/MinterRole.sol";
import "./libraries/Address.sol";
import "./libraries/SafeMath.sol";
import "./helpers/Context.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IPancakeFactory.sol";
import "./interfaces/IPineconeToken.sol";

contract PineconeToken is Context, IERC20, MinterRole {
    using SafeMath for uint256;
    using Address for address;

    address public vaultWallet;
    address public pctPair;
    IPancakeRouter02 public router;

    uint256 public buyFee = 500; // 5% 
    uint256 public transferFee = 1000; // 10%;
    uint256 public sellFee = 1000; // 10%

    uint256 public tokenHoldersPart = 4000; // 40%
    uint256 public lpPart = 4000; // 40%
    uint256 public burnPart = 1000; // 10%
    uint256 public vaultPart = 1000; // 10%

    uint256 public totalHoldersFee;
    uint256 public totalLpFee;
    uint256 public totalBurnFee;
    uint256 public totalVaultFee;

    uint256 public maxTxAmountPercent = 100; // 1%
    uint256 public tokensSellToAddToLiquidityPercent = 10; //0.1%
    bool public swapAndLiquifyEnabled = true;

    address[] public callees;
    mapping(address => bool) private mapCallees;

    address[] public pairs;
    mapping(address => bool) private mapPairs;

    address private _owner;
    uint256 private constant FEEMAX = 10000;
    mapping (address => uint256) private _rOwned;
    mapping (address => uint256) private _tOwned;
    mapping (address => mapping (address => uint256)) private _allowances;
    mapping (address => bool) private _isExcludedFromFee;
    mapping (address => bool) private _isExcluded;
    address[] private _excluded;

    uint256 private constant MAX = ~uint256(0);
    uint256 private _tTotal = 10**9 * 10**18;
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    uint256 private _totalSupply;

    string private _name = "Pinecone Token";
    string private _symbol = "PCT";
    uint8 private _decimals = 18;

    bool private _inSwapAndLiquify;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Addresses that excluded from antiWhale
    mapping(address => bool) private _excludedFromAntiWhale;

    struct OneBlockTxInfo {
        uint256 blockNumber;
        uint256 accTxAmt;
    }

    mapping(address => OneBlockTxInfo) private _userOneBlockTxInfo; //anti flashloan
    mapping(address => uint256) private _presaleUsers;

    address public presaleAddress;

    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );

    event TxFee(
        uint256 tFee,
        address from,
        address to
    );

    modifier onlyOwner() 
    {
        require(msg.sender == _owner, "!owner");
        _;
    }

    modifier onlyPresaleContract()
    {
        require(msg.sender == presaleAddress || msg.sender == _owner, "!presale contract");
        _;
    }

    modifier lockTheSwap {
        _inSwapAndLiquify = true;
        _;
        _inSwapAndLiquify = false;
    }

    constructor(address payable _routerAddr) public {
        _rOwned[address(0)] = _rTotal;
        _owner = msg.sender;
        vaultWallet = msg.sender;
        IPancakeRouter02 _router = IPancakeRouter02(_routerAddr);
        router = _router;
        IPancakeFactory _factory = IPancakeFactory(_router.factory());
        pctPair = _factory.createPair(address(this), _router.WETH());
        require(pctPair != address(0), "create pct pair false!");
        addPair(pctPair);
        excludeFromReward(DEAD);
        excludeFromReward(address(this));
        _isExcludedFromFee[_owner] = true;
        _isExcludedFromFee[address(this)] = true;
        _approve(address(this), address(_router), uint256(~0));

        _excludedFromAntiWhale[msg.sender] = true;
        _excludedFromAntiWhale[address(0)] = true;
        _excludedFromAntiWhale[address(this)] = true;
        _excludedFromAntiWhale[DEAD] = true;
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function maxSupply() public view returns(uint256) {
        return _tTotal;
    }

    function setOwner(address newOwner) public onlyOwner {
        require(newOwner != address(0), "newOwner is zero-address");
        require(newOwner != _owner, "newOwner is the same");
        _owner = newOwner;
    }

    function owner() public view returns(address) {
        return _owner;
    }

    function setVaultWallet(address account) external onlyOwner {
        require(account != address(0), "Vault wallet is zero-address");
        require(account != vaultWallet, "Vault wallet is the same");
        vaultWallet = account;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address from, address spender) public view override returns (uint256) {
        return _allowances[from][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function isExcludedFromReward(address account) public view returns (bool) {
        return _isExcluded[account];
    }

    function isExcludedFromFee(address account) public view returns(bool) {
        return _isExcludedFromFee[account];
    }

    function presaleUserUnlockTime(address account) public view returns(uint256) {
        return _presaleUsers[account];
    }

    function addPresaleUser(address account) public onlyPresaleContract {
        _presaleUsers[account] = block.timestamp + 30 days;
    }

    function isPresaleUser(address account) public view returns(bool) {
        uint256 unlockTime = _presaleUsers[account]; 
        if (unlockTime == 0 || unlockTime > block.timestamp) {
            return false;
        }

        return true;
    }

    function setPresaleContract(address addr) public onlyOwner {
        presaleAddress = addr;
    }

    //tType: 0 buy fee, 1 transfer fee, 2 sell fee, 3 no fee
    function reflectionFromToken(uint256 tAmount, uint256 tType) public view returns(uint256) {
        require(tAmount <= maxSupply(), "Amount must be less than max supply");
        uint256 txFee = 0;
        if (tType == 0) {
            txFee = buyFee;
        } else if (tType == 1) {
            txFee = transferFee;
        } else if (tType == 2) {
            txFee = sellFee;
        }
        (,uint256 rTransferAmount,,,) = _getValues(tAmount, txFee);
        return rTransferAmount;
    }

    function tokenFromReflection(uint256 rAmount) public view returns(uint256) {
        require(rAmount <= _rTotal, "Amount must be less than total reflections");
        uint256 currentRate =  _getRate();
        return rAmount.div(currentRate);
    }

    function excludeFromReward(address account) public onlyOwner {
        require(!_isExcluded[account], "Account is already excluded");
        if(_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }

    function includeInReward(address account) external onlyOwner {
        require(_isExcluded[account], "Account is already included");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0;
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }
    }
    
    function excludeFromFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = true;
    }
    
    function includeInFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = false;
    }
    
    function setTxFee(uint256 _buyFee, uint256 _transferFee, uint256 _sellFee) external onlyOwner {
        require(_buyFee < FEEMAX, "buy fee must less than FEEMAX");
        require(_transferFee < FEEMAX, "transfer fee must less than FEEMAX");
        require(_sellFee < FEEMAX, "sell fee must less than FEEMAX");
        buyFee = _buyFee;
        transferFee = _transferFee;
        sellFee = _sellFee;
    }

    function setMaxTxAmountPercent(uint256 percent) external onlyOwner {
        require(percent < FEEMAX, "max tx amount percent must be less than FEEMAX");
        maxTxAmountPercent = percent;
    }

    function setTokensSellToAddToLiquidityPercent(uint256 percent) external onlyOwner {
        require(percent < FEEMAX, "percent must be less than FEEMAX");
        tokensSellToAddToLiquidityPercent = percent;
    }

    function setSwapAndLiquifyEnabled(bool enabled) public onlyOwner {
        swapAndLiquifyEnabled = enabled;
    }

    function maxTxAmount() public view returns(uint256) {
        return _totalSupply.mul(maxTxAmountPercent).div(FEEMAX);
    }

    function numTokensSellToAddToLiquidity() public view returns(uint256) {
        return _totalSupply.mul(tokensSellToAddToLiquidityPercent).div(FEEMAX);
    }

    function isExcludedFromAntiWhale(address _account) public view returns (bool) {
        return _excludedFromAntiWhale[_account];
    }

    function setExcludedFromAntiWhale(address _account, bool _exclude) public onlyOwner {
        _excludedFromAntiWhale[_account] = _exclude;
    }

    function addPair(address pair) public onlyOwner {
        require(!isPair(pair), "Pair exist");
        require(pairs.length < 25, "Maximum 25 LP Pairs reached");
        mapPairs[pair] = true;
        pairs.push(pair);
        excludeFromReward(pair);
    }

    function isPair(address pair) public view returns (bool) {
        return mapPairs[pair];
    }

    function pairsLength() public view returns (uint256) {
        return pairs.length;
    }

    function addCallee(address callee) public onlyOwner {
        require(!isCallee(callee), "Callee exist");
        require(callees.length < 10, "Maximum 10 callees reached");
        mapCallees[callee] = true;
        callees.push(callee);
    }

    function removeCallee(address callee) public onlyOwner {
        require(isCallee(callee), "Callee not exist");
        mapCallees[callee] = false;
        for (uint256 i = 0; i < callees.length; i++) {
            if (callees[i] == callee) {
                callees[i] = callees[callees.length - 1];
                callees.pop();
                break;
            }
        }
    }

    function isCallee(address callee) public view returns (bool) {
        return mapCallees[callee];
    }

    function calleesLength() public view returns(uint256) {
        return callees.length;
    }

    function mint(address to, uint256 amount) public onlyMinter {
        if (amount == 0) {
            return;
        }

        uint256 supply = totalSupply();
        uint256 _maxSupply = maxSupply();
        if (supply >= _maxSupply) {
            return;
        }

        uint256 temp = supply.add(amount);
        if (temp > _maxSupply) {
            amount = _maxSupply.sub(supply);
        }
        _mint(to, amount);
    }

    function _mint(address account, uint256 amount) private {
        require(account != address(0), "ERC20: mint to the zero address");
        _totalSupply = _totalSupply.add(amount);

        (uint256 rAmount,,,,) = _getValues(amount, 0);
        _rOwned[address(0)] = _rOwned[address(0)].sub(rAmount);
        _rOwned[account] = _rOwned[account].add(rAmount);
        _tOwned[account] = _tOwned[account].add(amount);

        emit Transfer(address(0), account, amount);
        _transferCallee(address(0), account);
    }

    function mintAvailable() public view returns(bool) {
        if (totalSupply() >= maxSupply()) {
            return false;
        }
        return true;
    }
    
     //to recieve ETH from uniswapV2Router when swaping
    receive() external payable {}

    /**
     * @dev No timelock functions
     */
    function withdrawBNB() public payable onlyOwner {
        msg.sender.transfer(address(this).balance);
    }

    function withdrawBEP20(address _tokenAddress) public payable onlyOwner {
        uint256 tokenBal = IERC20(_tokenAddress).balanceOf(address(this));
        IERC20(_tokenAddress).transfer(msg.sender, tokenBal);
    }

    function _transferCallee(address from, address to) private {
        for (uint256 i = 0; i < callees.length; ++i) {
            address callee = callees[i];
            IPineconeTokenCallee(callee).transferCallee(from, to);
        }
    }

    function _calculateTxFee(uint256 amount, uint256 tFee) private pure returns (uint256) {
        return amount.mul(tFee).div(FEEMAX);
    }

    function _approve(address from, address spender, uint256 amount) private {
        require(from != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[from][spender] = amount;
        emit Approval(from, spender, amount);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) private {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");

        uint256 bal = balanceOf(from);
        if (amount > bal) {
            amount = bal;
        }

        // is the token balance of this contract address over the min number of
        // tokens that we need to initiate a swap + liquidity lock?
        // also, don't get caught in a circular liquidity event.
        // also, don't swap & liquify if sender is uniswap pair.
        uint256 contractTokenBalance = balanceOf(address(this));
        
        uint256 _maxTxAmount = maxTxAmount();
        if (isExcludedFromAntiWhale(from) == false && isExcludedFromAntiWhale(to) == false) {
            OneBlockTxInfo storage info = _userOneBlockTxInfo[from];
            //anti flashloan
            if (info.blockNumber != block.number) {
                info.blockNumber = block.number;
                info.accTxAmt = amount;
            } else {
                info.accTxAmt = info.accTxAmt.add(amount);
            }

            require(info.accTxAmt <= _maxTxAmount, "Transfer amount exceeds the maxTxAmount.");
            if(contractTokenBalance > _maxTxAmount) {
                contractTokenBalance = _maxTxAmount;
            }
        }
        
        uint256 _numTokensSellToAddToLiquidity = numTokensSellToAddToLiquidity();
        bool overMinTokenBalance = contractTokenBalance >= _numTokensSellToAddToLiquidity;
        if (
            overMinTokenBalance &&
            !_inSwapAndLiquify &&
            from != pctPair &&
            swapAndLiquifyEnabled
        ) {
            contractTokenBalance = _numTokensSellToAddToLiquidity;
            //add liquidity
            _swapAndLiquify(contractTokenBalance);
        }
        
        //indicates if fee should be deducted from transfer
        uint256 tFee = transferFee;
        //if any account belongs to _isExcludedFromFee account then remove the fee
        if(_isExcludedFromFee[from] || _isExcludedFromFee[to]) {
            tFee = 0;
        } else {
            if (isPresaleUser(from) || isPresaleUser(to)) {
                if (from == msg.sender && isPair(from)) { // buying
                    tFee = 0;
                } else if (isPair(to)) { // selling
                    tFee = sellFee / 2;
                } else {
                    tFee = 0;
                }
            } else {
                if (from == msg.sender && isPair(from)) {// buying
                    tFee = buyFee;
                } else if (isPair(to)) {// selling
                    tFee = sellFee;
                }
            }
        }
        emit TxFee(tFee, from, to);
        //transfer amount, it will take tax, burn, liquidity, vault fee
        _tokenTransfer(from,to,amount,tFee);
    }

    function _swapAndLiquify(uint256 contractTokenBalance) private lockTheSwap {
        // split the contract balance into halves
        uint256 half = contractTokenBalance.div(2);
        uint256 otherHalf = contractTokenBalance.sub(half);

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH
        _swapTokensForEth(half); // <- this breaks the ETH -> HATE swap when swap+liquify is triggered

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // add liquidity to uniswap
        _addLiquidity(otherHalf, newBalance);
        
        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function _swapTokensForEth(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        // make the swap
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // add the liquidity
        router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            owner(),
            block.timestamp
        );
    }

    function _getValues(uint256 tAmount, uint256 tFee) private view returns (uint256, uint256, uint256, uint256, uint256) {
        (uint256 tTransferAmount, uint256 tFeeAmount) = _getTValues(tAmount, tFee);
        uint256 currentRate = _getRate();
        (uint256 rAmount, uint256 rTransferAmount) = _getRValues(tAmount, tFeeAmount, currentRate);
        return (rAmount, rTransferAmount, tTransferAmount, tFeeAmount, currentRate);
    }

    function _getTValues(uint256 tAmount, uint256 tFee) private pure returns (uint256, uint256) {
        uint256 tFeeAmount = _calculateTxFee(tAmount, tFee);
        uint256 tTransferAmount = tAmount.sub(tFeeAmount);
        return (tTransferAmount, tFeeAmount);
    }

    function _getRValues(uint256 tAmount, uint256 tFeeAmount, uint256 currentRate) private pure returns (uint256, uint256) {
        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rFeeAmount = tFeeAmount.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rFeeAmount);
        return (rAmount, rTransferAmount);
    }

    function _getRate() private view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }

    function _getCurrentSupply() private view returns(uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;      
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _tTotal);
            rSupply = rSupply.sub(_rOwned[_excluded[i]]);
            tSupply = tSupply.sub(_tOwned[_excluded[i]]);
        }
        if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }

    //this method is responsible for taking all fee, if takeFee is true
    function _tokenTransfer(address sender, address recipient, uint256 amount, uint256 tFee) private {
        if (_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferFromExcluded(sender, recipient, amount, tFee);
        } else if (!_isExcluded[sender] && _isExcluded[recipient]) {
            _transferToExcluded(sender, recipient, amount, tFee);
        } else if (_isExcluded[sender] && _isExcluded[recipient]) {
            _transferBothExcluded(sender, recipient, amount, tFee);
        } else {
            _transferStandard(sender, recipient, amount, tFee);
        }
    }

    function _transferBothExcluded(address sender, address recipient, uint256 tAmount, uint256 tFee) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 tTransferAmount, uint256 tFeeAmount, uint256 currentRate) = _getValues(tAmount, tFee);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);        
        _takeTxFee(currentRate, tFeeAmount);
        emit Transfer(sender, recipient, tTransferAmount);
        _transferCallee(sender, recipient);
    }

    function _transferStandard(address sender, address recipient, uint256 tAmount, uint256 tFee) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 tTransferAmount, uint256 tFeeAmount, uint256 currentRate) = _getValues(tAmount, tFee);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeTxFee(currentRate, tFeeAmount);
        emit Transfer(sender, recipient, tTransferAmount);
        _transferCallee(sender, recipient);
    }

    function _transferToExcluded(address sender, address recipient, uint256 tAmount, uint256 tFee) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 tTransferAmount, uint256 tFeeAmount, uint256 currentRate) = _getValues(tAmount, tFee);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);           
        _takeTxFee(currentRate, tFeeAmount);
        emit Transfer(sender, recipient, tTransferAmount);
        _transferCallee(sender, recipient);
    }

    function _transferFromExcluded(address sender, address recipient, uint256 tAmount, uint256 tFee) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 tTransferAmount, uint256 tFeeAmount, uint256 currentRate) = _getValues(tAmount, tFee);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);   
        _takeTxFee(currentRate, tFeeAmount);
        emit Transfer(sender, recipient, tTransferAmount);
        _transferCallee(sender, recipient);
    }

    function _takeTxFee(uint256 currentRate, uint256 tFeeAmount) private {
        if (tFeeAmount == 0) return;

        uint256 holdersFee = tFeeAmount.mul(tokenHoldersPart).div(FEEMAX);
        uint256 rHolderFee = holdersFee.mul(currentRate);
        totalHoldersFee = totalHoldersFee.add(holdersFee);
        _rTotal = _rTotal.sub(rHolderFee);

        uint256 lpFee = tFeeAmount.mul(lpPart).div(FEEMAX);
        uint256 rLpFee = lpFee.mul(currentRate);
        totalLpFee = totalLpFee.add(lpFee);
        _transferFeeTo(address(this), rLpFee, lpFee);
        _transferCallee(address(0), address(this));

        uint256 burnFee = tFeeAmount.mul(burnPart).div(FEEMAX);
        uint256 rBurnFee = burnFee.mul(currentRate);
        totalBurnFee = totalBurnFee.add(burnFee);
        _transferFeeTo(DEAD, rBurnFee, burnFee);
        _transferCallee(address(0), DEAD);

        uint256 vaultFee = tFeeAmount.sub(holdersFee).sub(lpFee).sub(burnFee);
        uint256 rVaultFee = vaultFee.mul(currentRate);
        totalVaultFee = totalVaultFee.add(vaultFee);
        _transferFeeTo(vaultWallet, rVaultFee, vaultFee);
    }

    function _transferFeeTo(address to, uint256 rAmount, uint256 tAmount) private {
        _rOwned[to] = _rOwned[to].add(rAmount);
        if(_isExcluded[to])
            _tOwned[to] = _tOwned[to].add(tAmount);
    }
}