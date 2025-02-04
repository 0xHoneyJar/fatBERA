// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/*###############################################################
                            INTERFACES
###############################################################*/
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

contract fatBERA is 
    ERC4626Upgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
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
    error ZeroShares();
    error ExceedsMaxRewardsTokens();
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

    // Define role constants
    bytes32 public constant REWARD_NOTIFIER_ROLE = keccak256("REWARD_NOTIFIER_ROLE");

    uint256 public MAX_REWARDS_TOKENS = 10;

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
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(REWARD_NOTIFIER_ROLE, _owner);

        maxDeposits = _maxDeposits;
        _pause();
    }

    /*###############################################################
                            OWNER LOGIC
    ###############################################################*/
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function setMaxRewardsTokens(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        MAX_REWARDS_TOKENS = newMax;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Updates the maximum amount of deposits allowed
     * @param newMax The new maximum deposit amount
     */
    function setMaxDeposits(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMax < depositPrincipal) revert InvalidMaxDeposits();
        maxDeposits = newMax;
    }

    /**
     * @dev Optional function for the owner to withdraw principal deposits
     *      so those tokens can be staked in a validator. This ensures yield
     *      remains in the vault, as depositPrincipal decrements.
     */
    function withdrawPrincipal(uint256 assets, address receiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
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
    function notifyRewardAmount(address token, uint256 rewardAmount) external onlyRole(REWARD_NOTIFIER_ROLE) {
        if (rewardAmount <= 0) revert ZeroRewards();
        if (token == address(0)) revert InvalidToken();
        
        uint256 totalSharesCurrent = totalSupply();
        if (totalSharesCurrent == 0) revert ZeroShares();

        IERC20 rewardToken = IERC20(token);
        rewardToken.safeTransferFrom(msg.sender, address(this), rewardAmount);

        // Add to reward tokens list if new
        if (!isRewardToken[token]) {
            rewardTokens.push(token);
            if (rewardTokens.length > MAX_REWARDS_TOKENS) revert ExceedsMaxRewardsTokens();
            isRewardToken[token] = true;
        }

        RewardData storage data = rewardData[token];
        data.rewardPerShareStored += FixedPointMathLib.fullMulDiv(
            rewardAmount, 
            1e36, 
            totalSharesCurrent
        );
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
     * @dev Returns the maximum amount of assets that can be deposited.
     * Overrides the default implementation to enforce the maxDeposits limit.
     */
    function maxDeposit(address) public view virtual override returns (uint256) {
        if (totalSupply() >= maxDeposits) return 0;
        return maxDeposits - totalSupply();
    }

    /**
     * @dev Returns the maximum amount of shares that can be minted.
     * Since shares are 1:1 with assets in this vault, this is the same as maxDeposit.
     */
    function maxMint(address receiver) public view virtual override returns (uint256) {
        return maxDeposit(receiver);
    }
    
    /**
     * @dev Returns the maximum amount of assets that can be withdrawn.
     * Currently returns 0 as withdrawals are disabled.
     * This will be updated in a future upgrade when withdrawals are enabled.
     */
    function maxWithdraw(address) public view virtual override returns (uint256) {
        return 0;
    }

    /**
     * @dev Returns the maximum amount of shares that can be redeemed.
     * Currently returns 0 as withdrawals are disabled.
     * This will be updated in a future upgrade when withdrawals are enabled.
     */
    function maxRedeem(address) public view virtual override returns (uint256) {
        return 0;
    }
    
    /**
     * @dev Deposit native ETH into the vault, wrapping it into WBERA. Here for better UX for users.
     * @param receiver The address to receive the shares.
     * @return The number of shares minted.
     */
    function depositNative(address receiver) external payable nonReentrant returns (uint256) {
        if (msg.value == 0) revert ZeroPrincipal();
        if (msg.value > maxDeposit(receiver)) revert ExceedsMaxDeposits();
        _updateRewards(receiver);

        // Wrap native token
        IWETH weth = IWETH(asset());
        weth.deposit{value: msg.value}();

        // Calculate shares directly using previewDeposit
        uint256 shares = previewDeposit(msg.value);
        
        // Bypass ERC4626 deposit and mint directly (we already have the assets)
        _mint(receiver, shares);
        depositPrincipal += msg.value;

        // Manually emit Deposit event to match ERC4626 spec
        emit Deposit(msg.sender, receiver, msg.value, shares);

        return shares;
    }

    /**
     * @notice Overridden deposit logic to account for rewards, then
     *         increment depositPrincipal.
     */
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
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
        assetsRequired = super.mint(shares, receiver);
        depositPrincipal += assetsRequired;

        return assetsRequired;
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
                     WITHDRAWALS ARENT ENABLED YET
    ###############################################################*/
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

    /*###############################################################
                            VIEW LOGIC
    ###############################################################*/
    function previewRewards(address account, address token) external view returns (uint256) {
        RewardData storage data = rewardData[token];
        uint256 earnedPerShare = data.rewardPerShareStored - userRewardPerSharePaid[token][account];
        uint256 accountShares = balanceOf(account);
        
        return rewards[token][account] + FixedPointMathLib.fullMulDiv(
            accountShares, 
            earnedPerShare, 
            1e36
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
            rewards[token][account] += FixedPointMathLib.fullMulDiv(
                accountShares, 
                earnedPerShare, 
                1e36
            );
        }
        userRewardPerSharePaid[token][account] = data.rewardPerShareStored;
    }
}
