// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                          INTERFACES                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/**
 * @dev Interface for the fatBERA vault. The function withdrawPrincipal sends the underlying asset
 * (expected to be the wrapped BERA token) to the designated receiver.
 */
interface IFatBera {
    function withdrawPrincipal(uint256 assets, address receiver) external;
    function depositPrincipal() external view returns (uint256);
}

/**
 * @dev Interface for the wrapped BERA token (e.g. WBERA) following an IWETH pattern.
 * Calling withdraw converts wrapped tokens to native BERA.
 */
interface IWETH {
    function withdraw(uint256 amount) external;
}

/**
 * @dev Interface for the beacon deposit contract. The deposit function accepts validator parameters
 * and receives native BERA via msg.value.
 */
interface IBeaconDeposit {
    function deposit(
        bytes calldata pubkey,
        bytes calldata withdrawalCredentials,
        bytes calldata signature,
        address operator
    ) external payable;
}

/**
 * @title AutomatedStake by THJ
 * @notice This contract is designed to be the only admin (aside from a multisig) for the fatBERA vault.
 * It implements a single function, executeWithdrawUnwrapAndStake, which atomically:
 *   1. Withdraws principal from fatBERA (which sends WBERA to this contract),
 *   2. Unwraps WBERA to native BERA,
 *   3. Deposits the native BERA to the beacon deposit contract (staking to the validator).
 */
contract AutomatedStake is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable 
{
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           ERRORS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error ZeroAmount();
    error InvalidAddress();
    error InsufficientBalance();
    error NoFundsToRescue();
    error TransferFailed();
    error InsufficientStakeAmount(uint256 amount, uint256 minimum);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event WithdrawUnwrapAndStakeExecuted(uint256 indexed amount, bytes indexed pubkey);
    event ValidatorPubkeyUpdated(bytes newPubkey);
    event WithdrawalCredentialsUpdated(bytes newWithdrawalCredentials);
    event ValidatorSignatureUpdated(bytes newSignature);
    event ValidatorOperatorUpdated(address newOperator);
    event FundsRescued(address recipient, uint256 amount);
    event TokensRescued(address token, address recipient, uint256 amount);
    event MinimumStakeAmountUpdated(uint256 newAmount);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // Addresses of the external contracts we interact with.
    address public fatBera;
    address public wBera;
    address public beaconDeposit;

    // Validator deposit parameters needed for the beacon deposit.
    bytes public validatorPubkey;
    bytes public withdrawalCredentials;
    bytes public validatorSignature;
    address public validatorOperator;

    // Minimum amount required for staking (initially 15,000 WBERA)
    uint256 public minimumStakeAmount;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     CONSTRUCTOR & INITIALIZER              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer function (replaces constructor for upgradeable contracts)
     * @param _fatBera The address of the fatBERA contract.
     * @param _wBera The address of the wrapped BERA token contract.
     * @param _beaconDeposit The address of the beacon deposit contract.
     * @param _validatorPubkey The validator public key in bytes.
     * @param _withdrawalCredentials The withdrawal credentials in bytes.
     * @param _validatorSignature The validator signature in bytes.
     * @param _validatorOperator The validator operator's address.
     * @param operatorAdmin The multisig address that will be granted admin AND operator roles.
     * @param operator The address that will be granted operator role to execute the staking process.
     */
    function initialize(
        address _fatBera,
        address _wBera,
        address _beaconDeposit,
        bytes memory _validatorPubkey,
        bytes memory _withdrawalCredentials,
        bytes memory _validatorSignature,
        address _validatorOperator,
        address operatorAdmin,
        address operator
    ) external initializer {
        if (_fatBera == address(0) || 
            _wBera == address(0) || 
            _beaconDeposit == address(0) || 
            operatorAdmin == address(0) ||
            operator == address(0)
        ) {
            revert InvalidAddress();
        }

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        fatBera = _fatBera;
        wBera = _wBera;
        beaconDeposit = _beaconDeposit;
        validatorPubkey = _validatorPubkey;
        withdrawalCredentials = _withdrawalCredentials;
        validatorSignature = _validatorSignature;
        validatorOperator = _validatorOperator;

        // Set initial minimum stake amount to 15,000 WBERA (15,000 * 10^18)
        minimumStakeAmount = 15_000 ether;

        // Set up roles - DEFAULT_ADMIN_ROLE for multisig, OPERATOR_ROLE for automated operator
        _grantRole(DEFAULT_ADMIN_ROLE, operatorAdmin);
        _grantRole(OPERATOR_ROLE, operatorAdmin);
        _grantRole(OPERATOR_ROLE, operator);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      EXTERNAL FUNCTIONS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Executes the process to withdraw principal from fatBERA, unwrap WBERA to native BERA,
     * and deposit it to the beacon deposit contract.
     * @dev This function is protected by the OPERATOR_ROLE and reentrancy guard.
     * @param amount The exact amount to withdraw and stake. Must be >= minimumStakeAmount and <= current deposit principal
     */
    function executeWithdrawUnwrapAndStake(uint256 amount) external onlyRole(OPERATOR_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount < minimumStakeAmount) {
            revert InsufficientStakeAmount(amount, minimumStakeAmount);
        }

        // Step 1: Withdraw principal from fatBERA.
        IFatBera(fatBera).withdrawPrincipal(amount, address(this));

        // Step 2: Unwrap WBERA to native BERA.
        IWETH(wBera).withdraw(amount);

        // Step 3: Stake to the validator via the beacon deposit contract.
        IBeaconDeposit(beaconDeposit).deposit{value: amount}(
            validatorPubkey,
            withdrawalCredentials,
            validatorSignature,
            validatorOperator
        );

        emit WithdrawUnwrapAndStakeExecuted(amount, validatorPubkey);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ADMIN FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Admin function to update the validator public key.
     * @param newPubkey New validator public key
     * @dev This is the most commonly updated parameter when adding new validators
     */
    function setValidatorPubkey(bytes calldata newPubkey) external onlyRole(DEFAULT_ADMIN_ROLE) {
        validatorPubkey = newPubkey;
        emit ValidatorPubkeyUpdated(newPubkey);
    }

    /**
     * @notice Admin function to update the withdrawal credentials.
     * @param newWithdrawalCredentials New withdrawal credentials
     * @dev This should rarely need to be updated as it's typically the same for all validators
     */
    function setWithdrawalCredentials(bytes calldata newWithdrawalCredentials) external onlyRole(DEFAULT_ADMIN_ROLE) {
        withdrawalCredentials = newWithdrawalCredentials;
        emit WithdrawalCredentialsUpdated(newWithdrawalCredentials);
    }

    /**
     * @notice Admin function to update the validator signature.
     * @param newSignature New validator signature
     */
    function setValidatorSignature(bytes calldata newSignature) external onlyRole(DEFAULT_ADMIN_ROLE) {
        validatorSignature = newSignature;
        emit ValidatorSignatureUpdated(newSignature);
    }

    /**
     * @notice Admin function to update the validator operator address.
     * @param newOperator New validator operator address
     */
    function setValidatorOperator(address newOperator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOperator == address(0)) revert InvalidAddress();
        validatorOperator = newOperator;
        emit ValidatorOperatorUpdated(newOperator);
    }

    /**
     * @notice Admin function to update the minimum stake amount.
     * @param newAmount The new minimum amount required for staking
     * @dev This function can only be called by the admin (multisig)
     */
    function setMinimumStakeAmount(uint256 newAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAmount == 0) revert ZeroAmount();
        minimumStakeAmount = newAmount;
        emit MinimumStakeAmountUpdated(newAmount);
    }

    /**
     * @notice Admin function to rescue any accidentally sent native funds.
     * @param recipient The address to forward the rescued funds.
     * @dev This function should only be used in emergency situations.
     */
    function rescueFunds(address payable recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidAddress();
        
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoFundsToRescue();
        
        (bool success, ) = recipient.call{value: balance}("");
        if (!success) revert TransferFailed();
        
        emit FundsRescued(recipient, balance);
    }

    /**
     * @notice Admin function to rescue any ERC20 tokens (including WBERA) that are stuck in the contract.
     * @param token The address of the token to rescue
     * @param recipient The address to receive the tokens
     * @param amount The amount of tokens to rescue
     * @dev This function should only be used in emergency situations.
     */
    function rescueTokens(
        address token,
        address recipient,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();

        bool success = IERC20(token).transfer(recipient, amount);
        if (!success) revert TransferFailed();

        emit TokensRescued(token, recipient, amount);
    }    

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      INTERNAL FUNCTIONS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      RECEIVE & FALLBACK                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Allow the contract to receive native BERA.
     */
    receive() external payable {}

    /**
     * @notice Allow the contract to receive native BERA (fallback).
     */
    fallback() external payable {}
}
