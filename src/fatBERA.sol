// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract fatBERA is ERC4626Upgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;
    /*###############################################################
                            ERRORS
    ###############################################################*/
    error ZeroPrincipal();
    error ExceedsPrincipal();
    error ZeroRewards();
    error ExceedsMaxDeposits();
    error InvalidMaxDeposits();
    error ExceedsAvailableRewards();
    error InvalidToken();
    /*###############################################################
                            STRUCTS
    ###############################################################*/
    struct RewardData {
        uint256 rewardPerShareStored;
        uint256 totalRewards;
    }
    /*###############################################################
                            EVENTS
    ###############################################################*/
    event RewardAdded(address indexed token, uint256 rewardAmount);
    /*###############################################################
                            STORAGE
    ###############################################################*/
    uint256 public depositPrincipal;
    uint256 public maxDeposits;
    
    // Reward tracking per token
    mapping(address => RewardData) public rewardData;
    mapping(address => mapping(address => uint256)) public userRewardPerSharePaid;
    mapping(address => mapping(address => uint256)) public rewards;
    
    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;

    /*###############################################################
                            CONSTRUCTOR
    ###############################################################*/
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    /*###############################################################
                            INITIALIZER
    ###############################################################*/
    function initialize(address _asset, address _owner, uint256 _maxDeposits) external initializer {
        __ERC4626_init(IERC20(_asset));
        __ERC20_init("fatBERA", "fatBERA");
        __Ownable_init(_owner);

        maxDeposits = _maxDeposits;
        _pause();
    }

    /*###############################################################
                            OWNER LOGIC
    ###############################################################*/
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Updates the maximum amount of deposits allowed
     * @param newMax The new maximum deposit amount
     */
    function setMaxDeposits(uint256 newMax) external onlyOwner {
        if (newMax < depositPrincipal) revert InvalidMaxDeposits();
        maxDeposits = newMax;
    }

    /**
     * @dev Optional function for the owner to withdraw principal deposits
     *      so those tokens can be staked in a validator. This ensures yield
     *      remains in the vault, as depositPrincipal decrements.
     */
    function withdrawPrincipal(uint256 assets, address receiver) external onlyOwner {
        if (assets <= 0) revert ZeroPrincipal();
        if (assets > depositPrincipal) revert ExceedsPrincipal();

        depositPrincipal -= assets;
        IERC20(asset()).safeTransfer(receiver, assets);
    }

    /**
     * @dev Allows owner (or another trusted source) to notify the contract
     *      that new reward tokens have arrived. This increments "rewardPerShareStored"
     *      proportionally to the total shares in existence.
     */
    function notifyRewardAmount(address token, uint256 rewardAmount) external onlyOwner {
        if (rewardAmount <= 0) revert ZeroRewards();
        if (token == address(0)) revert InvalidToken();
        
        IERC20 rewardToken = IERC20(token);
        if (rewardAmount > rewardToken.balanceOf(address(this))) revert ExceedsAvailableRewards();

        // Add to reward tokens list if new
        if (!isRewardToken[token]) {
            rewardTokens.push(token);
            isRewardToken[token] = true;
        }

        RewardData storage data = rewardData[token];
        uint256 totalSharesCurrent = totalSupply();
        
        if (totalSharesCurrent > 0) {
            data.rewardPerShareStored += FixedPointMathLib.fullMulDiv(
                rewardAmount, 
                1e18, 
                totalSharesCurrent
            );
        }
        data.totalRewards += rewardAmount;
        emit RewardAdded(token, rewardAmount);
    }

    /*###############################################################
                            EXTERNAL LOGIC
    ###############################################################*/
    /**
     * @dev Override to return only totalSupply, ignoring any extra tokens from yield or
     * tokens removed by owner to stake in validator. Shares are always worth 1 WBERA and
     * all yield is handled by the rewards logic.
     */
    function totalAssets() public view virtual override returns (uint256) {
        return totalSupply();
    }
    /**
     * @notice Overridden deposit logic to account for rewards, then
     *         increment depositPrincipal.
     */

    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        if (depositPrincipal + assets > maxDeposits) revert ExceedsMaxDeposits();
        _updateRewards(receiver);

        uint256 sharesMinted = super.deposit(assets, receiver);
        depositPrincipal += assets;

        return sharesMinted;
    }

    /**
     * @notice Overridden mint logic with same reward update approach,
     *         and consistent depositPrincipal increments.
     */
    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        _updateRewards(receiver);

        uint256 assetsRequired = super.previewMint(shares);
        if (depositPrincipal + assetsRequired > maxDeposits) revert ExceedsMaxDeposits();

        assetsRequired = super.mint(shares, receiver);
        depositPrincipal += assetsRequired;

        return assetsRequired;
    }

    /**
     * @notice Overridden withdraw logic that also handles reward distribution.
     *         Time-locked or restricted for regular users (except via unpause or
     *         specific chain events enabling principal withdrawals).
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotPaused
        returns (uint256)
    {
        _updateRewards(owner);

        uint256 burnedShares = super.withdraw(assets, receiver, owner);
        depositPrincipal -= assets;

        return burnedShares;
    }

    /**
     * @notice Overridden redeem logic that also handles reward distribution.
     */
    function redeem(uint256 shares, address receiver, address owner) public override whenNotPaused returns (uint256) {
        _updateRewards(owner);

        uint256 redeemedAssets = super.redeem(shares, receiver, owner);
        depositPrincipal -= redeemedAssets;

        return redeemedAssets;
    }

    /**
     * @dev Called by user to claim any accrued rewards.
     */
    function claimRewards(address token, address receiver) public nonReentrant {
        _updateRewards(msg.sender, token);
        
        uint256 reward = rewards[token][msg.sender];
        if (reward > 0) {
            rewards[token][msg.sender] = 0;
            IERC20(token).safeTransfer(receiver, reward);
        }
    }

    // Overloaded for multiple reward tokens
    function claimRewards(address receiver) public nonReentrant {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            _updateRewards(msg.sender, rewardTokens[i]);

            uint256 reward = rewards[rewardTokens[i]][msg.sender];
            if (reward > 0) {
                rewards[rewardTokens[i]][msg.sender] = 0;
                IERC20(rewardTokens[i]).safeTransfer(receiver, reward);
            }
        }
    }

    /*###############################################################
                            VIEW LOGIC
    ###############################################################*/
    function previewRewards(address account, address token) external view returns (uint256) {
        RewardData storage data = rewardData[token];
        uint256 earnedPerShare = data.rewardPerShareStored - userRewardPerSharePaid[token][account];
        uint256 accountShares = balanceOf(account);
        
        return rewards[token][account] + FixedPointMathLib.mulDiv(
            accountShares, 
            earnedPerShare, 
            1e18
        );
    }

    // Helper to get all reward tokens
    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }

    /*###############################################################
                            INTERNAL LOGIC
    ###############################################################*/
    function _updateRewards(address account) internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            _updateRewards(account, rewardTokens[i]);
        }
    }

    function _updateRewards(address account, address token) internal {
        RewardData storage data = rewardData[token];
        uint256 accountShares = balanceOf(account);
        
        if (accountShares > 0) {
            uint256 earnedPerShare = data.rewardPerShareStored - userRewardPerSharePaid[token][account];
            rewards[token][account] += FixedPointMathLib.mulDiv(
                accountShares, 
                earnedPerShare, 
                1e18
            );
        }
        userRewardPerSharePaid[token][account] = data.rewardPerShareStored;
    }

    /*###############################################################
    ###############################################################*/
    receive() external payable {}
}
