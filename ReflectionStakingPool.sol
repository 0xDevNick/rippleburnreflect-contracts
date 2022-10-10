// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./utilities/TransferHelper.sol";
import "./interfaces/IPancakeRouter.sol";
import "./interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract ReflectionStakingPool is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Users must be tracked in an iterable format
    EnumerableSet.AddressSet private userSet;

    // Track balance by address
    mapping(address => uint256) private stakedBalances;

    // Track total staked tokens
    uint256 public totalStaked;

    // Define stakable/reward tokens
    address public tokenToBuy;
    address public tokenToSell;

    // Router informaton
    IPancakeRouter02 private _pancakeRouter;

    // Fee to withdraw staked tokens (value out of 1000; i.e. 50 = 5%)
    uint256 public withdrawFee;

    /* Bounty paid to wallet that triggers swap (value out of 1000; i.e. 50 = 5%)
       Incentivizes users to trigger swap if enough rewards have accumulated which
       allows swaps to remain consistent.
    */
    uint256 public triggerBounty;

    /* Events */
    event onSwap(address triggerer, uint256 amount);

    // Settings for staking RippleBurnReflect with XRP rewards
    constructor() {
        // Default: RippleBurnReflect
        tokenToBuy = 0x77282DF2E846A641530f08cf3988602884218d39;
        // Default: XRP (BSC)
        tokenToSell = 0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE;

        // PancakeSwap v2 Router
        _pancakeRouter = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

        withdrawFee = 0; // 0%
        triggerBounty = 5; // 0.5%
    }

    /* Internal Helper Functions */
    function rewardsInContract() internal view returns(uint256) {
        return IERC20(tokenToSell).balanceOf(address(this));
    }

    /* External Helper Functions */
    function getContractRewards() external view returns(uint256) {
        return IERC20(tokenToSell).balanceOf(address(this));
    }

    function getNumUsers() external view returns(uint256) {
        return userSet.length();
    }

    function getStakeForUser(address _user) external view returns(uint256) {
        return stakedBalances[_user];
    }

    function setWithdrawFee(uint256 _withdrawFee) external onlyOwner {
        require(_withdrawFee < 50, "Withdraw fee cannot exceed 5%!");

        withdrawFee = _withdrawFee;
    }

    function setTriggerBounty(uint256 _triggerBounty) external onlyOwner {
        require(_triggerBounty < 15, "Trigger bounty cannot exceed 1.5%!");

        triggerBounty = _triggerBounty;
    }

    function setTokenToSell(address _token) external onlyOwner {
        tokenToSell = _token;
    }

    /* Function to convert sellable tokens in contract
       into the main staking token.
       
       i.e. Swap any XRP held in contract to RippleBurnReflect

       The `tokenToSell` value can be changed by owner in order
       to support selling any tokens sent to the contract and
       distributing the proceeds among the current stakers.
    */
    function swapTokens() external {
        uint256 balanceInContract = rewardsInContract();

        require(balanceInContract > 0, "Contract holds no swappable tokens!");

        // If trigger bounty is enabled, pay msg.sender.
        if (triggerBounty > 0) {
            uint256 bountyPaid = balanceInContract.mul(triggerBounty).div(1000);

            // Send remaining tokens to msg.sender.
            TransferHelper.safeTransfer(tokenToSell, msg.sender, bountyPaid);
        }

        // Recalculate balance after bounty.
        balanceInContract = rewardsInContract();

        // Approve router to swap tokens.
        IERC20(tokenToSell).approve(
            address(_pancakeRouter),
            balanceInContract
        );

        // Initialize router path through BNB (i.e. XRP > WBNB > RBR)
        address[] memory path = new address[](3);
        path[0] = address(tokenToSell);
        path[1] = _pancakeRouter.WETH();
        path[2] = address(tokenToBuy);

        // Record contract balance before swap
        uint256 initialBalance = IERC20(tokenToBuy).balanceOf(address(this));

        /* Trigger swap through PancakeSwap router.
           This call allows for a token tax of up to
           20% on a contract. Anything higher will
           fail.
        */
        _pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            balanceInContract,
            balanceInContract.mul(80).div(100),
            path,
            address(this),
            (block.timestamp + 1 hours)
        );

        // Record new balance after swap
        uint256 newBalance = IERC20(tokenToBuy).balanceOf(address(this));   

        // Calculate difference to get exact number of tokens purchased.
        uint256 purchasedTokens = newBalance.sub(initialBalance);

        /* Iterate through all current stakers and allocate purchased
           tokens according to the proportional share of the pool
           the staker owns.
        */
        for (uint i = 0; i < userSet.length(); i++) {
            uint256 currentBalance = stakedBalances[userSet.at(i)];
            stakedBalances[userSet.at(i)] =
            currentBalance.add(
                purchasedTokens.mul(currentBalance).div(totalStaked)
            );
        }

        // Increment `totalStaked` by new tokens purchased.
        totalStaked = totalStaked.add(purchasedTokens);

        emit onSwap(
            msg.sender,
            purchasedTokens
        );
    }

    // Function to stake specified tokens in the pool (i.e. RippleBurnReflect)
    function depositStake(uint256 _amount) external payable nonReentrant {
        require(_amount > 0, "Cannot stake less than 0 tokens");
        require(IERC20(tokenToBuy).balanceOf(msg.sender) > 0, "Nothing to stake!");

        // Take snapshot of contract balance before transfer.
        uint256 initialBalance = IERC20(tokenToBuy).balanceOf(address(this));

        // Transfer tokens to contract.
        TransferHelper.safeTransferFrom(tokenToBuy, address(msg.sender), address(this), _amount);

        // Take snapshot of contract balance after transfer to account for transfer tax.
        uint256 newBalance = IERC20(tokenToBuy).balanceOf(address(this));

        uint256 stakedTokens = newBalance.sub(initialBalance);

        // Increment `totalStaked` by received tokens
        totalStaked = totalStaked.add(stakedTokens);

        // Add user to EnumerableSet and track sent tokens
        userSet.add(msg.sender);
        stakedBalances[msg.sender] = stakedTokens;
    }

    // Function to withdraw any staked and accumulated tokens from the pool.
    function withdrawStake(uint256 _amount) external nonReentrant {
        require(stakedBalances[msg.sender] > 0, "Nothing to unstake!");
        require(stakedBalances[msg.sender].sub(_amount) > 0, "Cannot more tokens than staked!");
        require(_amount > 0, "Must withdraw more than zero!");

        // Calculate tokens to burn and tokens to send to msg.sender.
        uint256 amountToBurn = _amount.mul(withdrawFee).div(1000);
        uint256 amountToWithdraw = _amount.sub(amountToBurn);

        // Only trigger if any tokens will be burned.
        if (amountToBurn > 0) {
            // Burn fee
            TransferHelper.safeTransfer(tokenToBuy, address(0x000000000000000000000000000000000000dEaD), amountToBurn);
        }

        // Send remaining tokens to msg.sender.
        TransferHelper.safeTransfer(tokenToBuy, msg.sender, amountToWithdraw);

        // Subtract withdrawn tokens from user balance.
        stakedBalances[msg.sender] = stakedBalances[msg.sender].sub(_amount);

        // If user no longer has any stake remaining, remove them from EnumerableSet.
        if (stakedBalances[msg.sender] == 0) {
            userSet.remove(msg.sender);
        }

        // Decrement `totalStaked` based on withdrawn tokens.
        totalStaked = totalStaked.sub(_amount);
    }

}