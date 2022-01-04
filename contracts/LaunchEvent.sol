// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IWAVAX.sol";
import "./interfaces/IJoeRouter02.sol";
import "./interfaces/IJoeFactory.sol";
import "./interfaces/IJoePair.sol";
import "./interfaces/IRocketJoeFactory.sol";

import "./RocketJoeToken.sol";

/// @title Rocket Joe Launch Event
/// @author traderjoexyz
/// @notice A liquidity launch contract enabling price discover and token distribution as secondary market listing price.
/// TODO: - if token hasn't 18 decimals, it needs some changes
///       - Calculate AVAX:rJOE ratio.
///       - give owner to issuer ?
///       - emergency withdraws
contract LaunchEvent is Ownable {
    /// @notice Issuer of that contract.
    address public issuer;

    /// @notice The start time of phase 1.
    uint256 public phaseOne;

    /// @notice The start time of phase 2.
    uint256 public phaseTwo;

    /// @notice The start time of phase 3.
    uint256 public phaseThree;

    /// @notice floor price (can be 0)
    uint256 public floorPrice;

    /// @notice When can user withdraw their LP (phase 3).
    uint256 public userTimelock;

    /// @notice When can issuer withdraw their LP (phase 3).
    uint256 public issuerTimelock;

    /// @notice The withdraw penalty gradient in “bps per sec”, in parts per 1e12 (phase 1).
    /// e.g. linearly reach 50% in 2 days `withdrawPenaltyGradient = 50 * 100 * 1e12 / 2 days`
    uint256 public withdrawPenaltyGradient;

    /// @notice The fixed withdraw penalty, in parts per 1e12 (phase 2).
    /// e.g. fixed penalty of 20% `fixedWithdrawPenalty = 20e11`
    uint256 public fixedWithdrawPenalty;

    /// @dev rJOE token contract.
    RocketJoeToken public rJoe;
    /// @dev WAVAX token contract.
    IWAVAX public WAVAX;
    /// @dev THE token contract.
    IERC20 public token;

    /// @dev Joe Router contract.
    IJoeRouter02 router;
    /// @dev Joe Factory contract.
    IJoeFactory factory;
    /// @dev Rocket Joe Factory contract.
    IRocketJoeFactory rocketJoeFactory;

    /// @dev internal state variable for paused
    bool internal isPaused;

    /// @dev max and min allocation limits.
    uint256 public minAllocation;
    uint256 public maxAllocation;

    /// @dev struct used to record a users allocation and allocation used.
    struct UserAllocation {
        uint256 allocation;
        uint256 pairPoolWithdrawn;
    }
    /// @dev mapping of users to allocation record.
    mapping(address => UserAllocation) public users;

    /// @dev the address of the uniswap pair. Only set after createLiquidityPool is called.
    IJoePair public pair;

    /// @dev pool information
    uint256 public avaxAllocated;
    uint256 public tokenAllocated;
    uint256 public lpSupply;

    uint256 public tokenReserve;

    /// Constructor

    constructor() {
        rocketJoeFactory = IRocketJoeFactory(msg.sender);
        WAVAX = IWAVAX(rocketJoeFactory.wavax());
        router = IJoeRouter02(rocketJoeFactory.router());
        factory = IJoeFactory(rocketJoeFactory.factory());
        rJoe = RocketJoeToken(rocketJoeFactory.rJoe());
    }

    function initialize(
        address _issuer,
        uint256 _phaseOne,
        address _token,
        uint256 _floorPrice,
        uint256 _withdrawPenatlyGradient,
        uint256 _fixedWithdrawPenalty,
        uint256 _minAllocation,
        uint256 _maxAllocation,
        uint256 _userTimelock,
        uint256 _issuerTimelock
    ) external {
        require(
            msg.sender == address(rocketJoeFactory),
            "LaunchEvent: forbidden"
        );
        require(_issuer != address(0), "LaunchEvent: Issuer is null address");
        require(
            _phaseOneStartTime >= block.timestamp,
            "LaunchEvent: phase 1 needs to start after the current timestamp"
        );
        require(
            _withdrawPenatlyGradient < 5e11 / uint256(2 days),
            "LaunchEvent: withdraw penalty gradient too big"
        ); /// 50%
        require(
            _fixedWithdrawPenalty < 5e11,
            "LaunchEvent: fixed withdraw penalty too big"
        ); /// 50%
        require(
            _maxAllocation >= _minAllocation,
            "LaunchEvent: max allocation needs to be greater than min's one"
        );
        require(
            _userTimelock < 7 days,
            "LaunchEvent: can't lock user LP for more than 7 days"
        );
        require(
            _issuerTimelock > _userTimelock,
            "LaunchEvent: issuer can't withdraw their LP before users"
        );

        issuer = _issuer;
        transferOwnership(issuer);
        /// Different time phases
        phaseOne = _phaseOne;
        phaseTwo = _phaseOne + 3 days;
        phaseThree = phaseTwo + 1 days;

        token = IERC20(_token);
        tokenReserve = token.balanceOf(address(this));
        floorPrice = _floorPrice;

        withdrawPenaltyGradient = _withdrawPenatlyGradient;
        fixedWithdrawPenalty = _fixedWithdrawPenalty;

        minAllocation = _minAllocation;
        maxAllocation = _maxAllocation;

        userTimelock = _userTimelock;
        issuerTimelock = _issuerTimelock;
    }

    /// Modifiers

    modifier notPaused() {
        require(isPaused != true, "LaunchEvent: paused");
        _;
    }

    /// Public functions.

    /// @notice Deposits AVAX and burns rJoe.
    /// @dev Checks are done in the `_depositWAVAX` function.
    function depositAVAX() external payable notPaused {
        require(
            block.timestamp >= phaseOne && block.timestamp < phaseTwo,
            "LaunchEvent: phase1 is over"
        );
        WAVAX.deposit{value: msg.value}();
        _depositWAVAX(msg.sender, msg.value); // checks are done here.
    }

    /// @dev withdraw AVAX only during phase 1 and 2.
    function withdrawWAVAX(uint256 amount) public notPaused {
        require(
            block.timestamp >= phaseOne && block.timestamp < phaseThree,
            "LaunchEvent: can't withdraw after phase2"
        );

        UserAllocation storage user = users[msg.sender];
        require(
            user.allocation >= amount,
            "LaunchEvent: withdrawn amount exceeds balance"
        );
        user.allocation = user.allocation - amount;

        uint256 feeAmount = (amount * getPenalty()) / 1e12;
        uint256 amountMinusFee = amount - feeAmount;

        WAVAX.withdraw(amount);

        safeTransferAVAX(msg.sender, amountMinusFee);
        if (feeAmount > 0) {
            safeTransferAVAX(penaltyCollector, feeAmount);
        }
    }

    /// @dev Needed for withdrawing from WAVAX contract.
    receive() external payable {}

    /// @dev Returns the current penalty
    function getPenalty() public view returns (uint256) {
        uint256 startedSince = block.timestamp - phaseOne;
        if (startedSince < 1 days) {
            return 0;
        } else if (startedSince < 3 days) {
            return (startedSince - 1 days) * withdrawPenaltyGradient;
        } else {
            return fixedWithdrawPenalty;
        }
        return fixedWithdrawPenalty;
    }

    /// @dev Returns the current balance of the pool
    function poolInfo() public view returns (uint256, uint256) {
        return (
            IERC20(address(WAVAX)).balanceOf(address(this)),
            token.balanceOf(address(this))
        );
    }

    /// @dev Create the uniswap pair, can be called by anyone but only once
    /// @dev but only once after phase 3 has started.
    function createPair() external notPaused {
        require(
            block.timestamp >= phaseThree,
            "LaunchEvent: not in phase three"
        );
        require(
            factory.getPair(address(WAVAX), address(token)) == address(0),
            "LaunchEvent: pair already created"
        );
        (address wavaxAddress, address tokenAddress) = (
            address(WAVAX),
            address(token)
        );
        (uint256 avaxBalance, uint256 tokenBalance) = poolInfo();

        if (floorPrice > (avaxBalance * 1e18) / tokenBalance) {
            tokenBalance = (avaxBalance * 1e18) / floorPrice;
        }

        IERC20(wavaxAddress).approve(address(router), ~uint256(0));
        IERC20(tokenAddress).approve(address(router), ~uint256(0));

        /// We can't trust the output cause of reflect tokens
        (, , lpSupply) = router.addLiquidity(
            tokenAddress,
            wavaxAddress,
            avaxBalance,
            tokenBalance,
            avaxBalance,
            tokenBalance,
            address(this),
            block.timestamp
        );

        pair = IJoePair(factory.getPair(tokenAddress, wavaxAddress));

        tokenAllocated = token.balanceOf(address(pair));
        avaxAllocated = IERC20(address(WAVAX)).balanceOf(address(pair));

        tokenReserve = tokenReserve - tokenAllocated;
    }

    /// @dev withdraw the liquidity pool tokens.
    function withdrawLiquidity() public notPaused {
        require(address(pair) != address(0), "LaunchEvent: pair is 0 address");
        require(
            block.timestamp > phaseThreeStartTime + userTimelock,
            "LaunchEvent: can't withdraw before user's timelock"
        );
        pair.transfer(msg.sender, pairBalance(msg.sender));

        if (tokenReserve > 0) {
            token.transfer(
                to,
                (users[to].allocation * tokenReserve) / avaxAllocated / 2
            );
        }
    }

    /// @dev withdraw the liquidity pool tokens, only for issuer.
    function withdrawIssuerLiquidity() public notPaused {
        require(address(pair) != address(0), "LaunchEvent: pair is 0 address");
        require(msg.sender == issuer, "LaunchEvent: caller is not Issuer");
        require(
            block.timestamp > phaseThree + issuerTimelock,
            "LaunchEvent: can't withdraw before issuer's timelock"
        );

        pair.transfer(issuer, avaxAllocated / 2);

        if (tokenReserve > 0) {
            token.transfer(issuer, (tokenReserve * 1e18) / avaxAllocated / 2);
        }
    }

    /// @dev get the allocation credits for this rjoe;
    /// @dev TODO: implement, currently just returns the allocation credits.
    function getAllocation(uint256 avaxAmount) public pure returns (uint256) {
        return avaxAmount / 1;
    }

    /// @dev The total amount of liquidity pool tokens the user can withdraw.
    function pairBalance(address _user) public view returns (uint256) {
        if (avaxAllocated == 0) {
            return 0;
        }

        return (users[_user].allocation * lpSupply) / avaxAllocated / 2;
    }

    /// Restricted functions.

    /// @dev Pause this contract
    function pause() external onlyOwner {
        isPaused = true;
    }

    /// @dev Unpause this contract
    function unpause() external onlyOwner {
        isPaused = false;
    }

    /// Internal functions.

    /// @dev Transfers `value` AVAX to address.
    function safeTransferAVAX(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "LaunchEvent: avax transfer failed");
    }

    /// @dev Transfers and burns all the rJoe.
    function burnRJoe(address from, uint256 rJoeAmount) internal {
        // TODO: Should we use SafeERC20
        rJoe.transferFrom(from, address(this), rJoeAmount);
        rJoe.burn(rJoeAmount);
    }

    /// @notice Use your allocation credits by sending WAVAX.
    function _depositWAVAX(address from, uint256 avaxAmount)
        internal
        notPaused
    {
        require(
            avaxAmount >= minAllocation,
            "LaunchEvent: amount doesnt fulfil min allocation"
        );

        UserAllocation storage user = users[from];
        require(
            user.allocation + avaxAmount <= maxAllocation,
            "LaunchEvent: amount exceeds max allocation"
        );

        burnRJoe(from, getAllocation(avaxAmount));

        user.allocation = user.allocation + avaxAmount;
    }
}
