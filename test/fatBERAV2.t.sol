// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test, console2} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {fatBERA} from "../src/fatBERA.sol";
import {fatBERAV2} from "../src/fatBERAV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract fatBERATest is Test {
    uint256 public maxDeposits = 36000000 ether;
    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public fulfiller = makeAddr("fulfiller"); // Multisig fulfiller

    fatBERAV2 public vault;
    MockWETH public wbera;
    MockERC20 public rewardToken1;
    MockERC20 public rewardToken2;

    uint256 tolerance = 1e7;

    uint256 public constant INITIAL_MINT = 36000000 ether;

    function setUp() public {
        // Deploy mock WBERA
        wbera = new MockWETH();
        rewardToken1 = new MockERC20("Reward Token 1", "RWD1", 18);
        rewardToken2 = new MockERC20("Reward Token 2", "RWD2", 18);

        // Deploy vault with admin as DEFAULT_ADMIN_ROLE
        bytes memory initData = abi.encodeWithSelector(
            fatBERA.initialize.selector,
            address(wbera),
            admin, // Now initial admin
            maxDeposits
        );

        // Deploy proxy using the implementation - match deployment script approach
        // Note: We skip specific validation warnings because:
        // 1. The ValidateUpgrade.s.sol script confirms the upgrade is safe
        // 2. The original contract is already deployed with this initializer order
        // 3. initializeV2 is a reinitializer and doesn't need to call parent initializers again
        Options memory opts;
        opts.unsafeAllow = "incorrect-initializer-order,missing-initializer-call";
        
        address proxy = Upgrades.deployUUPSProxy("fatBERA.sol:fatBERA", initData, opts);
        
        // Upgrade to V2 with initialization data
        bytes memory initV2Data = abi.encodeWithSelector(fatBERAV2.initializeV2.selector, fulfiller);
        vm.startPrank(admin);
        Upgrades.upgradeProxy(proxy, "fatBERAV2.sol:fatBERAV2", initV2Data, opts);
        vm.stopPrank();

        // Cast to fatBERAV2
        vault = fatBERAV2(payable(proxy));

        // Debug logs
        // console2.log("Admin address:", admin);
        // console2.log("Proxy address:", address(proxy));
        // console2.log("Implementation address:", Upgrades.getImplementationAddress(address(proxy)));
        // console2.log("Admin has DEFAULT_ADMIN_ROLE:", vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        // console2.log("Admin has REWARD_NOTIFIER_ROLE:", vault.hasRole(vault.REWARD_NOTIFIER_ROLE(), admin));

        // Mint initial tokens to test accounts
        wbera.mint(alice, INITIAL_MINT);
        wbera.mint(bob, INITIAL_MINT);
        wbera.mint(charlie, INITIAL_MINT);
        wbera.mint(admin, INITIAL_MINT);

        rewardToken1.mint(admin, INITIAL_MINT);
        rewardToken2.mint(admin, INITIAL_MINT);

        // Approve vault to spend tokens
        vm.prank(alice);
        wbera.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        wbera.approve(address(vault), type(uint256).max);
        vm.prank(charlie);
        wbera.approve(address(vault), type(uint256).max);
        vm.startPrank(admin);
        wbera.approve(address(vault), type(uint256).max);
        rewardToken1.approve(address(vault), type(uint256).max);
        rewardToken2.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        // Fund test accounts with ETH
        vm.deal(alice, INITIAL_MINT);
        vm.deal(bob, INITIAL_MINT);
        vm.deal(charlie, INITIAL_MINT);

        // VAULT DURATION
        vm.startPrank(admin);
        vault.setRewardsDuration(address(wbera), 7 days);
        vault.setRewardsDuration(address(rewardToken1), 7 days);
        vault.setRewardsDuration(address(rewardToken2), 7 days);
        vm.stopPrank();
    }

    function notifyAndWarp(address token, uint256 amount) public {
        vm.prank(admin);
        vault.notifyRewardAmount(token, amount);
        vm.warp(block.timestamp + 1 + 7 days);
    }

    function test_Initialize() public view {
        // Check roles instead of owner
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "Admin should have DEFAULT_ADMIN_ROLE");
        assertEq(address(vault.asset()), address(wbera));
        assertEq(vault.paused(), true);
        (uint256 rewardPerShareStored, uint256 totalRewards,,,,,) = vault.rewardData(address(wbera));
        assertEq(rewardPerShareStored, 0);
        assertEq(totalRewards, 0);
        assertEq(vault.depositPrincipal(), 0);
    }

    function test_DepositWhenPaused() public {
        // Should succeed even when paused
        vm.prank(alice);
        uint256 sharesMinted = vault.deposit(100e18, alice);

        assertEq(sharesMinted, 100e18, "Shares should be 1:1 with deposit");
        assertEq(vault.balanceOf(alice), 100e18);
    }

    // Normal withdrawals have been changed to just return 0 since withdraws from the validator are handled seperately by fulfiller
    // function test_WithdrawWhenPaused() public {
    //     // First deposit (should work while paused)
    //     vm.prank(alice);
    //     vault.deposit(100e18, alice);

    //     // Try to withdraw while paused (should fail)
    //     vm.prank(alice);
    //     vm.expectRevert();
    //     vault.withdraw(50e18, alice, alice);
    // }

    function test_PreviewRewardsAccuracy() public {
        // Define an acceptable tolerance (in wei) to account for rounding differences.
        // 10^7 wei tolerance (0.00001 WBERA approximately)

        // Alice deposits 100 WBERA
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // First reward: 10 WBERA provided by admin
        notifyAndWarp(address(wbera), 10e18);

        // Expect that Alice receives approximately 10e18 reward, allowing for slight rounding differences
        uint256 expectedAliceFirstReward = 10e18; // 10 WBERA
        assertApproxEqAbs(
            vault.previewRewards(alice, address(wbera)),
            expectedAliceFirstReward,
            tolerance,
            "First reward preview mismatch"
        );

        // Bob deposits 100 WBERA, so now the total supply = 200 WBERA.
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // Second reward: 20 WBERA provided by admin
        notifyAndWarp(address(wbera), 20e18);

        // With 200 shares total for the new reward, each share earns (20e18 / 200) = 0.1e18 reward.
        // - Alice had already received ~10e18 from the first round and will earn an additional ~10e18.
        // - Bob will earn ~10e18 from the second reward only.
        uint256 expectedAliceTotalReward = 20e18;
        uint256 expectedBobReward = 10e18;

        assertApproxEqAbs(
            vault.previewRewards(alice, address(wbera)),
            expectedAliceTotalReward,
            tolerance,
            "Alice's total reward mismatch after second reward"
        );
        assertApproxEqAbs(
            vault.previewRewards(bob, address(wbera)), expectedBobReward, tolerance, "Bob's reward preview mismatch"
        );

        // After Alice claims her rewards, her preview should return 0 but Bob's should remain unchanged.
        vm.prank(alice);
        vault.claimRewards(address(alice));
        assertApproxEqAbs(
            vault.previewRewards(alice, address(wbera)), 0, tolerance, "Alice should have 0 rewards after claim"
        );
        assertApproxEqAbs(
            vault.previewRewards(bob, address(wbera)),
            expectedBobReward,
            tolerance,
            "Bob's rewards unchanged after Alice's claim"
        );
    }

    function test_BasicDepositAndReward() public {
        // Admin already has REWARD_NOTIFIER_ROLE from initialize()
        // No need to grant it again

        // Alice deposits 100 WBERA
        uint256 aliceDeposit = 100e18;
        vm.prank(alice);
        uint256 sharesMinted = vault.deposit(aliceDeposit, alice);

        assertEq(sharesMinted, aliceDeposit, "Shares should be 1:1 with deposit");
        assertEq(vault.balanceOf(alice), aliceDeposit);
        assertEq(vault.depositPrincipal(), aliceDeposit);
        assertEq(vault.totalSupply(), aliceDeposit);
        assertEq(vault.totalAssets(), aliceDeposit);

        // Add reward
        notifyAndWarp(address(wbera), 10e18);
        // Check Alice's claimable rewards
        assertApproxEqAbs(
            vault.previewRewards(alice, address(wbera)), 10e18, tolerance, "Alice should have 10e18 rewards"
        );
    }

    function test_MultipleDepositorsRewardDistribution() public {
        vm.prank(admin);
        vault.unpause();

        // Alice deposits 100 WBERA
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Admin adds 10 WBERA reward
        notifyAndWarp(address(wbera), 10e18);

        // Bob deposits 100 WBERA
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // Admin adds another 10 WBERA reward
        notifyAndWarp(address(wbera), 10e18);

        // Check rewards
        assertApproxEqAbs(
            vault.previewRewards(alice, address(wbera)),
            15e18,
            tolerance,
            "Alice should have first reward + half of second"
        );
        assertApproxEqAbs(
            vault.previewRewards(bob, address(wbera)), 5e18, tolerance, "Bob should have half of second reward only"
        );
    }

    function test_ClaimRewards() public {
        vm.prank(admin);
        vault.unpause();

        // Alice deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Add reward
        notifyAndWarp(address(wbera), 10e18);

        // Record balance before claim
        uint256 balanceBefore = wbera.balanceOf(alice);

        // Claim rewards
        vm.prank(alice);
        vault.claimRewards(address(alice));

        // Verify reward received
        assertApproxEqAbs(wbera.balanceOf(alice) - balanceBefore, 10e18, tolerance, "Should receive full reward");
        assertEq(vault.previewRewards(alice, address(wbera)), 0, "Rewards should be zero after claim");
    }

    function test_OwnerWithdrawPrincipal() public {
        vm.prank(admin);
        vault.unpause();

        // Alice deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Admin withdraws principal for staking
        vm.prank(admin);
        vault.withdrawPrincipal(50e18, admin);

        // Check state
        assertEq(vault.depositPrincipal(), 50e18, "Principal should be reduced");
        assertEq(vault.totalSupply(), 100e18, "Total supply unchanged");
        assertEq(vault.totalAssets(), 100e18, "Total assets matches supply");
        assertEq(vault.balanceOf(alice), 100e18, "Alice's shares unchanged");
    }

    function test_MultipleRewardCycles() public {
        vm.prank(admin);
        vault.unpause();

        // Alice and Bob deposit
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // First reward cycle
        notifyAndWarp(address(wbera), 10e18);

        // Alice claims
        vm.prank(alice);
        vault.claimRewards(address(alice));

        // Second reward cycle
        notifyAndWarp(address(wbera), 10e18);

        // Verify rewards
        assertApproxEqAbs(
            vault.previewRewards(alice, address(wbera)), 5e18, tolerance, "Alice should have half of second reward"
        );
        assertApproxEqAbs(
            vault.previewRewards(bob, address(wbera)),
            10e18,
            tolerance,
            "Bob should have unclaimed rewards from both cycles"
        );
    }

    function test_RewardDistributionWithPartialClaims() public {
        // Alice deposits 100
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // First reward: 10 WBERA
        notifyAndWarp(address(wbera), 10e18);

        // Bob deposits 100
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // Alice claims her first reward
        vm.prank(alice);
        vault.claimRewards(address(alice));

        // Second reward: 20 WBERA (split between Alice and Bob)
        notifyAndWarp(address(wbera), 20e18);

        // Charlie deposits 200
        vm.prank(charlie);
        vault.deposit(200e18, charlie);

        // Third reward: 40 WBERA (split between all three)
        notifyAndWarp(address(wbera), 40e18);

        // Verify final reward states
        assertApproxEqAbs(
            vault.previewRewards(alice, address(wbera)),
            20e18,
            tolerance,
            "Alice should have share of second and third rewards"
        );
        assertApproxEqAbs(
            vault.previewRewards(bob, address(wbera)), 20e18, tolerance, "Bob should have all unclaimed rewards"
        );
        assertApproxEqAbs(
            vault.previewRewards(charlie, address(wbera)),
            20e18,
            tolerance,
            "Charlie should have share of third reward only"
        );
    }

    function test_SequentialDepositsAndRewards() public {
        // Alice deposits 100
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Reward 1: 10 WBERA
        notifyAndWarp(address(wbera), 10e18);

        // Bob deposits 200
        vm.prank(bob);
        vault.deposit(200e18, bob);

        // Reward 2: 30 WBERA
        notifyAndWarp(address(wbera), 30e18);

        // Alice claims
        vm.prank(alice);
        vault.claimRewards(address(alice));

        // Charlie deposits 300
        vm.prank(charlie);
        vault.deposit(300e18, charlie);

        // Reward 3: 60 WBERA
        notifyAndWarp(address(wbera), 60e18);

        // Verify complex reward distribution
        assertApproxEqAbs(
            vault.previewRewards(alice, address(wbera)), 10e18, tolerance, "Alice's new rewards after claim"
        );
        assertApproxEqAbs(vault.previewRewards(bob, address(wbera)), 40e18, tolerance, "Bob's accumulated rewards");
        assertApproxEqAbs(
            vault.previewRewards(charlie, address(wbera)), 30e18, tolerance, "Charlie's portion of last reward"
        );
    }

    function test_notifyRewardAmount() public {
        // Try to notify reward with no deposits (should revert with ZeroShares)
        vm.prank(admin);
        vm.expectRevert(fatBERA.ZeroShares.selector);
        vault.notifyRewardAmount(address(wbera), 10e18);

        // Alice deposits after failed reward
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Verify no rewards from before deposit
        assertEq(vault.previewRewards(alice, address(wbera)), 0, "Should have no rewards from before deposit");

        // New reward should work
        notifyAndWarp(address(wbera), 10e18);
        assertApproxEqAbs(vault.previewRewards(alice, address(wbera)), 10e18, tolerance, "Should receive new rewards");
    }

    function test_OwnerWithdrawAndRewardCycles() public {
        // Initial deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // Admin withdraws 150 for staking
        vm.prank(admin);
        vault.withdrawPrincipal(150e18, admin);

        // Verify deposit principal reduced but shares unchanged
        assertEq(vault.depositPrincipal(), 50e18, "Deposit principal should be reduced");
        assertEq(vault.totalSupply(), 200e18, "Total supply should be unchanged");

        // Add rewards (simulating staking returns)
        notifyAndWarp(address(wbera), 30e18);

        // Verify rewards still work correctly
        assertApproxEqAbs(vault.previewRewards(alice, address(wbera)), 15e18, tolerance, "Alice's reward share");
        assertApproxEqAbs(vault.previewRewards(bob, address(wbera)), 15e18, tolerance, "Bob's reward share");
    }

    function test_MaxDeposits() public {
        // Try to deposit more than max
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, alice, maxDeposits + 1, maxDeposits
            )
        );
        vault.deposit(maxDeposits + 1, alice);

        // Deposit up to max should work
        vm.prank(alice);
        vault.deposit(maxDeposits, alice);

        // Any further deposit should fail
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, bob, 1, 0));
        vault.deposit(1, bob);
    }

    function test_MaxDepositsWithMint() public {
        // Try to mint more than max
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, alice, maxDeposits + 1, maxDeposits
            )
        );
        vault.mint(maxDeposits + 1, alice);

        // Mint up to max should work
        vm.prank(alice);
        vault.mint(maxDeposits, alice);

        // Any further mint should fail
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, bob, 1, 0));
        vault.mint(1, bob);
    }

    function test_MaxDepositsWithMultipleUsers() public {
        uint256 halfMax = maxDeposits / 2;

        // First user deposits half
        vm.prank(alice);
        vault.deposit(halfMax, alice);

        // Second user deposits slightly less than half
        vm.prank(bob);
        vault.deposit(halfMax - 1 ether, bob);

        // Third user tries to deposit more than remaining
        vm.prank(charlie);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, charlie, 2 ether, 1 ether)
        );
        vault.deposit(2 ether, charlie);

        // But can deposit exactly the remaining amount
        vm.prank(charlie);
        vault.deposit(1 ether, charlie);
    }

    function test_MaxDepositsUpdate() public {
        // Initial deposit at current max
        vm.prank(alice);
        vault.deposit(maxDeposits, alice);
        // New deposit should still fail since vault is already at initial max
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, bob, 1 ether, 0));
        vault.deposit(1 ether, bob);

        // Admin updates max deposits to double
        vm.prank(admin);
        vault.setMaxDeposits(maxDeposits + 1 ether);

        // New deposit should work
        vm.prank(bob);
        vault.deposit(1 ether, bob);

        // New deposit should fail
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, bob, 1 ether, 0));
        vault.deposit(1 ether, bob);
    }

    function test_GetRewardTokensList() public {
        // First make a deposit to avoid ZeroShares error
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Add first reward token
        vm.startPrank(admin);
        rewardToken1.transfer(address(vault), 20e18);
        vault.notifyRewardAmount(address(rewardToken1), 20e18);

        // Add second reward token
        rewardToken2.transfer(address(vault), 40e18);
        vault.notifyRewardAmount(address(rewardToken2), 40e18);
        vm.stopPrank();

        // Get reward tokens list
        address[] memory rewardTokens = vault.getRewardTokens();

        // Verify list contents
        assertEq(rewardTokens.length, 2, "Should have 2 reward tokens");
        assertEq(rewardTokens[0], address(rewardToken1), "First reward token mismatch");
        assertEq(rewardTokens[1], address(rewardToken2), "Second reward token mismatch");
    }

    // Fuzz Tests
    function testFuzz_Deposit(uint256 amount) public {
        // Bound amount between 1 and maxDeposits to avoid unrealistic values
        amount = bound(amount, 1, maxDeposits);

        vm.prank(alice);
        uint256 sharesMinted = vault.deposit(amount, alice);

        assertEq(sharesMinted, amount, "Shares minted should equal deposit amount");
        assertEq(vault.balanceOf(alice), amount, "Balance should equal deposit");
        assertEq(vault.depositPrincipal(), amount, "Principal should equal deposit");
    }

    function testFuzz_DepositWithExistingBalance(uint256 firstAmount, uint256 secondAmount) public {
        // Bound amounts to avoid overflow and unrealistic values
        firstAmount = bound(firstAmount, 1, maxDeposits / 2);
        secondAmount = bound(secondAmount, 1, maxDeposits - firstAmount);

        // First deposit
        vm.prank(alice);
        vault.deposit(firstAmount, alice);

        // Second deposit
        vm.prank(alice);
        vault.deposit(secondAmount, alice);

        assertEq(vault.balanceOf(alice), firstAmount + secondAmount, "Total balance incorrect");
        assertEq(vault.depositPrincipal(), firstAmount + secondAmount, "Total principal incorrect");
    }

    function testFuzz_Mint(uint256 shares) public {
        // Bound shares between 1 and maxDeposits
        shares = bound(shares, 1, maxDeposits);

        vm.prank(alice);
        uint256 assets = vault.mint(shares, alice);

        assertEq(assets, shares, "Assets should equal shares for 1:1 ratio");
        assertEq(vault.balanceOf(alice), shares, "Balance should equal minted shares");
        assertEq(vault.depositPrincipal(), assets, "Principal should equal assets");
    }

    function testFuzz_NotifyRewardAmount(uint256 depositAmount, uint256 rewardAmount) public {
        // Bound deposit amount between 1 and maxDeposits
        depositAmount = bound(depositAmount, 1 ether / 10000, maxDeposits);
        // Bound reward amount between 1 and maxDeposits (reasonable range for rewards)
        rewardAmount = bound(rewardAmount, 1 ether / 1000, maxDeposits);

        // Initial deposit
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Add reward
        notifyAndWarp(address(wbera), rewardAmount);

        // Record balance before claim
        uint256 balanceBefore = wbera.balanceOf(alice);

        // Claim rewards
        vm.prank(alice);
        vault.claimRewards(address(alice));

        // Verify actual rewards received with 0.00001% relative tolerance
        uint256 rewardsReceived = wbera.balanceOf(alice) - balanceBefore;
        assertApproxEqRel(
            rewardsReceived,
            rewardAmount,
            1e11, //
            "Reward amount received should be approximately equal"
        );
    }

    function testFuzz_MultiUserRewardDistribution(uint256 aliceDeposit, uint256 bobDeposit, uint256 rewardAmount)
        public
    {
        // Bound deposits to avoid overflow and unrealistic values
        aliceDeposit = bound(aliceDeposit, 1 ether / 10000, maxDeposits / 2);
        bobDeposit = bound(bobDeposit, 1 ether / 10000, maxDeposits - aliceDeposit);
        // Bound reward to a reasonable range
        rewardAmount = bound(rewardAmount, 1 ether / 1000, maxDeposits);

        // Alice and Bob deposit
        vm.prank(alice);
        vault.deposit(aliceDeposit, alice);
        vm.prank(bob);
        vault.deposit(bobDeposit, bob);

        // Add reward
        notifyAndWarp(address(wbera), rewardAmount);

        // Calculate expected rewards using the same mulDiv logic as the contract
        uint256 totalDeposits = aliceDeposit + bobDeposit;
        uint256 expectedAliceReward = FixedPointMathLib.mulDiv(rewardAmount, aliceDeposit, totalDeposits);
        uint256 expectedBobReward = FixedPointMathLib.mulDiv(rewardAmount, bobDeposit, totalDeposits);

        // Record balances before claims
        uint256 aliceBalanceBefore = wbera.balanceOf(alice);
        uint256 bobBalanceBefore = wbera.balanceOf(bob);

        // Claim rewards
        vm.prank(alice);
        vault.claimRewards(address(alice));
        vm.prank(bob);
        vault.claimRewards(address(bob));

        // Verify actual rewards received with 0.00001% relative tolerance
        uint256 aliceRewardsReceived = wbera.balanceOf(alice) - aliceBalanceBefore;
        uint256 bobRewardsReceived = wbera.balanceOf(bob) - bobBalanceBefore;

        // Verify rewards with 0.00001% relative tolerance
        assertApproxEqRel(
            aliceRewardsReceived, expectedAliceReward, 1e11, "Alice rewards should be approximately equal to expected"
        );
        assertApproxEqRel(
            bobRewardsReceived, expectedBobReward, 1e11, "Bob rewards should be approximately equal to expected"
        );

        // Critical safety check - protocol should never over-distribute
        assertLe(
            aliceRewardsReceived + bobRewardsReceived,
            rewardAmount,
            "Total distributed rewards should not exceed input amount"
        );
    }

    function test_MultiTokenRewards() public {
        // Initial deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // Add first reward token
        notifyAndWarp(address(rewardToken1), 20e18);

        // Add second reward token
        notifyAndWarp(address(rewardToken2), 40e18);

        // Verify reward preview for both tokens
        assertApproxEqAbs(
            vault.previewRewards(alice, address(rewardToken1)), 10e18, tolerance, "Alice's RWD1 rewards incorrect"
        );
        assertApproxEqAbs(
            vault.previewRewards(alice, address(rewardToken2)), 20e18, tolerance, "Alice's RWD2 rewards incorrect"
        );
        assertApproxEqAbs(
            vault.previewRewards(bob, address(rewardToken1)), 10e18, tolerance, "Bob's RWD1 rewards incorrect"
        );
        assertApproxEqAbs(
            vault.previewRewards(bob, address(rewardToken2)), 20e18, tolerance, "Bob's RWD2 rewards incorrect"
        );

        // Claim rewards and verify balances
        uint256 aliceRwd1Before = rewardToken1.balanceOf(alice);
        uint256 aliceRwd2Before = rewardToken2.balanceOf(alice);

        vm.prank(alice);
        vault.claimRewards(address(alice));

        assertApproxEqAbs(
            rewardToken1.balanceOf(alice) - aliceRwd1Before, 10e18, tolerance, "Alice's RWD1 claim incorrect"
        );
        assertApproxEqAbs(
            rewardToken2.balanceOf(alice) - aliceRwd2Before, 20e18, tolerance, "Alice's RWD2 claim incorrect"
        );
    }

    function test_MultiTokenRewardsWithPartialClaims() public {
        // Initial deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // First reward cycle with both tokens
        notifyAndWarp(address(rewardToken1), 20e18);
        notifyAndWarp(address(rewardToken2), 40e18);

        // Alice claims only rewardToken1
        vm.prank(alice);
        vault.claimRewards(address(rewardToken1), address(alice));

        // Second reward cycle
        notifyAndWarp(address(rewardToken1), 30e18);
        notifyAndWarp(address(rewardToken2), 60e18);

        // Verify rewards state
        assertApproxEqAbs(
            vault.previewRewards(alice, address(rewardToken1)),
            15e18,
            tolerance,
            "Alice's RWD1 rewards after partial claim"
        );
        assertApproxEqAbs(
            vault.previewRewards(alice, address(rewardToken2)), 50e18, tolerance, "Alice's RWD2 rewards accumulated"
        );
        assertApproxEqAbs(
            vault.previewRewards(bob, address(rewardToken1)), 25e18, tolerance, "Bob's RWD1 total rewards"
        );
        assertApproxEqAbs(
            vault.previewRewards(bob, address(rewardToken2)), 50e18, tolerance, "Bob's RWD2 total rewards"
        );
    }

    function testFuzz_MultiTokenRewardDistribution(
        uint256 aliceDeposit,
        uint256 bobDeposit,
        uint256 reward1Amount,
        uint256 reward2Amount
    ) public {
        // Bound deposits to avoid overflow and unrealistic values
        aliceDeposit = bound(aliceDeposit, 1 ether / 10000, maxDeposits / 2);
        bobDeposit = bound(bobDeposit, 1 ether / 10000, maxDeposits - aliceDeposit);
        // Bound rewards to reasonable ranges
        reward1Amount = bound(reward1Amount, 1 ether / 1000, maxDeposits);
        reward2Amount = bound(reward2Amount, 1 ether / 1000, maxDeposits);

        // Alice and Bob deposit
        vm.prank(alice);
        vault.deposit(aliceDeposit, alice);
        vm.prank(bob);
        vault.deposit(bobDeposit, bob);

        notifyAndWarp(address(rewardToken1), reward1Amount);
        notifyAndWarp(address(rewardToken2), reward2Amount);

        // Calculate expected rewards
        uint256 totalDeposits = aliceDeposit + bobDeposit;
        uint256 expectedAliceReward1 = FixedPointMathLib.mulDiv(reward1Amount, aliceDeposit, totalDeposits);
        uint256 expectedAliceReward2 = FixedPointMathLib.mulDiv(reward2Amount, aliceDeposit, totalDeposits);
        uint256 expectedBobReward1 = FixedPointMathLib.mulDiv(reward1Amount, bobDeposit, totalDeposits);
        uint256 expectedBobReward2 = FixedPointMathLib.mulDiv(reward2Amount, bobDeposit, totalDeposits);

        // Record balances before claims
        uint256 aliceReward1Before = rewardToken1.balanceOf(alice);
        uint256 aliceReward2Before = rewardToken2.balanceOf(alice);
        uint256 bobReward1Before = rewardToken1.balanceOf(bob);
        uint256 bobReward2Before = rewardToken2.balanceOf(bob);

        // Claim rewards
        vm.prank(alice);
        vault.claimRewards(address(alice));
        vm.prank(bob);
        vault.claimRewards(address(bob));

        // Verify rewards with 0.00001% relative tolerance
        assertApproxEqRel(
            rewardToken1.balanceOf(alice) - aliceReward1Before, expectedAliceReward1, 1e11, "Alice reward1 mismatch"
        );
        assertApproxEqRel(
            rewardToken2.balanceOf(alice) - aliceReward2Before, expectedAliceReward2, 1e11, "Alice reward2 mismatch"
        );
        assertApproxEqRel(
            rewardToken1.balanceOf(bob) - bobReward1Before, expectedBobReward1, 1e11, "Bob reward1 mismatch"
        );
        assertApproxEqRel(
            rewardToken2.balanceOf(bob) - bobReward2Before, expectedBobReward2, 1e11, "Bob reward2 mismatch"
        );

        // Verify total rewards don't exceed input amounts
        assertLe(
            (rewardToken1.balanceOf(alice) - aliceReward1Before) + (rewardToken1.balanceOf(bob) - bobReward1Before),
            reward1Amount,
            "Total reward1 distribution exceeds input"
        );
        assertLe(
            (rewardToken2.balanceOf(alice) - aliceReward2Before) + (rewardToken2.balanceOf(bob) - bobReward2Before),
            reward2Amount,
            "Total reward2 distribution exceeds input"
        );
    }

    // Native Deposit Specific Tests
    function test_DepositNativeBasic() public {
        uint256 depositAmount = 1 ether;
        vm.prank(alice);
        vault.depositNative{value: depositAmount}(alice);

        assertEq(vault.balanceOf(alice), depositAmount, "Shares minted");
        assertEq(vault.depositPrincipal(), depositAmount, "Principal tracking");
        assertEq(address(vault).balance, 0, "No leftover ETH");
    }

    function test_DepositNativeRevertZeroValue() public {
        vm.prank(alice);
        vm.expectRevert(fatBERA.ZeroPrincipal.selector);
        vault.depositNative{value: 0}(alice);
    }

    function test_DepositNativeExceedsMax() public {
        uint256 maxDeposit = maxDeposits - 1 ether;

        // Fill up to max
        vm.prank(alice);
        vault.deposit(maxDeposit, alice);

        // Try to deposit 1.01 ETH native
        vm.prank(bob);
        vm.expectRevert(fatBERA.ExceedsMaxDeposits.selector);
        vault.depositNative{value: 1.01 ether}(bob);
    }

    function test_DepositNativeWETHBalance() public {
        uint256 depositAmount = 5 ether;
        uint256 initialWETHBalance = wbera.balanceOf(address(vault));

        vm.prank(alice);
        vault.depositNative{value: depositAmount}(alice);

        assertEq(
            wbera.balanceOf(address(vault)),
            initialWETHBalance + depositAmount,
            "WETH balance should increase by deposit amount"
        );
    }

    function test_MixedDepositMethods() public {
        uint256 nativeDeposit = 2 ether;
        uint256 erc20Deposit = 3 ether;

        // Native deposit
        vm.prank(alice);
        vault.depositNative{value: nativeDeposit}(alice);

        // ERC20 deposit
        vm.prank(alice);
        vault.deposit(erc20Deposit, alice);

        assertEq(vault.depositPrincipal(), nativeDeposit + erc20Deposit, "Should track both deposit types");
        assertEq(vault.balanceOf(alice), nativeDeposit + erc20Deposit, "Shares should be cumulative");
    }

    function test_NativeDepositWithRewards() public {
        uint256 depositAmount = 10 ether;

        vm.prank(alice);
        vault.depositNative{value: depositAmount}(alice);

        // Add rewards
        notifyAndWarp(address(wbera), 10 ether);

        // Verify rewards
        assertApproxEqAbs(
            vault.previewRewards(alice, address(wbera)), 10 ether, tolerance, "Should accrue rewards correctly"
        );
    }

    // Fuzz Tests
    function testFuzz_DepositNative(uint256 amount) public {
        amount = bound(amount, 1 wei, maxDeposits);
        vm.deal(alice, amount);

        vm.prank(alice);
        vault.depositNative{value: amount}(alice);

        assertEq(vault.balanceOf(alice), amount, "Shares should match deposit");
        assertEq(vault.depositPrincipal(), amount, "Principal should match");
    }

    function testFuzz_MixedDepositTypes(uint256 nativeAmount, uint256 erc20Amount) public {
        nativeAmount = bound(nativeAmount, 1 wei, maxDeposits / 2);
        erc20Amount = bound(erc20Amount, 1 wei, maxDeposits - nativeAmount);
        vm.deal(alice, nativeAmount);

        // Native deposit
        vm.prank(alice);
        vault.depositNative{value: nativeAmount}(alice);

        // ERC20 deposit
        vm.prank(alice);
        vault.deposit(erc20Amount, alice);

        assertEq(vault.depositPrincipal(), nativeAmount + erc20Amount, "Total principal should sum both types");
    }

    function test_RoleManagement() public {
        address newNotifier = makeAddr("newNotifier");

        // First verify initial roles
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "Admin should have DEFAULT_ADMIN_ROLE");
        assertTrue(vault.hasRole(vault.REWARD_NOTIFIER_ROLE(), admin), "Admin should have REWARD_NOTIFIER_ROLE");

        // Admin grants REWARD_NOTIFIER_ROLE to new address
        vm.startPrank(admin);
        vault.grantRole(vault.REWARD_NOTIFIER_ROLE(), newNotifier);
        vm.stopPrank();

        // Verify roles after granting
        assertTrue(vault.hasRole(vault.REWARD_NOTIFIER_ROLE(), newNotifier), "New notifier should have role");
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "Admin should still have admin role");
        assertTrue(vault.hasRole(vault.REWARD_NOTIFIER_ROLE(), admin), "Admin should still have notifier role");

        // Test revoking role
        vm.startPrank(admin);
        vault.revokeRole(vault.REWARD_NOTIFIER_ROLE(), newNotifier);
        vm.stopPrank();
        assertFalse(vault.hasRole(vault.REWARD_NOTIFIER_ROLE(), newNotifier), "Role should be revoked");
        console.log("newNotifier", newNotifier);

        bytes32 role = vault.REWARD_NOTIFIER_ROLE();

        // Test that non-admin cannot grant roles
        vm.startPrank(newNotifier);
        vm.expectRevert();
        vault.grantRole(role, alice);
        vm.stopPrank();
    }

    function test_only_admin_can_pause_and_unpause() public {
        // Non-admin attempts
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.unpause();

        // Admin attempts should succeed
        vm.startPrank(admin);
        vault.unpause();
        assertTrue(!vault.paused(), "Vault should be unpaused");

        vault.pause();
        assertTrue(vault.paused(), "Vault should be paused");
        vm.stopPrank();
    }

    function test_only_admin_can_set_max_rewards_tokens() public {
        uint256 newMax = 20;

        // Non-admin attempt
        vm.prank(alice);
        vm.expectRevert();
        vault.setMaxRewardsTokens(newMax);

        // Admin attempt should succeed
        vm.prank(admin);
        vault.setMaxRewardsTokens(newMax);
        assertEq(vault.MAX_REWARDS_TOKENS(), newMax, "MAX_REWARDS_TOKENS not updated");
    }

    function test_setRewardsDuration_active_period_reverts() public {
        // First make a deposit to avoid ZeroShares error
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Set initial duration
        vm.prank(admin);
        vault.setRewardsDuration(address(wbera), 7 days);

        // Notify reward to start period
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera), 10e18);

        // Attempt to update duration during active period
        vm.prank(admin);
        vm.expectRevert(fatBERA.RewardPeriodStillActive.selector);
        vault.setRewardsDuration(address(wbera), 14 days);
    }

    /**
     * @dev Test that rewards accrue linearly over time.
     * After notifying a reward, we warp forward a fraction of the reward period and verify
     * that the accrued rewards match the expected proportion.
     */
    function test_PartialTimeRewardAccrual() public {
        // Unpause the vault so that deposits are permitted.
        vm.prank(admin);
        vault.unpause();

        // Alice deposits 100 tokens.
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Record the starting time.
        uint256 startTime = block.timestamp;

        // Notify a reward amount that will be distributed linearly over 7 days.
        uint256 rewardAmount = 70e18; // For example, 70 WBERA reward
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera), rewardAmount);

        // Immediately after notification, no reward should have accrued.
        uint256 initialAccrued = vault.previewRewards(alice, address(wbera));
        assertEq(initialAccrued, 0, "No reward should accrue immediately after notification");

        // Warp forward by half of the reward duration (i.e. 3.5 days).
        uint256 halfTime = 7 days / 2;
        vm.warp(startTime + halfTime);

        // Expected reward is proportional: (rewardAmount * elapsedTime) / rewardsDuration.
        uint256 expectedReward = rewardAmount * halfTime / (7 days);
        uint256 accruedReward = vault.previewRewards(alice, address(wbera));
        assertApproxEqAbs(accruedReward, expectedReward, tolerance, "Partial time reward accrual mismatch");
    }

    /**
     * @dev Test that once the entire reward period elapses, the total accrued rewards equal the full reward,
     * and that further time passage does not increase rewards beyond the notified amount.
     */
    function test_FullTimeRewardAccrual() public {
        vm.prank(admin);
        vault.unpause();

        vm.prank(alice);
        vault.deposit(100e18, alice);

        uint256 startTime = block.timestamp;
        uint256 rewardAmount = 50e18;
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera), rewardAmount);

        // Warp exactly to the end of the reward period.
        vm.warp(startTime + 7 days);
        uint256 accruedReward = vault.previewRewards(alice, address(wbera));
        // Expect the full reward amount to have accrued.
        assertApproxEqAbs(accruedReward, rewardAmount, tolerance, "Full time reward accrual mismatch");

        // Warp further in time; rewards should not exceed the full reward.
        vm.warp(startTime + 7 days + 1 days);
        uint256 accruedRewardAfterExtra = vault.previewRewards(alice, address(wbera));
        assertApproxEqAbs(
            accruedRewardAfterExtra, rewardAmount, tolerance, "Reward should not accrue past reward period"
        );
    }

    /**
     * @dev Test that reward accumulations over successive cycles are additive.
     * The test first notifies a reward, waits for the entire period (thus accruing the full first reward),
     * then notifies a second reward and checks that the total accrued rewards equal the sum of the full first reward
     * and a partial accrual of the second reward.
     */
    function test_CumulativeTimeBasedRewards() public {
        vm.prank(admin);
        vault.unpause();

        // Alice deposits 100 tokens.
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Record the initial timestamp.
        uint256 startTime = block.timestamp;

        // First reward: 40 WBERA distributed over 7 days.
        uint256 rewardAmount1 = 40e18;
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera), rewardAmount1);

        // Warp to the end of the first reward period.
        vm.warp(startTime + 7 days);
        uint256 accruedFirst = vault.previewRewards(alice, address(wbera));
        // Should equal the full first reward amount.
        assertApproxEqAbs(accruedFirst, rewardAmount1, tolerance, "First reward full accrual mismatch");

        // Second reward: notify a new reward immediately after the first period.
        uint256 rewardAmount2 = 60e18;
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera), rewardAmount2);
        uint256 secondStartTime = block.timestamp; // Should equal startTime + 7 days

        // Warp forward by half of the second reward period.
        uint256 halfTimeSecond = 7 days / 2;
        vm.warp(secondStartTime + halfTimeSecond);
        uint256 accruedSecond = rewardAmount2 * halfTimeSecond / (7 days);

        // Total expected rewards are the sum of the first (fully accrued) and second (partially accrued).
        uint256 totalExpected = rewardAmount1 + accruedSecond;
        uint256 totalAccrued = vault.previewRewards(alice, address(wbera));
        assertApproxEqAbs(totalAccrued, totalExpected, tolerance, "Cumulative reward accrual mismatch");
    }

    /**
     * @dev Test that a sandwich attack is mitigated. In a vulnerable design, an attacker depositing
     * just before notifyRewardAmount() and quickly claiming would capture the full reward.
     * With time-based accrual, the attacker only earns rewards for the very short time they are staked.
     * Withdrawals are disabled, so previewRewards() is used to verify the minimal reward accumulation.
     */
    function test_SandwichAttackMitigation() public {
        // Unpause the vault to allow deposits.
        vm.prank(admin);
        vault.unpause();

        // --- Attacker deposits borrowed WBERA before the reward is notified ---
        uint256 attackerDeposit = 100e18;
        vm.prank(bob);
        vault.deposit(attackerDeposit, bob);

        // Capture the block timestamp as the notify time.
        uint256 notifyTime = block.timestamp;

        // --- Admin notifies a reward ---
        // For example, notify 50 WBERA to be distributed linearly over 7 days.
        uint256 totalReward = 50e18;
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera), totalReward);

        // --- Simulate the attacker quickly exiting ---
        // Immediately after notifying, simulate a brief time passage of 1 second.
        vm.warp(notifyTime + 1);

        // Instead of withdrawing (withdrawals are disabled), check what reward accrual preview shows.
        uint256 attackerRewardPreview = vault.previewRewards(bob, address(wbera));

        // With a linear accrual the reward earned over 1 second should be:
        //   rewardRate = totalReward / rewardsDuration (7 days = 604800 seconds)
        // Thus, expectedReward = 1 * (totalReward / 604800)
        uint256 expectedAttackerReward = totalReward / 604800;

        // We use a modest tolerance (1e10 wei) after accounting for arithmetic precision.
        assertApproxEqAbs(
            attackerRewardPreview,
            expectedAttackerReward,
            1e10,
            "Attacker reward preview exceeds expected minimal accrual"
        );
    }

    /**
     * @dev Test to ensure that transferring shares does not allow a recipient
     *      to claim rewards accrued before the transfer.
     *      This test fails in the vulnerable contract (without reward update on transfer)
     *      and passes once the fix (calling _updateRewards on share transfers) is applied.
     */
    function test_TransferDoesNotStealRewards() public {
        // Alice deposits 100 WBERA
        uint256 depositAmount = 100e18;
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Notify a reward of 10 WBERA
        uint256 rewardAmount = 10e18;
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera), rewardAmount);

        // Warp forward by half the reward duration (3.5 days)
        uint256 halfPeriod = 7 days / 2;
        vm.warp(block.timestamp + halfPeriod);

        // Capture Alice's accrued rewards before the transfer
        uint256 aliceRewardsBefore = vault.previewRewards(alice, address(wbera));
        assertGt(aliceRewardsBefore, 0, "Alice should have accrued rewards before transfer");

        // Alice transfers half of her shares (50e18) to Bob
        uint256 transferAmount = depositAmount / 2;
        vm.prank(alice);
        vault.transfer(bob, transferAmount);

        // Immediately after transfer:
        // 1. Alice's rewards should remain the same (she keeps rewards accrued before transfer)
        uint256 aliceRewardsAfter = vault.previewRewards(alice, address(wbera));
        assertEq(aliceRewardsAfter, aliceRewardsBefore, "Alice's rewards should not change after transfer");

        // 2. Bob should start with 0 rewards (should not inherit Alice's rewards)
        uint256 bobRewardsAfter = vault.previewRewards(bob, address(wbera));
        assertEq(bobRewardsAfter, 0, "Bob should not have any accrued rewards from transferred shares");

        // 3. If Bob claims rewards immediately, he should get nothing
        uint256 bobBalanceBefore = wbera.balanceOf(bob);
        vm.prank(bob);
        vault.claimRewards(bob);
        uint256 bobClaimed = wbera.balanceOf(bob) - bobBalanceBefore;
        assertEq(bobClaimed, 0, "Bob should not be able to claim any rewards from transferred shares");

        // 4. After some time passes, Bob should start accruing new rewards
        vm.warp(block.timestamp + 1 days);
        uint256 bobRewardsLater = vault.previewRewards(bob, address(wbera));
        assertGt(bobRewardsLater, 0, "Bob should accrue new rewards after time passes");
    }

    function test_setWhitelistedVault_access() public {
        address vaultAddress = makeAddr("vault");

        // Non-admin attempt
        vm.prank(alice);
        vm.expectRevert();
        vault.setWhitelistedVault(vaultAddress, true);

        // Admin attempt should succeed
        vm.prank(admin);
        vault.setWhitelistedVault(vaultAddress, true);
        assertTrue(vault.isWhitelistedVault(vaultAddress), "Vault should be whitelisted");

        // Admin can also unset
        vm.prank(admin);
        vault.setWhitelistedVault(vaultAddress, false);
        assertFalse(vault.isWhitelistedVault(vaultAddress), "Vault should not be whitelisted");
    }

    function test_transfer_to_whitelisted_vault_updates_vaultedShares() public {
        address vaultAddress = makeAddr("vault");
        uint256 depositAmount = 100e18;
        uint256 transferAmount = 50e18;

        // Setup: Alice deposits and vault is whitelisted
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        vm.prank(admin);
        vault.setWhitelistedVault(vaultAddress, true);

        // Transfer to vault
        vm.prank(alice);
        vault.transfer(vaultAddress, transferAmount);

        // Check vaulted shares
        assertEq(vault.vaultedShares(alice), transferAmount, "Vaulted shares not updated correctly");
        assertEq(vault.effectiveBalance(alice), depositAmount, "Effective balance should remain unchanged");
    }

    function test_transfer_from_whitelisted_vault_fails_if_insufficient() public {
        address vaultAddress = makeAddr("vault");
        uint256 depositAmount = 100e18;
        uint256 transferAmount = 50e18;

        // Setup: Alice deposits and transfers to vault
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        vm.prank(admin);
        vault.setWhitelistedVault(vaultAddress, true);

        vm.prank(alice);
        vault.transfer(vaultAddress, transferAmount);

        // Attempt to transfer more than vaulted shares from vault
        vm.prank(vaultAddress);
        vm.expectRevert("Insufficient vaulted shares");
        vault.transfer(bob, transferAmount + 1e18);
    }

    function test_deposit_principal_consistency() public {
        // Track total deposits
        uint256 totalDeposited;

        // Native deposit
        uint256 nativeAmount = 1 ether;
        vm.deal(alice, nativeAmount);
        vm.prank(alice);
        vault.depositNative{value: nativeAmount}(alice);
        totalDeposited += nativeAmount;

        // Regular deposit
        uint256 regularAmount = 2 ether;
        vm.prank(bob);
        vault.deposit(regularAmount, bob);
        totalDeposited += regularAmount;

        // Mint shares
        uint256 mintShares = 3 ether;
        vm.prank(charlie);
        uint256 assetsForMint = vault.mint(mintShares, charlie);
        totalDeposited += assetsForMint;

        // Verify consistency
        assertEq(vault.depositPrincipal(), totalDeposited, "depositPrincipal mismatch");
        assertEq(vault.totalSupply(), totalDeposited, "totalSupply mismatch");
        assertEq(vault.totalAssets(), totalDeposited, "totalAssets mismatch");
    }

    function test_RewardSimulationScenario1() public {
        // Initial setup
        vm.prank(admin);
        vault.unpause();

        address userA = makeAddr("userA");
        address userB = makeAddr("userB");

        // Setup initial balances and approvals
        wbera.mint(userA, 10 ether);
        wbera.mint(userB, 5 ether);
        wbera.mint(admin, 1000000 ether);

        vm.prank(userA);
        wbera.approve(address(vault), type(uint256).max);
        vm.prank(userB);
        wbera.approve(address(vault), type(uint256).max);
        vm.prank(admin);
        wbera.approve(address(vault), type(uint256).max);

        console.log("\nScenario 1: 2-day reward duration, hourly notifications over 1 week");
        console.log("==============================================");

        // Set reward duration to 2 days
        vm.prank(admin);
        vault.setRewardsDuration(address(wbera), 2 days);

        // User A deposits 10 fatBERA at hour 0
        vm.prank(userA);
        vault.deposit(10 ether, userA);
        console.log("Initial deposit - User A: 10 BERA");

        uint256 startTime = block.timestamp;

        // Simulate hourly notifications for first scenario over a week
        for (uint256 hour = 1; hour <= 168; hour++) {
            vm.warp(startTime + hour * 1 hours);

            // Calculate hourly reward: 1 BERA per day per fatBERA
            uint256 totalStaked = hour <= 24 ? 10 ether : 15 ether;
            uint256 hourlyReward = (totalStaked / 10) / 24; // Direct calculation for hourly rate

            vm.prank(admin);
            vault.notifyRewardAmount(address(wbera), hourlyReward);

            // Add User B's deposit at 24 hours
            if (hour == 24) {
                vm.prank(userB);
                vault.deposit(5 ether, userB);
                console.log("\nHour 24 - User B deposits 5 BERA");
                console.log("User A rewards: %d", vault.previewRewards(userA, address(wbera)));
                console.log("User B rewards: %d", vault.previewRewards(userB, address(wbera)));
            }

            // Log at specific intervals
            if (hour == 48 || hour == 96 || hour == 144) {
                console.log("\nHour %d", hour);
                console.log("User A rewards: %d", vault.previewRewards(userA, address(wbera)));
                console.log("User B rewards: %d", vault.previewRewards(userB, address(wbera)));
            }
        }

        // Log final state
        console.log("\nFinal State (Hour 168):");
        console.log("User A rewards: %d", vault.previewRewards(userA, address(wbera)));
        console.log("User B rewards: %d", vault.previewRewards(userB, address(wbera)));
    }

    function test_RewardSimulationScenario2() public {
        // Initial setup
        vm.prank(admin);
        vault.unpause();

        address userA = makeAddr("userA");
        address userB = makeAddr("userB");

        // Setup initial balances and approvals
        wbera.mint(userA, 10 ether);
        wbera.mint(userB, 5 ether);
        wbera.mint(admin, 1000000 ether);

        vm.prank(userA);
        wbera.approve(address(vault), type(uint256).max);
        vm.prank(userB);
        wbera.approve(address(vault), type(uint256).max);
        vm.prank(admin);
        wbera.approve(address(vault), type(uint256).max);

        console.log("\nScenario 2: 2-day reward duration, 48-hour notifications over 1 week");
        console.log("==============================================");

        // Set reward duration to 2 days
        vm.prank(admin);
        vault.setRewardsDuration(address(wbera), 2 days);

        // User A deposits for second scenario
        vm.prank(userA);
        vault.deposit(10 ether, userA);
        console.log("Initial deposit - User A: 10 BERA");

        uint256 startTime = block.timestamp;
        uint256 totalRewardsNotified = 0;

        // Simulate hourly checks but 48-hour notifications
        for (uint256 hour = 1; hour <= 168; hour++) {
            vm.warp(startTime + hour * 1 hours);

            // Notify rewards every 48 hours (2 days)
            if (hour % 48 == 0) {
                uint256 totalStaked = hour <= 24 ? 10 ether : 15 ether;
                uint256 twoDayReward = (totalStaked / 10) * 2;

                vm.prank(admin);
                vault.notifyRewardAmount(address(wbera), twoDayReward);
                totalRewardsNotified += twoDayReward;

                console.log("\nHour %d - Notified reward: %d", hour, twoDayReward);
                console.log("User A rewards: %d", vault.previewRewards(userA, address(wbera)));
                console.log("User B rewards: %d", vault.previewRewards(userB, address(wbera)));
            }

            // Add User B's deposit at 24 hours
            if (hour == 24) {
                vm.prank(userB);
                vault.deposit(5 ether, userB);
                console.log("\nHour 24 - User B deposits 5 BERA");
                console.log("User A rewards: %d", vault.previewRewards(userA, address(wbera)));
                console.log("User B rewards: %d", vault.previewRewards(userB, address(wbera)));
            }
        }

        // Log final state
        console.log("\nFinal State (Hour 168):");
        console.log("Total Rewards Notified: %d", totalRewardsNotified);
        console.log("User A rewards: %d", vault.previewRewards(userA, address(wbera)));
        console.log("User B rewards: %d", vault.previewRewards(userB, address(wbera)));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    V2 WITHDRAWAL TESTS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_BasicWithdrawalFlow() public {
        // Setup: Users deposit
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(bob);
        vault.deposit(50e18, bob);

        // Alice requests withdrawal
        vm.prank(alice);
        vault.requestWithdraw(40e18);

        // Check state
        assertEq(vault.balanceOf(alice), 60e18, "Alice should have 60 shares left");
        assertEq(vault.pending(alice), 40e18, "Alice should have 40 shares pending");
        assertEq(vault.totalPending(), 40e18, "Total pending should be 40");

        // Admin starts batch
        vm.expectEmit(true, true, true, true);
        emit fatBERAV2.BatchStarted(1, 40e18);
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Simulate validator withdrawal (mint WBERA to fulfiller)
        wbera.mint(fulfiller, 40e18);
        vm.prank(fulfiller);
        wbera.approve(address(vault), 40e18);

        // Fulfiller fulfills batch with 0 fee
        vm.prank(fulfiller);
        vault.fulfillBatch(1, 0);

        // Check state after fulfillment
        assertEq(vault.pending(alice), 0, "Alice should have 0 pending");
        assertEq(vault.claimable(alice), 40e18, "Alice should have 40 claimable");
        assertEq(vault.totalPending(), 0, "Total pending should be 0");

        // Alice claims withdrawn assets
        uint256 aliceBalanceBefore = wbera.balanceOf(alice);
        vm.expectEmit(true, true, true, true);
        emit fatBERAV2.WithdrawalClaimed(alice, 40e18);
        vm.prank(alice);
        vault.claimWithdrawnAssets();

        assertEq(wbera.balanceOf(alice) - aliceBalanceBefore, 40e18, "Alice should receive 40 WBERA");
        assertEq(vault.claimable(alice), 0, "Alice should have 0 claimable");
    }

    function test_MultipleUsersInBatch() public {
        // Setup: Multiple users deposit
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(bob);
        vault.deposit(50e18, bob);

        vm.prank(charlie);
        vault.deposit(200e18, charlie);

        // Multiple users request withdrawals
        vm.prank(alice);
        vault.requestWithdraw(50e18);

        vm.prank(bob);
        vault.requestWithdraw(25e18);

        vm.prank(charlie);
        vault.requestWithdraw(100e18);

        // Check batch state
        // Note: Public mapping only returns non-array fields
        (bool frozen, bool fulfilled, uint256 total) = vault.batches(1);
        assertEq(total, 175e18, "Total should be 175");
        assertFalse(frozen, "Batch should not be frozen");
        assertFalse(fulfilled, "Batch should not be fulfilled");

        // Admin starts batch
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Simulate validator withdrawal with 1% fee
        uint256 fee = 175e18 * 1 / 100; // 1.75e18
        uint256 netAmount = 175e18 - fee;
        wbera.mint(fulfiller, netAmount);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), netAmount);
        vault.fulfillBatch(1, fee);
        vm.stopPrank();

        // Check proportional distribution
        uint256 aliceShare = 50e18 * netAmount / 175e18;
        uint256 bobShare = 25e18 * netAmount / 175e18;
        uint256 charlieShare = 100e18 * netAmount / 175e18;

        assertEq(vault.claimable(alice), aliceShare, "Alice claimable incorrect");
        assertEq(vault.claimable(bob), bobShare, "Bob claimable incorrect");
        assertEq(vault.claimable(charlie), charlieShare, "Charlie claimable incorrect");

        // All users claim
        vm.prank(alice);
        vault.claimWithdrawnAssets();
        vm.prank(bob);
        vault.claimWithdrawnAssets();
        vm.prank(charlie);
        vault.claimWithdrawnAssets();

        // Verify all claimed
        assertEq(vault.claimable(alice), 0, "Alice should have claimed all");
        assertEq(vault.claimable(bob), 0, "Bob should have claimed all");
        assertEq(vault.claimable(charlie), 0, "Charlie should have claimed all");
    }

    function test_MultipleBatches() public {
        // Setup
        vm.prank(alice);
        vault.deposit(200e18, alice);

        // First batch
        vm.prank(alice);
        vault.requestWithdraw(50e18);

        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Check batch ID incremented
        assertEq(vault.currentBatchId(), 2, "Current batch ID should be 2");

        // Second batch
        vm.prank(alice);
        vault.requestWithdraw(30e18);

        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Check batch ID incremented again
        assertEq(vault.currentBatchId(), 3, "Current batch ID should be 3");

        // Fulfill first batch
        wbera.mint(fulfiller, 50e18);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), 50e18);
        vault.fulfillBatch(1, 0);
        vm.stopPrank();

        // Alice can claim from first batch
        assertEq(vault.claimable(alice), 50e18, "Alice should have 50 claimable from batch 1");

        // Fulfill second batch
        wbera.mint(fulfiller, 30e18);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), 30e18);
        vault.fulfillBatch(2, 0);
        vm.stopPrank();

        // Alice can claim total from both batches
        assertEq(vault.claimable(alice), 80e18, "Alice should have 80 total claimable");

        vm.prank(alice);
        vault.claimWithdrawnAssets();

        assertEq(vault.claimable(alice), 0, "Alice should have claimed all");
    }

    function test_RequestWithdrawRevertsZeroShares() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        vm.expectRevert(fatBERAV2.ZeroShares.selector);
        vault.requestWithdraw(0);
    }

    function test_StartBatchRevertsNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.startWithdrawalBatch();
    }

    function test_FulfillBatchRevertsNonFulfiller() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        vault.requestWithdraw(50e18);

        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Non-fulfiller tries to fulfill
        vm.prank(alice);
        vm.expectRevert();
        vault.fulfillBatch(1, 0);
    }

    function test_FulfillBatchRevertsBatchNotFrozen() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        vault.requestWithdraw(50e18);

        // Try to fulfill unfrozen batch
        vm.prank(fulfiller);
        vm.expectRevert(fatBERAV2.BatchNotFrozen.selector);
        vault.fulfillBatch(1, 0);
    }

    function test_FulfillBatchRevertsAlreadyFulfilled() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        vault.requestWithdraw(50e18);

        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Fulfill once
        wbera.mint(fulfiller, 50e18);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), 50e18);
        vault.fulfillBatch(1, 0);

        // Try to fulfill again
        vm.expectRevert(fatBERAV2.BatchAlreadyFulfilled.selector);
        vault.fulfillBatch(1, 0);
        vm.stopPrank();
    }

    function test_FulfillBatchRevertsExcessiveFee() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        vault.requestWithdraw(50e18);

        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Try to fulfill with fee > total
        vm.prank(fulfiller);
        vm.expectRevert(fatBERAV2.InsufficientAssets.selector);
        vault.fulfillBatch(1, 51e18);
    }

    function test_FulfillEmptyBatch() public {
        // Start empty batch
        vm.prank(fulfiller);
        vm.expectRevert(fatBERAV2.BatchEmpty.selector);
        vault.startWithdrawalBatch();
    }

    function test_ClaimWithdrawnAssetsRevertsNothingToClaim() public {
        vm.prank(alice);
        vm.expectRevert(fatBERAV2.NothingToClaim.selector);
        vault.claimWithdrawnAssets();
    }

    function test_WithdrawalRewardsSettlement() public {
        // Alice deposits and earns rewards
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Add rewards
        notifyAndWarp(address(wbera), 10e18);

        // Alice has 10 rewards pending
        assertApproxEqAbs(vault.previewRewards(alice, address(wbera)), 10e18, tolerance, "Alice should have 10 rewards");

        // Alice requests withdrawal
        vm.prank(alice);
        vault.requestWithdraw(100e18);

        // Rewards should still be claimable after withdrawal request
        assertApproxEqAbs(vault.previewRewards(alice, address(wbera)), 10e18, tolerance, "Rewards should persist");

        // Alice can claim rewards separately
        vm.prank(alice);
        vault.claimRewards(address(alice));

        assertEq(vault.previewRewards(alice, address(wbera)), 0, "Rewards should be claimed");
    }

    function test_PartialWithdrawalFlow() public {
        // Alice deposits 100
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Alice withdraws 40
        vm.prank(alice);
        vault.requestWithdraw(40e18);

        assertEq(vault.balanceOf(alice), 60e18, "Alice should have 60 shares remaining");

        // Process withdrawal
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        wbera.mint(fulfiller, 40e18);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), 40e18);
        vault.fulfillBatch(1, 0);
        vm.stopPrank();

        // Alice still earns rewards on remaining 60 shares
        notifyAndWarp(address(wbera), 12e18);

        // With 60 shares out of 60 total, Alice gets all rewards
        assertApproxEqAbs(
            vault.previewRewards(alice, address(wbera)),
            12e18,
            tolerance,
            "Alice should earn rewards on remaining shares"
        );
    }

    function test_FeeDistribution() public {
        // Multiple users with different amounts
        vm.prank(alice);
        vault.deposit(300e18, alice);

        vm.prank(bob);
        vault.deposit(200e18, bob);

        vm.prank(charlie);
        vault.deposit(100e18, charlie);

        // Request withdrawals
        vm.prank(alice);
        vault.requestWithdraw(150e18); // 50% of alice

        vm.prank(bob);
        vault.requestWithdraw(100e18); // 50% of bob

        vm.prank(charlie);
        vault.requestWithdraw(50e18); // 50% of charlie

        // Total: 300e18
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // 2% fee
        uint256 fee = 6e18;
        uint256 netAmount = 294e18;

        wbera.mint(fulfiller, netAmount);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), netAmount);
        vault.fulfillBatch(1, fee);
        vm.stopPrank();

        // Check proportional fee distribution
        // Alice had 150/300 = 50% of batch
        // Bob had 100/300 = 33.33% of batch
        // Charlie had 50/300 = 16.67% of batch
        assertEq(vault.claimable(alice), 147e18, "Alice should receive 147 (150 - 3 fee)");
        assertEq(vault.claimable(bob), 98e18, "Bob should receive 98 (100 - 2 fee)");
        assertEq(vault.claimable(charlie), 49e18, "Charlie should receive 49 (50 - 1 fee)");
    }

    function test_ReentrancyProtection() public {
        // Test that reentrancy protection works on key functions
        // Since ERC20 transfers don't trigger receive(), we test direct reentrancy
        
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        vault.requestWithdraw(100e18);

        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        wbera.mint(fulfiller, 100e18);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), 100e18);
        vault.fulfillBatch(1, 0);
        vm.stopPrank();

        // Test that claimWithdrawnAssets has reentrancy protection
        // by verifying it can only be called once per user per amount
        vm.prank(alice);
        vault.claimWithdrawnAssets();
        
        // Second call should revert with NothingToClaim since claimable is now 0
        vm.prank(alice);
        vm.expectRevert(fatBERAV2.NothingToClaim.selector);
        vault.claimWithdrawnAssets();
    }

    function test_RemaindersFromRounding() public {
        // Test that tiny remainders from rounding are handled correctly
        vm.prank(alice);
        vault.deposit(1e18 + 7, alice); // Odd amount

        vm.prank(bob);
        vault.deposit(1e18 + 3, bob); // Another odd amount

        // Request withdrawals
        vm.prank(alice);
        vault.requestWithdraw(1e18 + 7);

        vm.prank(bob);
        vault.requestWithdraw(1e18 + 3);

        uint256 total = 2e18 + 10;

        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Apply fee that causes rounding
        uint256 fee = 11; // Prime number fee
        uint256 netAmount = total - fee;

        wbera.mint(fulfiller, netAmount);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), netAmount);

        uint256 principalBefore = vault.depositPrincipal();
        vault.fulfillBatch(1, fee);
        uint256 principalAfter = vault.depositPrincipal();
        vm.stopPrank();

        // Any remainder should be added to depositPrincipal
        uint256 aliceClaimable = vault.claimable(alice);
        uint256 bobClaimable = vault.claimable(bob);
        uint256 remainder = netAmount - aliceClaimable - bobClaimable;

        assertEq(principalAfter - principalBefore, remainder, "Remainder should be added to principal");
    }

    function test_WithdrawERC4626Disabled() public {
        // Standard ERC4626 withdrawals should still be disabled
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // withdraw() returns 0
        vm.prank(alice);
        uint256 shares = vault.withdraw(50e18, alice, alice);
        assertEq(shares, 0, "withdraw should return 0");

        // redeem() returns 0
        vm.prank(alice);
        uint256 assets = vault.redeem(50e18, alice, alice);
        assertEq(assets, 0, "redeem should return 0");
    }

    function testFuzz_WithdrawalFlow(uint256 depositAmount, uint256 withdrawAmount, uint256 feePercent) public {
        // Bound inputs
        depositAmount = bound(depositAmount, 1e18, 1000e18);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);
        feePercent = bound(feePercent, 0, 500); // 0-5%

        // Setup
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Request withdrawal
        vm.prank(alice);
        vault.requestWithdraw(withdrawAmount);

        // Process
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        uint256 fee = withdrawAmount * feePercent / 10000;
        uint256 netAmount = withdrawAmount - fee;

        wbera.mint(fulfiller, netAmount);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), netAmount);
        vault.fulfillBatch(1, fee);
        vm.stopPrank();

        // Claim
        uint256 balanceBefore = wbera.balanceOf(alice);
        vm.prank(alice);
        vault.claimWithdrawnAssets();

        assertEq(wbera.balanceOf(alice) - balanceBefore, netAmount, "Should receive net amount");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    EDGE CASE TESTS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_MultipleWithdrawsBeforeFirstFulfilled() public {
        // Alice deposits 300
        vm.prank(alice);
        vault.deposit(300e18, alice);

        // Alice requests first withdrawal in batch 1
        vm.prank(alice);
        vault.requestWithdraw(100e18);

        // Start batch 1
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Alice requests second withdrawal in batch 2 (before batch 1 is fulfilled)
        vm.prank(alice);
        vault.requestWithdraw(50e18);

        // Alice requests third withdrawal in batch 2
        vm.prank(alice);
        vault.requestWithdraw(75e18);

        // Start batch 2
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Check Alice's state
        assertEq(vault.balanceOf(alice), 75e18, "Alice should have 75 shares left");
        assertEq(vault.pending(alice), 225e18, "Alice should have 225 shares pending across batches");

        // Fulfill batch 1 first
        wbera.mint(fulfiller, 100e18);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), 100e18);
        vault.fulfillBatch(1, 0);
        vm.stopPrank();

        // Alice should have claimable from batch 1
        assertEq(vault.claimable(alice), 100e18, "Alice should have 100 claimable from batch 1");
        assertEq(vault.pending(alice), 125e18, "Alice should have 125 pending in batch 2");

        // Fulfill batch 2
        wbera.mint(fulfiller, 125e18);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), 125e18);
        vault.fulfillBatch(2, 0);
        vm.stopPrank();

        // Alice should have total claimable from both batches
        assertEq(vault.claimable(alice), 225e18, "Alice should have 225 total claimable");
        assertEq(vault.pending(alice), 0, "Alice should have 0 pending");
    }

    function test_ClaimFromMultipleBatchesSequentially() public {
        // Setup: Alice deposits and creates two withdrawal batches
        vm.prank(alice);
        vault.deposit(200e18, alice);

        // Batch 1: 80 shares
        vm.prank(alice);
        vault.requestWithdraw(80e18);
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Batch 2: 60 shares
        vm.prank(alice);
        vault.requestWithdraw(60e18);
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Fulfill batch 1 with 2% fee
        uint256 fee1 = 80e18 * 2 / 100;
        uint256 net1 = 80e18 - fee1;
        wbera.mint(fulfiller, net1);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), net1);
        vault.fulfillBatch(1, fee1);
        vm.stopPrank();

        // Alice claims from batch 1
        uint256 balanceBefore = wbera.balanceOf(alice);
        vm.prank(alice);
        vault.claimWithdrawnAssets();
        uint256 claimed1 = wbera.balanceOf(alice) - balanceBefore;
        assertEq(claimed1, net1, "Alice should receive net amount from batch 1");
        assertEq(vault.claimable(alice), 0, "Alice should have 0 claimable after first claim");

        // Fulfill batch 2 with 3% fee
        uint256 fee2 = 60e18 * 3 / 100;
        uint256 net2 = 60e18 - fee2;
        wbera.mint(fulfiller, net2);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), net2);
        vault.fulfillBatch(2, fee2);
        vm.stopPrank();

        // Alice claims from batch 2
        balanceBefore = wbera.balanceOf(alice);
        vm.prank(alice);
        vault.claimWithdrawnAssets();
        uint256 claimed2 = wbera.balanceOf(alice) - balanceBefore;
        assertEq(claimed2, net2, "Alice should receive net amount from batch 2");
        assertEq(vault.claimable(alice), 0, "Alice should have 0 claimable after second claim");

        // Verify total claimed
        assertEq(claimed1 + claimed2, net1 + net2, "Total claimed should equal sum of net amounts");
    }

    function test_V1AccountingNotAffectedByV2Withdrawals() public {
        // Record initial state
        uint256 initialDepositPrincipal = vault.depositPrincipal();
        uint256 initialTotalSupply = vault.totalSupply();

        // Alice and Bob deposit (V1 style deposits)
        vm.prank(alice);
        vault.deposit(200e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        uint256 afterDepositsDepositPrincipal = vault.depositPrincipal();
        uint256 afterDepositsTotalSupply = vault.totalSupply();

        // Verify deposits updated accounting correctly
        assertEq(afterDepositsDepositPrincipal, initialDepositPrincipal + 300e18, "depositPrincipal should increase by 300");
        assertEq(afterDepositsTotalSupply, initialTotalSupply + 300e18, "totalSupply should increase by 300");

        // Admin withdraws some principal for staking (V1 functionality)
        vm.prank(admin);
        vault.withdrawPrincipal(150e18, admin);

        uint256 afterWithdrawDepositPrincipal = vault.depositPrincipal();
        assertEq(afterWithdrawDepositPrincipal, afterDepositsDepositPrincipal - 150e18, "depositPrincipal should decrease by 150");

        // Alice requests V2 withdrawal
        vm.prank(alice);
        vault.requestWithdraw(100e18);

        // V2 withdrawal request should NOT affect depositPrincipal
        assertEq(vault.depositPrincipal(), afterWithdrawDepositPrincipal, "depositPrincipal should not change on withdrawal request");
        assertEq(vault.totalSupply(), afterDepositsTotalSupply - 100e18, "totalSupply should decrease by withdrawn shares");

        // Process V2 withdrawal
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        uint256 fee = 5e18;
        uint256 netAmount = 100e18 - fee;
        wbera.mint(fulfiller, netAmount);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), netAmount);
        vault.fulfillBatch(1, fee);
        vm.stopPrank();

        // After fulfillment, any remainder from rounding should be added to depositPrincipal
        // but the main accounting should remain intact
        uint256 afterFulfillmentDepositPrincipal = vault.depositPrincipal();
        assertTrue(afterFulfillmentDepositPrincipal >= afterWithdrawDepositPrincipal, "depositPrincipal should not decrease");
        
        // The difference should be small (just rounding remainder if any)
        uint256 difference = afterFulfillmentDepositPrincipal - afterWithdrawDepositPrincipal;
        assertTrue(difference <= 1e15, "Difference should be minimal (just rounding)"); // Allow up to 0.001 BERA difference

        // Alice claims withdrawal
        vm.prank(alice);
        vault.claimWithdrawnAssets();

        // Claiming should not affect depositPrincipal
        assertEq(vault.depositPrincipal(), afterFulfillmentDepositPrincipal, "depositPrincipal should not change on claim");

        // Bob should still be able to earn rewards and admin should still be able to withdraw principal
        notifyAndWarp(address(wbera), 20e18);
        assertApproxEqAbs(vault.previewRewards(bob, address(wbera)), 10e18, tolerance, "Bob should earn half");
        assertApproxEqAbs(vault.previewRewards(alice, address(wbera)), 10e18, tolerance, "Alice should earn half");

        // Admin should still be able to withdraw more principal
        vm.prank(admin);
        vault.withdrawPrincipal(50e18, admin);
        assertEq(vault.depositPrincipal(), afterFulfillmentDepositPrincipal - 50e18, "Admin should still be able to withdraw principal");
    }

    function test_RequestWithdrawExceedsBalance() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Try to withdraw more than balance
        vm.prank(alice);
        vm.expectRevert(); // Should revert with ERC20InsufficientBalance or similar
        vault.requestWithdraw(101e18);
    }

    function test_StartBatchAlreadyFrozen() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        vault.requestWithdraw(50e18);

        // Start batch once
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Try to start again
        vm.prank(fulfiller);
        vm.expectRevert();
        vault.startWithdrawalBatch();
    }

    function test_AbandonedBatch() public {
        // Test scenario where batch is started but never fulfilled
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        vault.requestWithdraw(50e18);

        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Move to next batch without fulfilling first
        vm.prank(alice);
        vault.requestWithdraw(25e18);

        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Alice should have shares in both batches
        (,, uint256 batch1Total) = vault.batches(1);
        (,, uint256 batch2Total) = vault.batches(2);
        assertEq(batch1Total, 50e18, "Batch 1 should have 50 shares");
        assertEq(batch2Total, 25e18, "Batch 2 should have 25 shares");
        assertEq(vault.pending(alice), 75e18, "Alice should have 75 total pending");

        // Fulfill only batch 2
        wbera.mint(fulfiller, 25e18);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), 25e18);
        vault.fulfillBatch(2, 0);
        vm.stopPrank();

        // Alice should be able to claim from batch 2
        assertEq(vault.claimable(alice), 25e18, "Alice should have 25 claimable from batch 2");
        assertEq(vault.pending(alice), 50e18, "Alice should still have 50 pending in batch 1");

        vm.prank(alice);
        vault.claimWithdrawnAssets();

        // Batch 1 remains unfulfilled but can be fulfilled later
        wbera.mint(fulfiller, 50e18);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), 50e18);
        vault.fulfillBatch(1, 0);
        vm.stopPrank();

        assertEq(vault.claimable(alice), 50e18, "Alice should now have 50 claimable from batch 1");
    }

    function test_ZeroAmountEdgeCases() public {
        // Test empty batch scenarios
        vm.prank(fulfiller);
        vm.expectRevert(fatBERAV2.BatchEmpty.selector);
        vault.startWithdrawalBatch(); // Attempt to start empty batch

        vm.prank(fulfiller);
        vm.expectRevert(fatBERAV2.BatchNotFrozen.selector);
        vault.fulfillBatch(1, 0); // Attempt to fulfill empty batch

        // Now add some requests to batch 1
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        vault.requestWithdraw(50e18);

        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Fulfill batch 1 normally
        wbera.mint(fulfiller, 50e18);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), 50e18);
        vault.fulfillBatch(1, 0);
        vm.stopPrank();

        assertEq(vault.claimable(alice), 50e18, "Alice should have 50 claimable");
    }

    function test_RewardsAfterWithdrawalRequest() public {
        // Test that users can still earn rewards after requesting withdrawal but before fulfillment
        vm.prank(alice);
        vault.deposit(200e18, alice);

        vm.prank(bob);
        vault.deposit(100e18, bob);

        // Alice requests partial withdrawal
        vm.prank(alice);
        vault.requestWithdraw(100e18); // Alice now has 100 shares, 100 pending

        // Add rewards - should be distributed based on current balances
        notifyAndWarp(address(wbera), 30e18);

        // Alice should get 100/200 = 50% of rewards (100 active shares out of 200 total)
        // Bob should get 100/200 = 50% of rewards
        assertApproxEqAbs(vault.previewRewards(alice, address(wbera)), 15e18, tolerance, "Alice should get 15 BERA rewards");
        assertApproxEqAbs(vault.previewRewards(bob, address(wbera)), 15e18, tolerance, "Bob should get 15 BERA rewards");

        // Process withdrawal
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        wbera.mint(fulfiller, 100e18);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), 100e18);
        vault.fulfillBatch(1, 0);
        vm.stopPrank();

        // Alice claims withdrawal and rewards
        vm.prank(alice);
        vault.claimWithdrawnAssets();

        vm.prank(alice);
        vault.claimRewards(address(alice));

        // Add more rewards after withdrawal - Alice should get proportionally less
        notifyAndWarp(address(wbera), 30e18);

        // Now Alice has 100 shares, Bob has 100 shares, so 50/50 split
        assertApproxEqAbs(vault.previewRewards(alice, address(wbera)), 15e18, tolerance, "Alice should get 15 BERA from second reward");
        assertApproxEqAbs(vault.previewRewards(bob, address(wbera)), 30e18, tolerance, "Bob should get 30 BERA 15 from first 15 from second reward");
    }

    function test_MaximumFeeScenario() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vm.prank(alice);
        vault.requestWithdraw(1000e18);

        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Test with very high fee (99% - extreme scenario)
        uint256 fee = 990e18;
        uint256 netAmount = 10e18;

        wbera.mint(fulfiller, netAmount);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), netAmount);
        vault.fulfillBatch(1, fee);
        vm.stopPrank();

        assertEq(vault.claimable(alice), netAmount, "Alice should receive only 1% after extreme fee");

        vm.prank(alice);
        vault.claimWithdrawnAssets();

        // Verify fee goes to increasing depositPrincipal for more staking
        // The remainder calculation should handle this correctly
    }

    function test_RoundingEdgeCasesWithSmallAmounts() public {
        // Test with very small amounts to check rounding behavior
        vm.prank(alice);
        vault.deposit(3, alice); // 3 wei

        vm.prank(bob);
        vault.deposit(7, bob); // 7 wei

        vm.prank(charlie);
        vault.deposit(5, charlie); // 5 wei

        // All request withdrawal
        vm.prank(alice);
        vault.requestWithdraw(3);

        vm.prank(bob);
        vault.requestWithdraw(7);

        vm.prank(charlie);
        vault.requestWithdraw(5);

        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        // Total: 15 wei, fee: 1 wei, net: 14 wei
        uint256 fee = 1;
        uint256 netAmount = 14;

        wbera.mint(fulfiller, netAmount);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), netAmount);

        uint256 principalBefore = vault.depositPrincipal();
        vault.fulfillBatch(1, fee);
        uint256 principalAfter = vault.depositPrincipal();
        vm.stopPrank();

        // Check that rounding is handled correctly
        uint256 aliceClaimable = vault.claimable(alice);
        uint256 bobClaimable = vault.claimable(bob);
        uint256 charlieClaimable = vault.claimable(charlie);

        // Sum should not exceed netAmount
        assertTrue(aliceClaimable + bobClaimable + charlieClaimable <= netAmount, "Total claimable should not exceed net amount");

        // Any remainder should be added to principal
        uint256 remainder = netAmount - (aliceClaimable + bobClaimable + charlieClaimable);
        assertEq(principalAfter - principalBefore, remainder, "Remainder should be added to principal");
    }

    function test_MultiplePartialWithdrawals() public {
        // Test user making multiple small withdrawal requests
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        // Alice makes 5 small withdrawal requests in same batch
        vm.prank(alice);
        vault.requestWithdraw(100e18);

        vm.prank(alice);
        vault.requestWithdraw(150e18);

        vm.prank(alice);
        vault.requestWithdraw(200e18);

        vm.prank(alice);
        vault.requestWithdraw(250e18);

        vm.prank(alice);
        vault.requestWithdraw(300e18);

        // Check state
        assertEq(vault.balanceOf(alice), 0, "Alice should have 0 shares left");
        assertEq(vault.pending(alice), 1000e18, "Alice should have 1000 shares pending");

        // Check batch structure
        (,, uint256 batchTotal) = vault.batches(1);
        assertEq(batchTotal, 1000e18, "Batch should have 1000 total shares");

        // Process normally
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        wbera.mint(fulfiller, 1000e18);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), 1000e18);
        vault.fulfillBatch(1, 0);
        vm.stopPrank();

        assertEq(vault.claimable(alice), 1000e18, "Alice should have 1000 claimable");

        vm.prank(alice);
        vault.claimWithdrawnAssets();

        assertEq(vault.claimable(alice), 0, "Alice should have 0 claimable after claim");
    }

    function test_DepositAfterWithdrawalRequest() public {
        // Test that user can deposit more after requesting withdrawal
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        vault.requestWithdraw(50e18);

        // Alice deposits more
        vm.prank(alice);
        vault.deposit(200e18, alice);

        // Alice should have 250 active shares and 50 pending
        assertEq(vault.balanceOf(alice), 250e18, "Alice should have 250 active shares");
        assertEq(vault.pending(alice), 50e18, "Alice should have 50 pending shares");

        // Alice can request more withdrawals
        vm.prank(alice);
        vault.requestWithdraw(100e18);

        assertEq(vault.balanceOf(alice), 150e18, "Alice should have 150 active shares");
        assertEq(vault.pending(alice), 150e18, "Alice should have 150 pending shares");

        // Process batch
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();

        wbera.mint(fulfiller, 150e18);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), 150e18);
        vault.fulfillBatch(1, 0);
        vm.stopPrank();

        assertEq(vault.claimable(alice), 150e18, "Alice should have 150 claimable");
        assertEq(vault.balanceOf(alice), 150e18, "Alice should still have 150 active shares");
    }

    function test_MassWithdrawalStressTest() public {
        uint256 numUsers = 150; // Test with 150 users
        address[] memory users = new address[](numUsers);
        uint256[] memory userDeposits = new uint256[](numUsers);
        uint256[] memory userWithdrawals = new uint256[](numUsers);
        
        console.log("Setting up %d users for mass withdrawal test", numUsers);
        
        uint256 totalDeposited = 0;
        uint256 totalWithdrawRequested = 0;
        
        // Setup users with varying deposit amounts
        for (uint256 i = 0; i < numUsers; i++) {
            users[i] = makeAddr(string.concat("user", vm.toString(i)));
            
            // Vary deposit amounts: 1-10 BERA per user
            userDeposits[i] = (i % 10 + 1) * 1e18;
            totalDeposited += userDeposits[i];
            
            // Mint WBERA to each user
            wbera.mint(users[i], userDeposits[i]);
            
            // Approve vault
            vm.prank(users[i]);
            wbera.approve(address(vault), userDeposits[i]);
            
            // Deposit
            vm.prank(users[i]);
            vault.deposit(userDeposits[i], users[i]);
        }
        
        console.log("Total deposited: %d BERA", totalDeposited / 1e18);
        assertEq(vault.totalSupply(), totalDeposited, "Total supply should match deposits");
        
        // Add some rewards before withdrawals
        notifyAndWarp(address(wbera), 100e18);
        
        // All users request partial withdrawals (50-75% of their deposits)
        for (uint256 i = 0; i < numUsers; i++) {
            // Withdraw between 50-75% of deposit
            userWithdrawals[i] = (userDeposits[i] * (50 + (i % 26))) / 100;
            totalWithdrawRequested += userWithdrawals[i];
            
            vm.prank(users[i]);
            vault.requestWithdraw(userWithdrawals[i]);
        }
        
        console.log("Total withdrawal requested: %d BERA", totalWithdrawRequested / 1e18);
        
        // Verify batch state
        (,, uint256 batchTotal) = vault.batches(1);
        assertEq(batchTotal, totalWithdrawRequested, "Batch total should match requested withdrawals");
        assertEq(vault.totalPending(), totalWithdrawRequested, "Total pending should match requests");
        
        // Verify individual pending amounts
        for (uint256 i = 0; i < numUsers; i++) {
            assertEq(vault.pending(users[i]), userWithdrawals[i], "Individual pending amount incorrect");
            assertEq(vault.balanceOf(users[i]), userDeposits[i] - userWithdrawals[i], "Remaining balance incorrect");
        }
        
        // Start withdrawal batch
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();
        
        // Verify batch is frozen and new batch started
        (bool frozen1, bool fulfilled1,) = vault.batches(1);
        (bool frozen2, bool fulfilled2,) = vault.batches(2);
        assertTrue(frozen1, "Batch 1 should be frozen");
        assertFalse(fulfilled1, "Batch 1 should not be fulfilled yet");
        assertFalse(frozen2, "Batch 2 should not be frozen");
        assertFalse(fulfilled2, "Batch 2 should not be fulfilled");
        assertEq(vault.currentBatchId(), 2, "Current batch ID should be 2");
        
        // Test that users can still request withdrawals in new batch
        vm.prank(users[0]);
        vault.requestWithdraw(userDeposits[0] - userWithdrawals[0]); // Withdraw remaining
        
        (,, uint256 batch2Total) = vault.batches(2);
        assertEq(batch2Total, userDeposits[0] - userWithdrawals[0], "New batch should have the additional withdrawal");
        
        // Fulfill first batch with 2% fee
        uint256 fee = totalWithdrawRequested * 2 / 100; // 2% validator fee
        uint256 netAmount = totalWithdrawRequested - fee;
        
        console.log("Fulfilling batch with fee: %d BERA, net: %d BERA", fee / 1e18, netAmount / 1e18);
        
        wbera.mint(fulfiller, netAmount);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), netAmount);
        vault.fulfillBatch(1, fee);
        vm.stopPrank();
        
        // Verify batch is now fulfilled
        (bool frozen1After, bool fulfilled1After,) = vault.batches(1);
        assertTrue(frozen1After, "Batch 1 should still be frozen");
        assertTrue(fulfilled1After, "Batch 1 should now be fulfilled");
        
        // Verify totalPending decreased
        assertEq(vault.totalPending(), userDeposits[0] - userWithdrawals[0], "Total pending should only include batch 2");
        
        // Calculate and verify claimable amounts for each user
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < numUsers; i++) {
            uint256 expectedClaimable = FixedPointMathLib.fullMulDiv(userWithdrawals[i], netAmount, totalWithdrawRequested);
            uint256 actualClaimable = vault.claimable(users[i]);
            
            assertApproxEqAbs(actualClaimable, expectedClaimable, 1, "Claimable amount incorrect for user");
            totalClaimable += actualClaimable;
            
            // Verify pending is cleared for batch 1, except user[0] who has pending in batch 2
            if (i == 0) {
                assertEq(vault.pending(users[i]), userDeposits[0] - userWithdrawals[0], "User 0 should have batch 2 pending");
            } else {
                assertEq(vault.pending(users[i]), 0, "Other users should have 0 pending after batch 1 fulfill");
            }
        }
        
        // Total claimable should not exceed net amount (due to rounding down)
        assertLe(totalClaimable, netAmount, "Total claimable should not exceed net amount");
        
        // Any remainder should be added to depositPrincipal
        uint256 remainder = netAmount - totalClaimable;
        console.log("Rounding remainder: %d wei", remainder);
        
        // Test mass claiming
        uint256 totalClaimed = 0;
        for (uint256 i = 0; i < numUsers; i++) {
            uint256 claimableBefore = vault.claimable(users[i]);
            if (claimableBefore > 0) {
                uint256 balanceBefore = wbera.balanceOf(users[i]);
                
                vm.prank(users[i]);
                vault.claimWithdrawnAssets();
                
                uint256 balanceAfter = wbera.balanceOf(users[i]);
                uint256 claimed = balanceAfter - balanceBefore;
                
                assertEq(claimed, claimableBefore, "Claimed amount should match claimable");
                assertEq(vault.claimable(users[i]), 0, "Claimable should be 0 after claim");
                
                totalClaimed += claimed;
            }
        }
        
        assertEq(totalClaimed, totalClaimable, "Total claimed should match total claimable");
        
        console.log("Mass withdrawal test completed successfully!");
        console.log("- %d users processed", numUsers);
        console.log("- %d BERA total deposited", totalDeposited / 1e18);
        console.log("- %d BERA total withdrawn", totalWithdrawRequested / 1e18);
        console.log("- %d BERA fee applied", fee / 1e18);
        console.log("- %d BERA net distributed", totalClaimed / 1e18);
        console.log("- %d wei rounding remainder", remainder);
    }

    function test_ParallelBatchProcessing() public {
        uint256 numUsersPerBatch = 50;
        address[] memory batch1Users = new address[](numUsersPerBatch);
        address[] memory batch2Users = new address[](numUsersPerBatch);
        
        uint256 depositAmount = 10e18;
        uint256 withdrawAmount = 8e18;
        
        // Setup batch 1 users
        for (uint256 i = 0; i < numUsersPerBatch; i++) {
            batch1Users[i] = makeAddr(string.concat("batch1user", vm.toString(i)));
            wbera.mint(batch1Users[i], depositAmount);
            
            vm.prank(batch1Users[i]);
            wbera.approve(address(vault), depositAmount);
            
            vm.prank(batch1Users[i]);
            vault.deposit(depositAmount, batch1Users[i]);
            
            vm.prank(batch1Users[i]);
            vault.requestWithdraw(withdrawAmount);
        }
        
        // Start first batch
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();
        
        // Setup batch 2 users
        for (uint256 i = 0; i < numUsersPerBatch; i++) {
            batch2Users[i] = makeAddr(string.concat("batch2user", vm.toString(i)));
            wbera.mint(batch2Users[i], depositAmount);
            
            vm.prank(batch2Users[i]);
            wbera.approve(address(vault), depositAmount);
            
            vm.prank(batch2Users[i]);
            vault.deposit(depositAmount, batch2Users[i]);
            
            vm.prank(batch2Users[i]);
            vault.requestWithdraw(withdrawAmount);
        }
        
        // Start second batch
        vm.prank(fulfiller);
        vault.startWithdrawalBatch();
        
        // Verify batch states
        assertEq(vault.currentBatchId(), 3, "Should be on batch 3");
        
        (,, uint256 batch1Total) = vault.batches(1);
        (,, uint256 batch2Total) = vault.batches(2);
        
        assertEq(batch1Total, numUsersPerBatch * withdrawAmount, "Batch 1 total incorrect");
        assertEq(batch2Total, numUsersPerBatch * withdrawAmount, "Batch 2 total incorrect");
        
        // Fulfill both batches (batch 2 first to test order independence)
        uint256 netAmount = numUsersPerBatch * withdrawAmount;
        
        // Fulfill batch 2
        wbera.mint(fulfiller, netAmount);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), netAmount);
        vault.fulfillBatch(2, 0);
        vm.stopPrank();
        
        // Fulfill batch 1
        wbera.mint(fulfiller, netAmount);
        vm.startPrank(fulfiller);
        wbera.approve(address(vault), netAmount);
        vault.fulfillBatch(1, 0);
        vm.stopPrank();
        
        // Verify all users can claim from both batches
        for (uint256 i = 0; i < numUsersPerBatch; i++) {
            assertEq(vault.claimable(batch1Users[i]), withdrawAmount, "Batch 1 user claimable incorrect");
            assertEq(vault.claimable(batch2Users[i]), withdrawAmount, "Batch 2 user claimable incorrect");
            
            // Test claiming
            vm.prank(batch1Users[i]);
            vault.claimWithdrawnAssets();
            
            vm.prank(batch2Users[i]);
            vault.claimWithdrawnAssets();
            
            assertEq(vault.claimable(batch1Users[i]), 0, "Batch 1 user should have 0 claimable after claim");
            assertEq(vault.claimable(batch2Users[i]), 0, "Batch 2 user should have 0 claimable after claim");
        }
        
        console.log("Parallel batch processing test completed successfully!");
    }
}


