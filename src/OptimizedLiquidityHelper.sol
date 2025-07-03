// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                          INTERFACES                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface IFatBERA is IERC20 {
    function depositNative(address receiver) external payable returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
}

interface IXfatBERA is IERC20 {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
}

interface IKodiakIsland {
    function getMintAmounts(uint256 amount0Max, uint256 amount1Max) 
        external view returns (uint256 amount0, uint256 amount1, uint256 mintAmount);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IKodiakIslandRouter {
    struct RouterSwapParams {
        bool zeroForOne;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes routeData;
    }

    function addLiquidity(
        address island,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 amountSharesMin,
        address receiver
    ) external returns (uint256 amount0, uint256 amount1, uint256 mintAmount);
}

/**
 * @title OptimizedLiquidityHelper
 * @notice Helper contract for optimally zapping single assets into xfatBERA/WBERA LP
 * @dev Instead of buying xfatBERA from the pool, this contract mints xfatBERA directly
 *      by depositing to fatBERA first, then wrapping to xfatBERA. This avoids swap fees and slippage.
 *      
 *      UPGRADEABLE: This contract is upgradeable using the UUPS pattern. Only the owner can
 *      authorize upgrades. Deploy using a proxy contract and call initialize() instead of
 *      the constructor.
 */
contract OptimizedLiquidityHelper is Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          ERRORS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error ZeroAmount();
    error InvalidReceiver();
    error InsufficientOutput();
    error TransferFailed();
    error InvalidSlippage();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EVENTS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event OptimizedLiquidityAdded(
        address indexed user,
        address indexed island,
        uint256 inputAmount,
        uint256 fatBeraDeposited,
        uint256 xfatBeraAmount,
        uint256 wberaAmount,
        uint256 lpTokens
    );

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    IWETH public WBERA;
    IFatBERA public fatBERA;
    IXfatBERA public xfatBERA;
    IKodiakIslandRouter public router;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          CONSTRUCTOR                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _wbera,
        address _fatBERA,
        address _xfatBERA,
        address _router,
        address _owner
    ) public initializer {
        __ReentrancyGuard_init();
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();

        WBERA = IWETH(_wbera);
        fatBERA = IFatBERA(_fatBERA);
        xfatBERA = IXfatBERA(_xfatBERA);
        router = IKodiakIslandRouter(_router);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EXTERNAL FUNCTIONS                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Optimally zap native BERA into xfatBERA/WBERA LP
     * @param island The Kodiak Island (LP) contract address
     * @param minLpTokens Minimum LP tokens to receive (slippage protection)
     * @param slippageBPS Maximum slippage tolerance in basis points (100 = 1%)
     * @param receiver Address to receive the LP tokens
     * @return lpTokens Amount of LP tokens received
     */
    function zapNativeBERA(
        address island,
        uint256 minLpTokens,
        uint256 slippageBPS,
        address receiver
    ) external payable nonReentrant returns (uint256 lpTokens) {
        if (msg.value == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidReceiver();
        if (slippageBPS > 10000) revert InvalidSlippage();

        // Wrap native BERA to WBERA
        WBERA.deposit{value: msg.value}();

        return _zapWBERA(island, msg.value, minLpTokens, slippageBPS, receiver);
    }

    /**
     * @notice Optimally zap WBERA into xfatBERA/WBERA LP
     * @param island The Kodiak Island (LP) contract address
     * @param wberaAmount Amount of WBERA to zap
     * @param minLpTokens Minimum LP tokens to receive (slippage protection)
     * @param slippageBPS Maximum slippage tolerance in basis points (100 = 1%)
     * @param receiver Address to receive the LP tokens
     * @return lpTokens Amount of LP tokens received
     */
    function zapWBERA(
        address island,
        uint256 wberaAmount,
        uint256 minLpTokens,
        uint256 slippageBPS,
        address receiver
    ) external nonReentrant returns (uint256 lpTokens) {
        if (wberaAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidReceiver();
        if (slippageBPS > 10000) revert InvalidSlippage();

        // Transfer WBERA from user
        IERC20(address(WBERA)).safeTransferFrom(msg.sender, address(this), wberaAmount);

        return _zapWBERA(island, wberaAmount, minLpTokens, slippageBPS, receiver);
    }

    /**
     * @notice Calculate optimal split for zapping WBERA into xfatBERA/WBERA LP
     * @param island The Kodiak Island (LP) contract address
     * @param wberaAmount Total WBERA amount to zap
     * @return fatBeraDepositAmount Amount to deposit to fatBERA
     * @return remainingWberaAmount Amount to keep as WBERA for LP
     * @return expectedLpTokens Expected LP tokens to receive
     */
    function calculateOptimalSplit(
        address island,
        uint256 wberaAmount
    ) external view returns (
        uint256 fatBeraDepositAmount,
        uint256 remainingWberaAmount,
        uint256 expectedLpTokens
    ) {
        return _calculateOptimalSplit(island, wberaAmount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          INTERNAL FUNCTIONS                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Internal function to zap WBERA into xfatBERA/WBERA LP
     * @param island The Kodiak Island (LP) contract address
     * @param wberaAmount Amount of WBERA to zap
     * @param minLpTokens Minimum LP tokens to receive
     * @param slippageBPS Maximum slippage tolerance in basis points (100 = 1%)
     * @param receiver Address to receive the LP tokens
     * @return lpTokens Amount of LP tokens received
     */
    function _zapWBERA(
        address island,
        uint256 wberaAmount,
        uint256 minLpTokens,
        uint256 slippageBPS,
        address receiver
    ) internal returns (uint256 lpTokens) {
        // Calculate optimal split
        (
            uint256 fatBeraDepositAmount,
            uint256 remainingWberaAmount,
            uint256 expectedLpTokens
        ) = _calculateOptimalSplit(island, wberaAmount);

        // Step 1: Deposit portion to fatBERA
        IERC20(address(WBERA)).approve(address(fatBERA), fatBeraDepositAmount);
        uint256 fatBeraShares = fatBERA.deposit(fatBeraDepositAmount, address(this));

        // Step 2: Wrap fatBERA to xfatBERA
        IERC20(address(fatBERA)).approve(address(xfatBERA), fatBeraShares);
        uint256 xfatBeraShares = xfatBERA.deposit(fatBeraShares, address(this));

        // Step 3: Add liquidity with xfatBERA + remaining WBERA
        uint256 amount0Min = (xfatBeraShares * (10000 - slippageBPS)) / 10000;
        uint256 amount1Min = (remainingWberaAmount * (10000 - slippageBPS)) / 10000;
        uint256 minShares = (expectedLpTokens * (10000 - slippageBPS)) / 10000;
        
        // Ensure we meet the user's minimum requirement
        if (minShares < minLpTokens) {
            minShares = minLpTokens;
        }

        // Approve router to spend tokens for liquidity addition
        IERC20(address(WBERA)).approve(address(router), remainingWberaAmount);
        IERC20(address(xfatBERA)).approve(address(router), xfatBeraShares);

        // For xfatBERA/WBERA island: WBERA is token0, xfatBERA is token1
        (uint256 amount0, uint256 amount1, uint256 mintAmount) = router.addLiquidity(
            island,
            remainingWberaAmount, // amount0Max (WBERA)
            xfatBeraShares,      // amount1Max (xfatBERA)
            amount1Min,          // amount0Min (WBERA)
            amount0Min,          // amount1Min (xfatBERA)
            minShares,           // amountSharesMin
            receiver             // receiver
        );

        // Refund any unused tokens to the user
        uint256 unusedWbera = remainingWberaAmount - amount0;
        uint256 unusedXfatBera = xfatBeraShares - amount1;

        if (unusedXfatBera > 0) {
            IERC20(address(xfatBERA)).safeTransfer(receiver, unusedXfatBera);
        }
        if (unusedWbera > 0) {
            IERC20(address(WBERA)).safeTransfer(receiver, unusedWbera);
        }

        emit OptimizedLiquidityAdded(
            msg.sender,
            island,
            wberaAmount,
            fatBeraDepositAmount,
            xfatBeraShares,
            remainingWberaAmount,
            mintAmount
        );

        return mintAmount;
    }

    /**
     * @notice Calculate optimal split for zapping WBERA into xfatBERA/WBERA LP
     * @param island The Kodiak Island (LP) contract address
     * @param wberaAmount Total WBERA amount to zap
     * @return fatBeraDepositAmount Amount to deposit to fatBERA
     * @return remainingWberaAmount Amount to keep as WBERA for LP
     * @return expectedLpTokens Expected LP tokens to receive
     */
    function _calculateOptimalSplit(
        address island,
        uint256 wberaAmount
    ) internal view returns (
        uint256 fatBeraDepositAmount,
        uint256 remainingWberaAmount,
        uint256 expectedLpTokens
    ) {
        // Step 1: Get the island ratio between xfatBERA and WBERA
        uint256 oneEther = 1 ether;
        (uint256 amount0Used, uint256 amount1Used, ) = IKodiakIsland(island).getMintAmounts(oneEther, oneEther);
        
        // For xfatBERA/WBERA island: WBERA is token0, xfatBERA is token1
        uint256 wberaAmountInPool = amount0Used;
        uint256 xfatBeraAmountInPool = amount1Used;
        
        // Step 2: Get xfatBERA exchange rate (how much xfatBERA we get for 1 fatBERA)
        // Since fatBERA deposits 1:1 with WBERA, this tells us WBERA -> xfatBERA rate
        uint256 xfatBeraPerWbera = xfatBERA.previewDeposit(oneEther);
        
        // Step 3: Calculate optimal split
        // We want: xfatBeraAmountInPool / wberaAmountInPool = xfatBeraToDeposit / wberaToKeep
        // Where: xfatBeraToDeposit = fatBeraDepositAmount * xfatBeraPerWbera / oneEther
        // And: fatBeraDepositAmount + wberaToKeep = wberaAmount
        
        // Substituting and solving:
        // xfatBeraAmountInPool / wberaAmountInPool = (fatBeraDepositAmount * xfatBeraPerWbera / oneEther) / (wberaAmount - fatBeraDepositAmount)
        // Cross multiply and solve for fatBeraDepositAmount:
        
        uint256 denominator = wberaAmountInPool * xfatBeraPerWbera + xfatBeraAmountInPool * oneEther;
        fatBeraDepositAmount = FixedPointMathLib.mulDiv(
            wberaAmount * xfatBeraAmountInPool, 
            oneEther, 
            denominator
        );
        remainingWberaAmount = wberaAmount - fatBeraDepositAmount;
        
        // Step 4: Calculate expected xfatBERA output
        uint256 expectedXfatBera = FixedPointMathLib.mulDiv(
            fatBeraDepositAmount, 
            xfatBeraPerWbera, 
            oneEther
        );
        
        // Step 5: Estimate expected LP tokens (WBERA is token0, xfatBERA is token1)
        (, , expectedLpTokens) = IKodiakIsland(island).getMintAmounts(remainingWberaAmount, expectedXfatBera);
        
        return (fatBeraDepositAmount, remainingWberaAmount, expectedLpTokens);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          RECOVERY FUNCTIONS                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Emergency function to recover stuck tokens
     * @param token Token address to recover
     * @param amount Amount to recover
     * @param to Address to send tokens to
     */
    function recoverTokens(address token, uint256 amount, address to) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Emergency function to recover stuck native tokens
     * @param to Address to send native tokens to
     */
    function recoverNative(address payable to) external onlyOwner {
        to.transfer(address(this).balance);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          UPGRADE FUNCTIONS                 */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Authorize upgrade (only owner can upgrade)
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          RECEIVE FUNCTIONS                 */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    receive() external payable {}
} 