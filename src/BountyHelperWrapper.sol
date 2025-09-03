// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface IBountyHelper {
    function claimBgt(
        address _bault,
        address router,
        bytes calldata data,
        uint256 minAmountOut,
        address bgtRecipient,
        address excessRecipient
    ) external payable;

    function claimBgtWrapper(
        address _bault,
        address bgtWrapper,
        address router,
        bytes calldata data,
        uint256 minAmountOut,
        address excessRecipient
    ) external;
}

/**
 * @title BountyHelperWrapper
 * @notice Access-controlled wrapper for BountyHelper to prevent MEV frontrunning
 * @dev Only addresses with BOT_ROLE can call the claim functions
 */
contract BountyHelperWrapper is 
    Initializable,
    AccessControlUpgradeable, 
    UUPSUpgradeable 
{
    IBountyHelper public bountyHelper;
    
    /// @notice Role for addresses that can call claim functions
    bytes32 public constant BOT_ROLE = keccak256("BOT_ROLE");
    
    /// @notice Events
    event BountyHelperUpdated(address indexed oldBountyHelper, address indexed newBountyHelper);
    
    /// @notice Custom errors
    error NotAuthorized();
    error ZeroAddress();
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the contract
     * @param _bountyHelper Address of the BountyHelper contract to wrap
     * @param _admin Admin of this wrapper contract (gets DEFAULT_ADMIN_ROLE)
     * @param _initialBot Bot address to initially grant BOT_ROLE
     */
    function initialize(
        address _bountyHelper,
        address _admin,
        address _initialBot
    ) external initializer {
        if (_bountyHelper == address(0) || _admin == address(0)) {
            revert ZeroAddress();
        }
        
        __AccessControl_init();
        __UUPSUpgradeable_init();
        
        // Grant admin role to the specified admin
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        
        bountyHelper = IBountyHelper(_bountyHelper);
        
        // Grant BOT_ROLE to initial bot addresses
        _grantRole(BOT_ROLE, _initialBot);
    }
    
    /**
     * @notice Modifier to check if caller has BOT_ROLE
     */
    modifier onlyBot() {
        if (!hasRole(BOT_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        _;
    }
    
    /**
     * @notice Wrapper for BountyHelper.claimBgt - Pay BERA, get raw BGT
     * @param _bault The bault contract address
     * @param router Router contract for token swaps
     * @param data Calldata for the router
     * @param minAmountOut Minimum BGT amount to receive
     * @param bgtRecipient Address to receive BGT
     * @param excessRecipient Address to receive excess tokens
     */
    function claimBgt(
        address _bault,
        address router,
        bytes calldata data,
        uint256 minAmountOut,
        address bgtRecipient,
        address excessRecipient
    ) external payable onlyBot {
        uint256 balanceBefore = address(this).balance - msg.value;
        
        bountyHelper.claimBgt{value: msg.value}(
            _bault,
            router,
            data,
            minAmountOut,
            bgtRecipient,
            excessRecipient
        );
        
        // Ensure no ETH is stuck in wrapper
        if (address(this).balance > balanceBefore) {
            payable(msg.sender).transfer(address(this).balance - balanceBefore);
        }
    }
    
    /**
     * @notice Wrapper for BountyHelper.claimBgtWrapper - Claim BGT wrapper tokens
     * @param _bault The bault contract address
     * @param bgtWrapper BGT wrapper token address
     * @param router Router contract for token swaps
     * @param data Calldata for the router
     * @param minAmountOut Minimum BGT wrapper amount to receive
     * @param excessRecipient Address to receive excess tokens
     */
    function claimBgtWrapper(
        address _bault,
        address bgtWrapper,
        address router,
        bytes calldata data,
        uint256 minAmountOut,
        address excessRecipient
    ) external onlyBot {
        bountyHelper.claimBgtWrapper(
            _bault,
            bgtWrapper,
            router,
            data,
            minAmountOut,
            excessRecipient
        );
    }
    
    /**
     * @notice Grant BOT_ROLE to an address
     * @param bot Address to grant BOT_ROLE to
     */
    function grantBotRole(address bot) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bot == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(BOT_ROLE, bot);
    }
    
    /**
     * @notice Revoke BOT_ROLE from an address
     * @param bot Address to revoke BOT_ROLE from
     */
    function revokeBotRole(address bot) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(BOT_ROLE, bot);
    }
    
    /**
     * @notice Batch grant BOT_ROLE to multiple addresses
     * @param bots Array of addresses to grant BOT_ROLE to
     */
    function batchGrantBotRole(address[] calldata bots) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 length = bots.length;
        for (uint256 i = 0; i < length;) {
            address bot = bots[i];
            if (bot != address(0)) {
                _grantRole(BOT_ROLE, bot);
            }
            
            unchecked {
                ++i;
            }
        }
    }
    
    /**
     * @notice Batch revoke BOT_ROLE from multiple addresses
     * @param bots Array of addresses to revoke BOT_ROLE from
     */
    function batchRevokeBotRole(address[] calldata bots) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 length = bots.length;
        for (uint256 i = 0; i < length;) {
            address bot = bots[i];
            if (bot != address(0)) {
                _revokeRole(BOT_ROLE, bot);
            }
            
            unchecked {
                ++i;
            }
        }
    }
    
    /**
     * @notice Update the bounty helper contract address
     * @param _newBountyHelper New bounty helper contract address
     */
    function setBountyHelper(address _newBountyHelper) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newBountyHelper == address(0)) {
            revert ZeroAddress();
        }
        
        address oldBountyHelper = address(bountyHelper);
        bountyHelper = IBountyHelper(_newBountyHelper);
        emit BountyHelperUpdated(oldBountyHelper, _newBountyHelper);
    }
    
    /**
     * @notice Emergency function to recover any tokens sent to this contract
     * @param token Token address to recover
     * @param to Address to send tokens to
     * @param amount Amount to recover
     */
    function emergencyRecover(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) {
            // Recover ETH
            payable(to).transfer(amount);
        } else {
            // Recover ERC20 tokens
            (bool success, bytes memory data) = token.call(
                abi.encodeWithSignature("transfer(address,uint256)", to, amount)
            );
            require(success && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
        }
    }
    
    /**
     * @notice Required by UUPSUpgradeable - only admin can authorize upgrades
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
    
    /**
     * @notice Allow contract to receive ETH
     */
    receive() external payable {}
} 