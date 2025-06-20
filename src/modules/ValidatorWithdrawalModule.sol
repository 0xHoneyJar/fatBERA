// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Enum} from "./Enum.sol";

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
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation
    ) external returns (bool success);
}

interface IFatBERAV2 {
    function startWithdrawalBatch() external returns (uint256 batchId, uint256 total);
    function fulfillBatch(uint256 batchId, uint256 fee) external;
    function WITHDRAW_FULFILLER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function currentBatchId() external view returns (uint256);
    function batches(uint256 batchId) external view returns (
        address[] memory users,
        uint256[] memory amounts,
        bool frozen,
        bool fulfilled,
        uint256 total
    );
}

/**
 * @title ValidatorWithdrawalModule
 * @notice Safe module that automates validator withdrawal operations
 * @dev This module allows authorized EOAs to trigger withdrawal batches and validator withdrawals
 *      without requiring multi-sig approval for each operation
 */
contract ValidatorWithdrawalModule is AccessControl, ReentrancyGuard {
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

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EVENTS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event WithdrawalBatchStarted(
        address indexed safe,
        address indexed initiator,
        uint256 indexed batchId,
        uint256 totalAmount
    );

    event ValidatorWithdrawalRequested(
        address indexed safe,
        address indexed initiator,
        bytes indexed cometBFTPublicKey,
        uint256 withdrawAmount,
        uint256 fee
    );

    event BatchFulfilled(
        address indexed safe,
        address indexed initiator,
        uint256 indexed batchId,
        uint256 fee
    );

    event TriggerUpdated(address indexed oldTrigger, address indexed newTrigger);
    event SafeConfigured(address indexed safe, address indexed fatBERA, bytes cometBFTPublicKey);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    bytes32 public constant TRIGGER_ROLE = keccak256("TRIGGER_ROLE");
    
    // Berachain constants
    address public constant BERACHAIN_WITHDRAW_CONTRACT = 0x00000961Ef480Eb55e80D19ad83579A64c007002;
    
    // Safe-specific configurations
    struct SafeConfig {
        address fatBERAContract;
        bool isConfigured;
    }
    
    mapping(address => SafeConfig) public safeConfigs;
    
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          CONSTRUCTOR                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    constructor(address admin, address initialTrigger) {
        if (admin == address(0)) revert ZeroAddress();
        if (initialTrigger == address(0)) revert ZeroAddress();
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TRIGGER_ROLE, initialTrigger);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          ADMIN FUNCTIONS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Configure a Safe for validator withdrawal operations
     * @param safe The Safe contract address
     * @param fatBERAContract The fatBERA contract address for this Safe
     */
    function configureSafe(
        address safe,
        address fatBERAContract
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (safe == address(0)) revert ZeroAddress();
        if (fatBERAContract == address(0)) revert InvalidFatBERAContract();
        
        safeConfigs[safe] = SafeConfig({
            fatBERAContract: fatBERAContract,
            isConfigured: true
        });
        
        emit SafeConfigured(safe, fatBERAContract, "");
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
        return _startWithdrawalBatch(safe);
    }

    /**
     * @notice Request a validator withdrawal from Berachain
     * @param safe The Safe contract (must be withdrawal credential address)
     * @param withdrawAmount The amount to withdraw
     * @param cometBFTPublicKey The CometBFT public key of the specific validator to withdraw from
     */
    function requestValidatorWithdrawal(
        address safe,
        uint256 withdrawAmount,
        bytes calldata cometBFTPublicKey
    ) external onlyRole(TRIGGER_ROLE) nonReentrant {
        _requestValidatorWithdrawal(safe, withdrawAmount, cometBFTPublicKey);
    }

    /**
     * @notice Start a withdrawal batch and immediately request validator withdrawal
     * @param safe The Safe contract that owns the fatBERA position and is the withdrawal credential
     * @param cometBFTPublicKey The CometBFT public key of the specific validator to withdraw from
     * @return batchId The ID of the started batch
     * @return totalAmount The total amount in the batch that was requested for validator withdrawal
     */
    function startWithdrawalBatchAndRequestValidatorWithdrawal(
        address safe,
        bytes calldata cometBFTPublicKey
    ) external onlyRole(TRIGGER_ROLE) nonReentrant returns (uint256 batchId, uint256 totalAmount) {
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
    function _startWithdrawalBatch(address safe) 
        internal 
        returns (uint256 batchId, uint256 totalAmount) 
    {
        SafeConfig memory config = safeConfigs[safe];
        if (!config.isConfigured) revert UnauthorizedSafe();
        
        // Verify the Safe has the WITHDRAW_FULFILLER_ROLE on the fatBERA contract
        IFatBERAV2 fatBERA = IFatBERAV2(config.fatBERAContract);
        bytes32 withdrawFulfillerRole = fatBERA.WITHDRAW_FULFILLER_ROLE();
        if (!fatBERA.hasRole(withdrawFulfillerRole, safe)) revert SafeNotAuthorized();
        
        // Encode the call to startWithdrawalBatch
        bytes memory startBatchData = abi.encodeWithSelector(
            IFatBERAV2.startWithdrawalBatch.selector
        );
        
        // Store the current batch ID before the call to detect the new one
        uint256 currentBatchIdBefore = fatBERA.currentBatchId();
        
        // Execute via Safe module
        bool success = ISafe(safe).execTransactionFromModule(
            config.fatBERAContract,
            0,
            startBatchData,
            Enum.Operation.Call
        );
        
        if (!success) revert TransactionFailed();
        
        batchId = currentBatchIdBefore; // The batch that was just started
        
        // Get the total amount from the batch that was just frozen
        (,, bool frozen,, uint256 total) = fatBERA.batches(batchId);
        if (!frozen) revert TransactionFailed();
        totalAmount = total;
        
        emit WithdrawalBatchStarted(safe, msg.sender, batchId, totalAmount);
        
        return (batchId, totalAmount);
    }

    /**
     * @notice Internal function to request a validator withdrawal from Berachain
     * @param safe The Safe contract (must be withdrawal credential address)
     * @param withdrawAmount The amount to withdraw
     * @param cometBFTPublicKey The CometBFT public key of the specific validator to withdraw from
     */
    function _requestValidatorWithdrawal(
        address safe,
        uint256 withdrawAmount,
        bytes calldata cometBFTPublicKey
    ) internal {
        SafeConfig memory config = safeConfigs[safe];
        if (!config.isConfigured) revert UnauthorizedSafe();
        if (withdrawAmount == 0) revert ZeroAmount();
        if (cometBFTPublicKey.length == 0) revert InvalidCometBFTPublicKey();
        
        // Get the current withdrawal fee
        (bool success, bytes memory returnData) = BERACHAIN_WITHDRAW_CONTRACT.staticcall("");
        if (!success) revert TransactionFailed();
        uint256 withdrawFee = abi.decode(returnData, (uint256));
        
        // Encode the withdrawal request
        bytes memory withdrawRequest = abi.encodePacked(
            cometBFTPublicKey,
            withdrawAmount
        );
        
        // Execute the validator withdrawal request via Safe
        success = ISafe(safe).execTransactionFromModule(
            BERACHAIN_WITHDRAW_CONTRACT,
            withdrawFee,
            withdrawRequest,
            Enum.Operation.Call
        );
        
        if (!success) revert TransactionFailed();
        
        emit ValidatorWithdrawalRequested(
            safe,
            msg.sender,
            cometBFTPublicKey,
            withdrawAmount,
            withdrawFee
        );
    }

    /**
     * @notice Fulfill a withdrawal batch after validator withdrawal completes
     * @param safe The Safe contract address
     * @param batchId The batch ID to fulfill
     * @param fee The withdrawal fee to deduct
     */
    function fulfillWithdrawalBatch(
        address safe,
        uint256 batchId,
        uint256 fee
    ) external onlyRole(TRIGGER_ROLE) nonReentrant {
        SafeConfig memory config = safeConfigs[safe];
        if (!config.isConfigured) revert UnauthorizedSafe();
        
        // Encode the call to fulfillBatch
        bytes memory data = abi.encodeWithSelector(
            IFatBERAV2.fulfillBatch.selector,
            batchId,
            fee
        );
        
        // Execute via Safe module
        bool success = ISafe(safe).execTransactionFromModule(
            config.fatBERAContract,
            0,
            data,
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
} 