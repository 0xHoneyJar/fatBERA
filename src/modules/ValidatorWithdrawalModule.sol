// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Enum} from "./Enum.sol";
import {fatBERAV2} from "../fatBERAV2.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                          INTERFACES                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Safe contract interface (following official tutorial pattern)
interface ISafe {
    /// @dev Allows a Module to execute a Safe transaction without any further confirmations.
    /// @param to Destination address of module transaction.
    /// @param value Ether value of module transaction.
    /// @param data Data payload of module transaction.
    /// @param operation Operation type of module transaction.
    function execTransactionFromModule(address to, uint256 value, bytes memory data, Enum.Operation operation)
        external
        returns (bool success);
}

/// @dev WBERA interface for wrapping native BERA
interface IWBERA {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

/**
 * @title ValidatorWithdrawalModule
 * @notice Safe module that automates validator withdrawal operations
 * @dev This module allows authorized EOAs to trigger withdrawal batches and validator withdrawals
 *      without requiring multi-sig approval for each operation
 */
contract ValidatorWithdrawalModule is AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          ERRORS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error UnauthorizedSafe();
    error InvalidFatBERAContract();
    error InvalidWithdrawContract();
    error InvalidCometBFTPublicKey();
    error InvalidWithdrawAmount();
    error InsufficientWithdrawFee();
    error TransactionFailed();
    error SafeNotAuthorized();
    error ZeroAddress();
    error ZeroAmount();
    error StartWithdrawalBatchDisabled();
    error RequestValidatorWithdrawalDisabled();
    error WithdrawalAmountTooLow();
    error ValidatorKeyNotWhitelisted();
    error InsufficientNativeBalance();
    error WrapFailed();
    error ApproveFailed();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EVENTS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event WithdrawalBatchStarted(
        address indexed safe, address indexed initiator, uint256 indexed batchId, uint256 totalAmount
    );

    event ValidatorWithdrawalRequested(
        address indexed safe,
        address indexed initiator,
        bytes indexed cometBFTPublicKey,
        uint256 withdrawAmount,
        uint256 fee
    );

    event BatchFulfilled(address indexed safe, address indexed initiator, uint256 indexed batchId, uint256 fee);

    event TriggerUpdated(address indexed oldTrigger, address indexed newTrigger);
    event SafeConfigured(address indexed safe, address indexed fatBERA, bytes cometBFTPublicKey);
    event StartWithdrawalBatchToggled(bool enabled);
    event RequestValidatorWithdrawalToggled(bool enabled);
    event NativeBeraWrapped(address indexed safe, uint256 amount);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    bytes32 public constant TRIGGER_ROLE = keccak256("TRIGGER_ROLE");

    // Berachain constants
    address public constant BERACHAIN_WITHDRAW_CONTRACT = 0x00000961Ef480Eb55e80D19ad83579A64c007002;
    address public constant WBERA_ADDRESS = 0x6969696969696969696969696969696969696969;

    // Safe-specific configurations
    struct SafeConfig {
        address fatBERAContract;
        bool isConfigured;
    }

    mapping(address => SafeConfig) public safeConfigs;
    
    // Validator key whitelist per Safe
    mapping(address => mapping(bytes32 => bool)) public whitelistedValidatorKeys;
    mapping(address => bytes32[]) public safeValidatorKeys;

    // Function toggles for security control
    bool public startWithdrawalBatchEnabled;
    bool public requestValidatorWithdrawalEnabled;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          CONSTRUCTOR                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Contract constructor.
     * @dev Disables initializers to prevent misuse.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract variables and sets up admin roles.
     * @param admin The admin owner address.
     * @param initialTrigger The initial trigger address.
     * @dev Calls initializer functions from parent contracts and sets up admin roles.
     */
    function initialize(address admin, address initialTrigger) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (initialTrigger == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TRIGGER_ROLE, initialTrigger);

        startWithdrawalBatchEnabled = false;
        requestValidatorWithdrawalEnabled = false;
    }

    /**
     * @notice Authorizes an upgrade of the contract implementation.
     * @param newImplementation The address of the new implementation.
     * @dev Only callable by admin.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          ADMIN FUNCTIONS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Configure a Safe for validator withdrawal operations
     * @param safe The Safe contract address
     * @param fatBERAContract The fatBERA contract address for this Safe
     */
    function configureSafe(address safe, address fatBERAContract) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (safe == address(0)) revert ZeroAddress();
        if (fatBERAContract == address(0)) revert InvalidFatBERAContract();

        safeConfigs[safe] = SafeConfig({fatBERAContract: fatBERAContract, isConfigured: true});

        emit SafeConfigured(safe, fatBERAContract, "");
    }

    /**
     * @notice Add a validator key to the whitelist for a Safe
     * @param safe The Safe contract address
     * @param validatorKey The CometBFT public key to whitelist
     */
    function addValidatorKey(address safe, bytes calldata validatorKey) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!safeConfigs[safe].isConfigured) revert UnauthorizedSafe();
        if (validatorKey.length == 0) revert InvalidCometBFTPublicKey();
        
        bytes32 keyHash = keccak256(validatorKey);
        if (!whitelistedValidatorKeys[safe][keyHash]) {
            whitelistedValidatorKeys[safe][keyHash] = true;
            safeValidatorKeys[safe].push(keyHash);
        }
    }

    /**
     * @notice Remove a validator key from the whitelist for a Safe
     * @param safe The Safe contract address
     * @param validatorKey The CometBFT public key to remove
     */
    function removeValidatorKey(address safe, bytes calldata validatorKey) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!safeConfigs[safe].isConfigured) revert UnauthorizedSafe();
        if (validatorKey.length == 0) revert InvalidCometBFTPublicKey();
        
        bytes32 keyHash = keccak256(validatorKey);
        whitelistedValidatorKeys[safe][keyHash] = false;
        
        // Remove from array
        bytes32[] storage keys = safeValidatorKeys[safe];
        for (uint256 i = 0; i < keys.length; i++) {
            if (keys[i] == keyHash) {
                keys[i] = keys[keys.length - 1];
                keys.pop();
                break;
            }
        }
    }

    /**
     * @notice Add a new trigger address
     * @param trigger The address to grant trigger permissions
     */
    function addTrigger(address trigger) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (trigger == address(0)) revert ZeroAddress();
        _grantRole(TRIGGER_ROLE, trigger);
        emit TriggerUpdated(address(0), trigger);
    }

    /**
     * @notice Remove a trigger address
     * @param trigger The address to revoke trigger permissions
     */
    function removeTrigger(address trigger) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(TRIGGER_ROLE, trigger);
        emit TriggerUpdated(trigger, address(0));
    }

    /**
     * @notice Enable or disable the startWithdrawalBatch function
     * @param enabled True to enable, false to disable
     */
    function setStartWithdrawalBatchEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        startWithdrawalBatchEnabled = enabled;
        emit StartWithdrawalBatchToggled(enabled);
    }

    /**
     * @notice Enable or disable the requestValidatorWithdrawal function
     * @param enabled True to enable, false to disable
     */
    function setRequestValidatorWithdrawalEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        requestValidatorWithdrawalEnabled = enabled;
        emit RequestValidatorWithdrawalToggled(enabled);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TRIGGER FUNCTIONS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Start a withdrawal batch from fatBERA
     * @param safe The Safe contract that owns the fatBERA position
     * @return batchId The ID of the started batch
     * @return totalAmount The total amount in the batch
     */
    function startWithdrawalBatch(address safe)
        external
        onlyRole(TRIGGER_ROLE)
        nonReentrant
        returns (uint256 batchId, uint256 totalAmount)
    {
        if (!startWithdrawalBatchEnabled) revert StartWithdrawalBatchDisabled();
        return _startWithdrawalBatch(safe);
    }

    /**
     * @notice Request a validator withdrawal from Berachain
     * @param safe The Safe contract (must be withdrawal credential address)
     * @param withdrawAmount The amount to withdraw
     * @param cometBFTPublicKey The CometBFT public key of the specific validator to withdraw from
     */
    function requestValidatorWithdrawal(address safe, uint256 withdrawAmount, bytes calldata cometBFTPublicKey)
        external
        onlyRole(TRIGGER_ROLE)
        nonReentrant
    {
        if (!requestValidatorWithdrawalEnabled) revert RequestValidatorWithdrawalDisabled();
        _requestValidatorWithdrawal(safe, withdrawAmount, cometBFTPublicKey);
    }

    /**
     * @notice Start a withdrawal batch and immediately request validator withdrawal
     * @param safe The Safe contract that owns the fatBERA position and is the withdrawal credential
     * @param cometBFTPublicKey The CometBFT public key of the specific validator to withdraw from
     * @return batchId The ID of the started batch
     * @return totalAmount The total amount in the batch that was requested for validator withdrawal
     */
    function startWithdrawalBatchAndRequestValidatorWithdrawal(address safe, bytes calldata cometBFTPublicKey)
        external
        onlyRole(TRIGGER_ROLE)
        nonReentrant
        returns (uint256 batchId, uint256 totalAmount)
    {
        // Step 1: Start withdrawal batch
        (batchId, totalAmount) = _startWithdrawalBatch(safe);

        // Step 2: Request validator withdrawal with the batch total amount
        _requestValidatorWithdrawal(safe, totalAmount, cometBFTPublicKey);

        return (batchId, totalAmount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        INTERNAL FUNCTIONS                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Internal function to start a withdrawal batch from fatBERA
     * @param safe The Safe contract that owns the fatBERA position
     * @return batchId The ID of the started batch
     * @return totalAmount The total amount in the batch
     */
    function _startWithdrawalBatch(address safe) internal returns (uint256 batchId, uint256 totalAmount) {
        SafeConfig memory config = safeConfigs[safe];
        if (!config.isConfigured) revert UnauthorizedSafe();

        // Verify the Safe has the WITHDRAW_FULFILLER_ROLE on the fatBERA contract
        fatBERAV2 fatBERA = fatBERAV2(config.fatBERAContract);
        bytes32 withdrawFulfillerRole = fatBERA.WITHDRAW_FULFILLER_ROLE();
        if (!fatBERA.hasRole(withdrawFulfillerRole, safe)) revert SafeNotAuthorized();

        // Encode the call to startWithdrawalBatch
        bytes memory startBatchData = abi.encodeWithSelector(fatBERAV2.startWithdrawalBatch.selector);

        // Store the current batch ID before the call to detect the new one
        uint256 currentBatchIdBefore = fatBERA.currentBatchId();

        // Execute via Safe module
        bool success =
            ISafe(safe).execTransactionFromModule(config.fatBERAContract, 0, startBatchData, Enum.Operation.Call);

        if (!success) revert TransactionFailed();

        batchId = currentBatchIdBefore; // The batch that was just started

        // Get the total amount from the batch that was just frozen
        (,, uint256 total) = fatBERA.batches(batchId);

        emit WithdrawalBatchStarted(safe, msg.sender, batchId, total);

        return (batchId, total);
    }

    /**
     * @notice Internal function to request a validator withdrawal from Berachain
     * @param safe The Safe contract (must be withdrawal credential address)
     * @param withdrawAmount The amount to withdraw
     * @param cometBFTPublicKey The CometBFT public key of the specific validator to withdraw from
     */
    function _requestValidatorWithdrawal(address safe, uint256 withdrawAmount, bytes calldata cometBFTPublicKey)
        internal
    {
        SafeConfig memory config = safeConfigs[safe];
        if (!config.isConfigured) revert UnauthorizedSafe();
        if (withdrawAmount == 0) revert ZeroAmount();
        
        // Key validation - only allow whitelisted keys
        if (cometBFTPublicKey.length == 0) revert InvalidCometBFTPublicKey();
        
        // SECURITY: Check if key is whitelisted for this Safe
        // This prevents compromised triggers from using malicious keys
        bytes32 keyHash = keccak256(cometBFTPublicKey);
        if (!whitelistedValidatorKeys[safe][keyHash]) revert ValidatorKeyNotWhitelisted();

        // Get the current withdrawal fee (confirmed to be in WEI based on Berachain docs)
        // Documentation shows fee is used as --value ${WITHDRAW_FEE}wei, so response is in WEI
        (bool success, bytes memory returnData) = BERACHAIN_WITHDRAW_CONTRACT.staticcall("");
        if (!success) revert TransactionFailed();
        uint256 withdrawFeeWei = abi.decode(returnData, (uint256));

        // Ensure withdrawal amount is greater than fee to avoid zero/negative net withdrawal
        // Also prevents accidental validator exit (withdrawAmount = 0 exits validator entirely)
        if (withdrawAmount <= withdrawFeeWei) revert WithdrawalAmountTooLow();

        // Subtract fee from withdrawal amount since fatBERA.fulfillBatch() already accounts for the fee
        // This ensures we get exactly (withdrawAmount - withdrawFeeWei) net from the validator
        uint256 adjustedWithdrawAmountWei = withdrawAmount - withdrawFeeWei;

        // Convert from WEI to GWEI as required by Berachain withdraw contract
        // fatBERAV2 returns amounts in WEI, but Berachain expects GWEI (uint64)
        // Use ceiling division to ensure we always request at least the amount needed
        uint256 adjustedWithdrawAmountGwei = (adjustedWithdrawAmountWei + 1e9 - 1) / 1e9;
        
        // Ensure the GWEI amount fits in uint64
        if (adjustedWithdrawAmountGwei > type(uint64).max) revert InvalidWithdrawAmount();

        // Encode the withdrawal request according to Berachain docs: (bytes,uint64)
        bytes memory withdrawRequest = abi.encodePacked(cometBFTPublicKey, uint64(adjustedWithdrawAmountGwei));

        // Execute the validator withdrawal request via Safe
        // Fee is paid as msg.value in WEI
        success = ISafe(safe).execTransactionFromModule(
            BERACHAIN_WITHDRAW_CONTRACT, withdrawFeeWei, withdrawRequest, Enum.Operation.Call
        );

        if (!success) revert TransactionFailed();

        emit ValidatorWithdrawalRequested(safe, msg.sender, cometBFTPublicKey, adjustedWithdrawAmountWei, withdrawFeeWei);
    }

    /**
     * @notice Fulfill a withdrawal batch after validator withdrawal completes
     * @param safe The Safe contract address
     * @param batchId The batch ID to fulfill
     * @param fee The withdrawal fee to deduct
     * @dev This function wraps native BERA to WBERA, approves the fatBERA contract, then fulfills the batch
     */
    function fulfillWithdrawalBatch(address safe, uint256 batchId, uint256 fee)
        external
        onlyRole(TRIGGER_ROLE)
        nonReentrant
    {
        SafeConfig memory config = safeConfigs[safe];
        if (!config.isConfigured) revert UnauthorizedSafe();

        // Get batch info to calculate exact amount needed
        fatBERAV2 fatBERA = fatBERAV2(config.fatBERAContract);
        (, , uint256 totalShares) = fatBERA.batches(batchId);
        uint256 netAmount = totalShares - fee;

        if (netAmount == 0) revert ZeroAmount();

        // Step 1: Wrap native BERA to WBERA
        bytes memory wrapData = abi.encodeWithSelector(IWBERA.deposit.selector);
        
        bool success = ISafe(safe).execTransactionFromModule(
            WBERA_ADDRESS,
            netAmount, // Send native BERA as msg.value
            wrapData,
            Enum.Operation.Call
        );
        if (!success) revert WrapFailed();

        emit NativeBeraWrapped(safe, netAmount);

        // Step 2: Approve fatBERA contract to spend WBERA
        bytes memory approveData = abi.encodeWithSelector(
            IWBERA.approve.selector,
            config.fatBERAContract,
            netAmount
        );
        
        success = ISafe(safe).execTransactionFromModule(
            WBERA_ADDRESS,
            0,
            approveData,
            Enum.Operation.Call
        );
        if (!success) revert ApproveFailed();

        // Step 3: Fulfill the batch
        bytes memory fulfillData = abi.encodeWithSelector(
            fatBERAV2.fulfillBatch.selector,
            batchId,
            fee
        );
        
        success = ISafe(safe).execTransactionFromModule(
            config.fatBERAContract,
            0,
            fulfillData,
            Enum.Operation.Call
        );
        if (!success) revert TransactionFailed();

        emit BatchFulfilled(safe, msg.sender, batchId, fee);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          VIEW FUNCTIONS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Check if an address can trigger operations
     * @param trigger The address to check
     * @return True if the address has trigger permissions
     */
    function canTrigger(address trigger) external view returns (bool) {
        return hasRole(TRIGGER_ROLE, trigger);
    }

    /**
     * @notice Get the current Berachain withdrawal fee
     * @return The current withdrawal fee in wei
     */
    function getCurrentWithdrawalFee() external view returns (uint256) {
        (bool success, bytes memory returnData) = BERACHAIN_WITHDRAW_CONTRACT.staticcall("");
        if (!success) return 0;
        return abi.decode(returnData, (uint256));
    }

    /**
     * @notice Get Safe configuration
     * @param safe The Safe contract address
     * @return config The Safe configuration
     */
    function getSafeConfig(address safe) external view returns (SafeConfig memory config) {
        return safeConfigs[safe];
    }

    /**
     * @notice Check if a Safe is properly configured
     * @param safe The Safe contract address
     * @return True if the Safe is configured for operations
     */
    function isSafeConfigured(address safe) external view returns (bool) {
        return safeConfigs[safe].isConfigured;
    }

    /**
     * @notice Check if a validator key is whitelisted for a Safe
     * @param safe The Safe contract address
     * @param validatorKey The CometBFT public key to check
     * @return True if the key is whitelisted
     */
    function isValidatorKeyWhitelisted(address safe, bytes calldata validatorKey) external view returns (bool) {
        bytes32 keyHash = keccak256(validatorKey);
        return whitelistedValidatorKeys[safe][keyHash];
    }

    /**
     * @notice Get all whitelisted validator keys for a Safe
     * @param safe The Safe contract address
     * @return Array of whitelisted validator key hashes
     */
    function getWhitelistedValidatorKeys(address safe) external view returns (bytes32[] memory) {
        return safeValidatorKeys[safe];
    }
}
