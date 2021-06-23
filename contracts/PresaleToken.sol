// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "./helpers/ERC20.sol";
import "./libraries/SafeERC20.sol";
import "./helpers/Ownable.sol";
import "./helpers/ReentrancyGuard.sol";
import "./helpers/Pausable.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IPancakeFactory.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IPinecone.sol";

interface IPresaleBeneficiary
{
    function mintForPresale(address to, uint256 amount) external returns(uint256);
    function stakeForPresale(address to, uint256 amount) external;
}

contract PresaleToken is Ownable, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct AuctionInfo {
        uint256 startTime;              // start time
        uint256 deadline;               // auction deadline
        uint256 allocation;             // allocation per wallet
        uint256 tokenSupply;            // amount of the pre-sale token
        uint256 tokenRemain;            // remain of the pre-sale token
        uint256 perAmount;              // per amount of purchase
        address inToken;                // payment token eg. cake
        address outToken;               // exchange token eg. pct
        address lpToken;                // lp token
        address payable beneficiary;    // auction host
        bool archived;                  // flag to determine archived
        uint256 mintAmount;             // mint token amount
    }

    struct UserInfo {
        uint256 engaged;
    }

    AuctionInfo[] public auctions;
    mapping(uint256 => mapping(address => UserInfo)) public presaledUsers;

    address private constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    IPancakeFactory private constant factory = IPancakeFactory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    uint256 public startAid = 0;
    uint256 public endAid = 0;
    IPineconeFarm public pineconeFarm;

    event Create(uint256 indexed id, address indexed inToken, address indexed outToken);
    event Archive(uint256 indexed id);
    event Purchase(
        uint256 indexed id, 
        address indexed user, 
        uint256 inAmount,
        uint256 mintAmount, 
        uint256 lpAmount
    );

    receive() external payable {}

    function createAuction(
        uint256 startTime,
        uint256 deadline,
        uint256 allocation,
        uint256 perAmount,
        address payable beneficiary,
        address inToken,
        address outToken,
        uint256 tokenSupply

    ) external onlyOwner {
        require(startTime > now, "!startTime");
        require(deadline > now, "!deadline");
        require(deadline > startTime, "startTime <= deadline");
        require(allocation > 0, "!allocation");
        require(perAmount > 0, "!perAmount");
        require(beneficiary != address(0), "!beneficiary");

        require(inToken != address(0), "!inToken");
        require(outToken != address(0), "!outToken");
        require(tokenSupply > 0, "!tokenSupply");


        AuctionInfo memory request;
        request.startTime = startTime;
        request.deadline = deadline;
        request.allocation = allocation;
        request.perAmount = perAmount;
        request.beneficiary = beneficiary;
        request.inToken = inToken;
        request.outToken = outToken;
        request.tokenSupply = tokenSupply;
        request.tokenRemain = request.tokenSupply;
        request.archived = false;

        address pair = factory.getPair(inToken, outToken);
        if (pair == address(0)) {
            pair = factory.createPair(inToken, outToken);
            require(pair != address(0), "pair == address(0)");    
        }
        request.lpToken = pair;
        auctions.push(request);
        uint256 id = auctions.length - 1;
        emit Create(id, request.inToken, request.outToken);

        _safeApprove(request.inToken, ROUTER);
        _safeApprove(request.inToken, request.beneficiary);
        _safeApprove(request.outToken, ROUTER);
        _safeApprove(request.outToken, request.beneficiary);
    }

    function setActiveId(uint256 sid, uint256 eid) external onlyOwner {
        require(sid < auctions.length, "sid out of range");
        require(eid < auctions.length, "eid out of range");
        require(eid >= sid, "eid less than sid");
        
        startAid = sid;
        endAid = sid;
    }

    function archive(uint256 id) external onlyOwner {
        require(id < auctions.length, "id out of range");

        AuctionInfo storage auction = auctions[id];
        auction.archived = true;
    }

    function setPineconeFarm(address addr) external onlyOwner {
        pineconeFarm = IPineconeFarm(addr);
    }

    function purchase(uint256 id) public payable whenNotPaused nonReentrant {
        require(id < auctions.length, "id out of range");

        AuctionInfo storage auction = auctions[id];
        require(now >= auction.startTime, "startTime <= now");
        require(!auction.archived, "archived");
        require(now < auction.deadline, "deadline");
        require(auction.tokenRemain > 0, "no shares");

        UserInfo storage user = presaledUsers[id][msg.sender];
        require(user.engaged < auction.allocation, "engaged >= allocation");

        uint256 leftAmt = auction.perAmount;
        if (auction.tokenRemain < leftAmt) {
            leftAmt = auction.tokenRemain;
        }

        if (leftAmt + user.engaged > auction.allocation) {
            leftAmt = auction.allocation.sub(user.engaged);
        }

        user.engaged = user.engaged.add(leftAmt);
        auction.tokenRemain = auction.tokenRemain.sub(leftAmt);

        if (auction.inToken == WBNB) {
            require(leftAmt == msg.value, "leftAmt != msg.value");
            IWETH(WBNB).deposit{value: msg.value}();
        } else {
            IERC20(auction.inToken).safeTransferFrom(
                address(msg.sender),
                address(this),
                leftAmt
            );
        }

        (uint256 mintAmount, uint256 lpAmount) = _mint(auction, msg.sender, leftAmt);
        auction.mintAmount = auction.mintAmount.add(mintAmount);

        emit Purchase(id, msg.sender, leftAmt, mintAmount, lpAmount);
    }

    function _mint(AuctionInfo memory auction, address user, uint256 inAmt) private returns(uint256 mintAmount, uint256 lpAmount) {
        uint256 profit = inAmt.mul(3).div(2);
        mintAmount = IPresaleBeneficiary(auction.beneficiary).mintForPresale(address(this), profit);
        uint256 token0Amt = inAmt.div(2);
        uint256 token1Amt = mintAmount.div(3);
        IPancakeRouter02(ROUTER).addLiquidity(
            auction.inToken,
            auction.outToken,
            token0Amt,
            token1Amt,
            0,
            0,
            address(this),
            now + 60
        );

        lpAmount = IERC20(auction.lpToken).balanceOf(address(this));
        IERC20(auction.lpToken).safeTransfer(owner(), lpAmount);
        uint256 realAmt = mintAmount.sub(token1Amt);
        IERC20(auction.outToken).safeTransfer(user, realAmt);

        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = CAKE;
        uint256 bnbAmount = inAmt.sub(token0Amt);
        uint256 cakeAmount = _swap(CAKE, bnbAmount, path);
        _safeApprove(WBNB, ROUTER);
        _safeApprove(CAKE, ROUTER);
        IPresaleBeneficiary(auction.beneficiary).stakeForPresale(auction.beneficiary, cakeAmount);
    }

    function presaleInfo() public view returns(uint256 mintAmount, uint256 deadline) {
        mintAmount = 0;
        deadline = 0;

        if (auctions.length > 0) {
            for (uint256 i = startAid; i <= endAid; ++i) {
                mintAmount = mintAmount.add(auctions[i].mintAmount);
            }

            deadline = auctions[endAid].deadline;
        }
    }


    function auctionLength() public view returns(uint256) {
        return auctions.length;
    }

    function _safeApprove(address token, address spender) internal {
        if (token != address(0) && IERC20(token).allowance(address(this), spender) == 0) {
            IERC20(token).safeApprove(spender, uint256(~0));
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

    function withdrawBNB(address payable _to) public payable onlyOwner {
        _to.transfer(address(this).balance);
    }

    function withdrawBEP20(address _tokenAddress, address _to) public payable onlyOwner {
        uint256 tokenBal = IERC20(_tokenAddress).balanceOf(address(this));
        IERC20(_tokenAddress).transfer(_to, tokenBal);
    }

    function claimDUSTBNB(address payable _to) public payable onlyOwner {
        pineconeFarm.claimBNB();
        _to.transfer(address(this).balance);
    }
}
