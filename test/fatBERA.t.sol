// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test, console2} from "forge-std/Test.sol";
import {fatBERA} from "../src/fatBERA.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract fatBERATest is Test {
    uint256 public maxDeposits  = 1000000 ether;
    address public owner        = makeAddr("owner");
    address public alice        = makeAddr("alice");
    address public bob          = makeAddr("bob");
    address public charlie      = makeAddr("charlie");

    fatBERA public vault;
    MockERC20 public wbera;

    uint256 public constant INITIAL_MINT = 2000000 ether;

    function setUp() public {
        // Deploy mock WBERA
        wbera = new MockERC20("Wrapped BERA", "WBERA", 18);

        // Deploy implementation and proxy
        bytes memory initData = abi.encodeWithSelector(fatBERA.initialize.selector, address(wbera), owner, maxDeposits);
        vault = fatBERA(payable(Upgrades.deployUUPSProxy("fatBERA.sol:fatBERA", initData)));

        // Mint initial WBERA to test accounts
        wbera.mint(alice, INITIAL_MINT);
        wbera.mint(bob, INITIAL_MINT);
        wbera.mint(charlie, INITIAL_MINT);
        wbera.mint(owner, INITIAL_MINT);

        // Approve vault to spend WBERA
        vm.prank(alice);
        wbera.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        wbera.approve(address(vault), type(uint256).max);
        vm.prank(charlie);
        wbera.approve(address(vault), type(uint256).max);
        vm.prank(owner);
        wbera.approve(address(vault), type(uint256).max);
    }

    function test_Initialize() public view {
        assertEq(vault.owner(), owner);
        assertEq(address(vault.asset()), address(wbera));
        assertEq(vault.paused(), true);
        assertEq(vault.rewardPerShareStored(), 0);
        assertEq(vault.depositPrincipal(), 0);
    }

    function test_DepositWhenPaused() public {
        // Should succeed even when paused
        vm.prank(alice);
        uint256 sharesMinted = vault.deposit(100e18, alice);

        assertEq(sharesMinted, 100e18, "Shares should be 1:1 with deposit");
        assertEq(vault.balanceOf(alice), 100e18);
    }

    function test_WithdrawWhenPaused() public {
        // First deposit (should work while paused)
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Try to withdraw while paused (should fail)
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(50e18, alice, alice);
    }

    function test_PreviewRewardsAccuracy() public {
        // Alice deposits 100 WBERA
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // First reward: 10 WBERA
        vm.prank(owner);
        wbera.transfer(address(vault), 10e18);
        vm.prank(owner);
        vault.notifyRewardAmount(10e18);

        // Manual calculation for first reward
        uint256 expectedRewardPerShare = (10e18 * 1e18) / 100e18; // Should be 0.1e18
        uint256 expectedAliceReward = (100e18 * expectedRewardPerShare) / 1e18; // Should be 10e18

        assertEq(vault.rewardPerShareStored(), expectedRewardPerShare, "Reward per share calculation mismatch");
        assertEq(vault.previewRewards(alice), expectedAliceReward, "First reward preview mismatch");
        assertEq(vault.previewRewards(alice), 10e18, "First reward should be 10 WBERA");

        // Bob deposits 100 WBERA
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // Second reward: 20 WBERA
        vm.prank(owner);
        wbera.transfer(address(vault), 20e18);
        vm.prank(owner);
        vault.notifyRewardAmount(20e18);

        // Manual calculation for second reward
        uint256 secondRewardPerShare = (20e18 * 1e18) / 200e18; // Should be 0.1e18

        // Alice's total expected: First reward (10) + (100 shares * 0.1 from second reward)
        uint256 expectedAliceTotalReward = 10e18 + ((100e18 * secondRewardPerShare) / 1e18);
        // Bob's expected: (100 shares * 0.1 from second reward only)
        uint256 expectedBobReward = (100e18 * secondRewardPerShare) / 1e18;

        assertEq(vault.previewRewards(alice), expectedAliceTotalReward, "Alice's second reward preview mismatch");
        assertEq(vault.previewRewards(alice), 20e18, "Alice should have 20 WBERA total rewards");
        assertEq(vault.previewRewards(bob), expectedBobReward, "Bob's reward preview mismatch");
        assertEq(vault.previewRewards(bob), 10e18, "Bob should have 10 WBERA rewards");

        // Verify reward tracking after Alice claims
        vm.prank(alice);
        vault.claimRewards();
        assertEq(vault.previewRewards(alice), 0, "Alice should have 0 rewards after claim");
        assertEq(vault.previewRewards(bob), 10e18, "Bob's rewards unchanged after Alice's claim");
    }

    function test_BasicDepositAndReward() public {
        // Alice deposits 100 WBERA
        uint256 aliceDeposit = 100e18;
        vm.prank(alice);
        uint256 sharesMinted = vault.deposit(aliceDeposit, alice);

        assertEq(sharesMinted, aliceDeposit, "Shares should be 1:1 with deposit");
        assertEq(vault.balanceOf(alice), aliceDeposit);
        assertEq(vault.depositPrincipal(), aliceDeposit);
        assertEq(vault.totalSupply(), aliceDeposit);
        assertEq(vault.totalAssets(), aliceDeposit);

        // Owner notifies 10 WBERA as reward
        uint256 rewardAmount = 10e18;
        vm.prank(owner);
        wbera.transfer(address(vault), rewardAmount);
        vm.prank(owner);
        vault.notifyRewardAmount(rewardAmount);

        // Check Alice's claimable rewards
        assertEq(vault.previewRewards(alice), rewardAmount, "All rewards should go to Alice");
    }

    function test_MultipleDepositorsRewardDistribution() public {
        vm.prank(owner);
        vault.unpause();

        // Alice deposits 100 WBERA
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Owner adds 10 WBERA reward
        vm.prank(owner);
        wbera.transfer(address(vault), 10e18);
        vm.prank(owner);
        vault.notifyRewardAmount(10e18);

        // Bob deposits 100 WBERA
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // Owner adds another 10 WBERA reward
        vm.prank(owner);
        wbera.transfer(address(vault), 10e18);
        vm.prank(owner);
        vault.notifyRewardAmount(10e18);

        // Check rewards
        assertEq(vault.previewRewards(alice), 15e18, "Alice should have first reward + half of second");
        assertEq(vault.previewRewards(bob), 5e18, "Bob should have half of second reward only");
    }

    function test_ClaimRewards() public {
        vm.prank(owner);
        vault.unpause();

        // Alice deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Add reward
        vm.prank(owner);
        wbera.transfer(address(vault), 10e18);
        vm.prank(owner);
        vault.notifyRewardAmount(10e18);

        // Record balance before claim
        uint256 balanceBefore = wbera.balanceOf(alice);

        // Claim rewards
        vm.prank(alice);
        vault.claimRewards();

        // Verify reward received
        assertEq(wbera.balanceOf(alice) - balanceBefore, 10e18, "Should receive full reward");
        assertEq(vault.previewRewards(alice), 0, "Rewards should be zero after claim");
    }

    function test_OwnerWithdrawPrincipal() public {
        vm.prank(owner);
        vault.unpause();

        // Alice deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Owner withdraws principal for staking
        vm.prank(owner);
        vault.withdrawPrincipal(50e18, owner);

        // Check state
        assertEq(vault.depositPrincipal(), 50e18, "Principal should be reduced");
        assertEq(vault.totalSupply(), 100e18, "Total supply unchanged");
        assertEq(vault.totalAssets(), 100e18, "Total assets matches supply");
        assertEq(vault.balanceOf(alice), 100e18, "Alice's shares unchanged");
    }

    function test_WithdrawWithRewards() public {
        vm.prank(owner);
        vault.unpause();

        // Alice deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Add reward
        vm.prank(owner);
        wbera.transfer(address(vault), 10e18);
        vm.prank(owner);
        vault.notifyRewardAmount(10e18);

        // Record balance before withdrawal
        uint256 balanceBefore = wbera.balanceOf(alice);

        // Withdraw half
        vm.prank(alice);
        vault.withdraw(50e18, alice, alice);

        // Verify
        uint256 totalReceived = wbera.balanceOf(alice) - balanceBefore;
        assertEq(totalReceived, 60e18, "Should receive withdrawal + rewards");
        assertEq(vault.balanceOf(alice), 50e18, "Should have half shares left");
    }

    function test_RedeemWithRewards() public {
        vm.prank(owner);
        vault.unpause();

        // Alice deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Add reward
        vm.prank(owner);
        wbera.transfer(address(vault), 10e18);
        vm.prank(owner);
        vault.notifyRewardAmount(10e18);

        // Record balance before redeem
        uint256 balanceBefore = wbera.balanceOf(alice);

        // Redeem half shares
        vm.prank(alice);
        vault.redeem(50e18, alice, alice);

        // Verify
        uint256 totalReceived = wbera.balanceOf(alice) - balanceBefore;
        assertEq(totalReceived, 60e18, "Should receive redemption + rewards");
        assertEq(vault.balanceOf(alice), 50e18, "Should have half shares left");
    }

    function test_CannotWithdrawWhenPaused() public {
        vm.prank(owner);
        vault.unpause();

        // Alice deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Pause vault
        vm.prank(owner);
        vault.pause();

        // Try to withdraw
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(50e18, alice, alice);
    }

    function test_MultipleRewardCycles() public {
        vm.prank(owner);
        vault.unpause();

        // Alice and Bob deposit
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // First reward cycle
        vm.prank(owner);
        wbera.transfer(address(vault), 10e18);
        vm.prank(owner);
        vault.notifyRewardAmount(10e18);

        // Alice claims
        vm.prank(alice);
        vault.claimRewards();

        // Second reward cycle
        vm.prank(owner);
        wbera.transfer(address(vault), 10e18);
        vm.prank(owner);
        vault.notifyRewardAmount(10e18);

        // Verify rewards
        assertEq(vault.previewRewards(alice), 5e18, "Alice should have half of second reward");
        assertEq(vault.previewRewards(bob), 10e18, "Bob should have unclaimed rewards from both cycles");
    }

    function test_RewardDistributionWithPartialClaims() public {
        // Alice deposits 100
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // First reward: 10 WBERA
        vm.prank(owner);
        wbera.transfer(address(vault), 10e18);
        vm.prank(owner);
        vault.notifyRewardAmount(10e18);

        // Bob deposits 100
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // Alice claims her first reward
        vm.prank(alice);
        vault.claimRewards();

        // Second reward: 20 WBERA (split between Alice and Bob)
        vm.prank(owner);
        wbera.transfer(address(vault), 20e18);
        vm.prank(owner);
        vault.notifyRewardAmount(20e18);

        // Charlie deposits 200
        vm.prank(charlie);
        vault.deposit(200e18, charlie);

        // Third reward: 30 WBERA (split between all three)
        vm.prank(owner);
        wbera.transfer(address(vault), 40e18);
        vm.prank(owner);
        vault.notifyRewardAmount(40e18);

        // Verify final reward states
        assertEq(vault.previewRewards(alice), 20e18, "Alice should have share of second and third rewards");
        assertEq(vault.previewRewards(bob), 20e18, "Bob should have all unclaimed rewards");
        assertEq(vault.previewRewards(charlie), 20e18, "Charlie should have share of third reward only");
    }

    function test_SequentialDepositsAndRewards() public {
        // Alice deposits 100
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Reward 1: 10 WBERA
        vm.prank(owner);
        wbera.transfer(address(vault), 10e18);
        vm.prank(owner);
        vault.notifyRewardAmount(10e18);

        // Bob deposits 200
        vm.prank(bob);
        vault.deposit(200e18, bob);

        // Reward 2: 30 WBERA
        vm.prank(owner);
        wbera.transfer(address(vault), 30e18);
        vm.prank(owner);
        vault.notifyRewardAmount(30e18);

        // Alice claims
        vm.prank(alice);
        vault.claimRewards();

        // Charlie deposits 300
        vm.prank(charlie);
        vault.deposit(300e18, charlie);

        // Reward 3: 60 WBERA
        vm.prank(owner);
        wbera.transfer(address(vault), 60e18);
        vm.prank(owner);
        vault.notifyRewardAmount(60e18);

        // Verify complex reward distribution
        assertEq(vault.previewRewards(alice), 10e18, "Alice's new rewards after claim");
        assertEq(vault.previewRewards(bob), 40e18, "Bob's accumulated rewards");
        assertEq(vault.previewRewards(charlie), 30e18, "Charlie's portion of last reward");
    }

    function test_WithdrawAfterMultipleRewardCycles() public {
        // Alice and Bob deposit 100 each
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // First reward cycle
        vm.prank(owner);
        wbera.transfer(address(vault), 20e18);
        vm.prank(owner);
        vault.notifyRewardAmount(20e18);

        // Alice claims but Bob doesn't
        vm.prank(alice);
        vault.claimRewards();

        // Second reward cycle
        vm.prank(owner);
        wbera.transfer(address(vault), 10e18);
        vm.prank(owner);
        vault.notifyRewardAmount(10e18);

        // Enable withdrawals
        vm.prank(owner);
        vault.unpause();

        // Alice withdraws half
        vm.prank(alice);
        vault.withdraw(50e18, alice, alice);

        // Third reward cycle
        vm.prank(owner);
        wbera.transfer(address(vault), 30e18);
        vm.prank(owner);
        vault.notifyRewardAmount(30e18);

        // Verify final states
        assertEq(vault.balanceOf(alice), 50e18, "Alice's remaining shares");
        assertEq(vault.balanceOf(bob), 100e18, "Bob's unchanged shares");
        assertEq(vault.previewRewards(alice), 10e18, "Alice's new rewards");
        assertEq(vault.previewRewards(bob), 35e18, "Bob's total unclaimed rewards");
    }

    function test_notifyRewardAmount() public {
        // Try to notify reward with no deposits
        vm.prank(owner);
        wbera.transfer(address(vault), 10e18);
        vm.prank(owner);
        vault.notifyRewardAmount(10e18);

        // Alice deposits after failed reward
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Verify no rewards from before deposit
        assertEq(vault.previewRewards(alice), 0, "Should have no rewards from before deposit");

        // New reward should work
        vm.prank(owner);
        wbera.transfer(address(vault), 10e18);
        vm.prank(owner);
        vault.notifyRewardAmount(10e18);
        assertEq(vault.previewRewards(alice), 10e18, "Should receive new rewards");
    }

    function test_ComplexWithdrawScenario() public {
        // Initial deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(200e18, bob);

        // First reward
        vm.prank(owner);
        wbera.transfer(address(vault), 30e18);
        vm.prank(owner);
        vault.notifyRewardAmount(30e18);

        // bob balance before claim
        uint256 bobBalanceBefore = wbera.balanceOf(bob);

        // Bob claims
        vm.prank(bob);
        vault.claimRewards();

        // verify bob received rewards
        assertEq(wbera.balanceOf(bob) - bobBalanceBefore, 20e18, "Bob should have received 20 WBERA");

        // Charlie deposits
        vm.prank(charlie);
        vault.deposit(300e18, charlie);

        // Second reward
        vm.prank(owner);
        wbera.transfer(address(vault), 60e18);
        vm.prank(owner);
        vault.notifyRewardAmount(60e18);

        // Enable withdrawals
        vm.prank(owner);
        vault.unpause();

        // Record balances before withdrawals
        uint256 aliceBalanceBefore = wbera.balanceOf(alice);
        bobBalanceBefore = wbera.balanceOf(bob);

        // Alice and Bob withdraw half
        vm.prank(alice);
        vault.withdraw(50e18, alice, alice);
        vm.prank(bob);
        vault.withdraw(100e18, bob, bob);

        // Verify withdrawals include correct rewards
        assertEq(
            wbera.balanceOf(alice) - aliceBalanceBefore,
            70e18, // 50 principal + 20 reward
            "Alice's withdrawal amount incorrect"
        );
        assertEq(
            wbera.balanceOf(bob) - bobBalanceBefore,
            120e18, // 100 principal + 20 reward
            "Bob's withdrawal amount incorrect"
        );

        // Third reward
        vm.prank(owner);
        wbera.transfer(address(vault), 90e18);
        vm.prank(owner);
        vault.notifyRewardAmount(90e18);

        // Verify final reward state
        assertEq(vault.previewRewards(alice), 10e18, "Alice's new rewards");
        assertEq(vault.previewRewards(bob), 20e18, "Bob's new rewards");
        assertEq(vault.previewRewards(charlie), 90e18, "Charlie's total rewards");
    }

    function test_OwnerWithdrawAndRewardCycles() public {
        // Initial deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // Owner withdraws 150 for staking
        vm.prank(owner);
        vault.withdrawPrincipal(150e18, owner);

        // Verify deposit principal reduced but shares unchanged
        assertEq(vault.depositPrincipal(), 50e18, "Deposit principal should be reduced");
        assertEq(vault.totalSupply(), 200e18, "Total supply should be unchanged");

        // Add rewards (simulating staking returns)
        vm.prank(owner);
        wbera.transfer(address(vault), 30e18);
        vm.prank(owner);
        vault.notifyRewardAmount(30e18);

        // Verify rewards still work correctly
        assertEq(vault.previewRewards(alice), 15e18, "Alice's reward share");
        assertEq(vault.previewRewards(bob), 15e18, "Bob's reward share");
    }

    function test_MaxDeposits() public {
        // Try to deposit more than max
        vm.prank(alice);
        vm.expectRevert(fatBERA.ExceedsMaxDeposits.selector);
        vault.deposit(maxDeposits + 1, alice);

        // Deposit up to max should work
        vm.prank(alice);
        vault.deposit(maxDeposits, alice);

        // Any further deposit should fail
        vm.prank(bob);
        vm.expectRevert(fatBERA.ExceedsMaxDeposits.selector);
        vault.deposit(1, bob);
    }

    function test_MaxDepositsWithMint() public {
        // Try to mint shares that would require more than max deposits
        vm.prank(alice);
        vm.expectRevert(fatBERA.ExceedsMaxDeposits.selector);
        vault.mint(maxDeposits + 1, alice);

        // Mint up to max should work
        vm.prank(alice);
        vault.mint(maxDeposits, alice);

        // Any further mint should fail
        vm.prank(bob);
        vm.expectRevert(fatBERA.ExceedsMaxDeposits.selector);
        vault.mint(1, bob);
    }

    function test_MaxDepositsUpdate() public {
        // Initial deposit
        vm.prank(alice);
        vault.deposit(500_000 ether, alice);

        // Try to set max deposits below current deposits
        vm.prank(owner);
        vm.expectRevert(fatBERA.InvalidMaxDeposits.selector);
        vault.setMaxDeposits(400_000 ether);

        // Update max deposits to a higher value
        vm.prank(owner);
        vault.setMaxDeposits(2_000_000 ether);

        // Should now be able to deposit more
        vm.prank(bob);
        vault.deposit(1_000_000 ether, bob);

        // But not exceed new max
        vm.prank(charlie);
        vm.expectRevert(fatBERA.ExceedsMaxDeposits.selector);
        vault.deposit(600_000 ether, charlie);
    }

    function test_MaxDepositsWithMultipleUsers() public {
        // First user deposits half of max
        vm.prank(alice);
        vault.deposit(maxDeposits / 2, alice);

        // Second user tries to deposit slightly more than remaining
        vm.prank(bob);
        vm.expectRevert(fatBERA.ExceedsMaxDeposits.selector);
        vault.deposit((maxDeposits / 2) + 1, bob);

        // Second user deposits exactly remaining amount
        vm.prank(bob);
        vault.deposit(maxDeposits / 2, bob);

        // Third user can't deposit anything
        vm.prank(charlie);
        vm.expectRevert(fatBERA.ExceedsMaxDeposits.selector);
        vault.deposit(1, charlie);

        // Verify total deposits
        assertEq(vault.depositPrincipal(), maxDeposits, "Total deposits should equal max");
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

    function testFuzz_WithdrawPartial(uint256 depositAmount, uint256 withdrawAmount) public {
        // Bound deposit amount between 2 and maxDeposits
        depositAmount = bound(depositAmount, 2, maxDeposits);
        // Bound withdraw amount between 1 and deposit amount
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);

        // Enable withdrawals
        vm.prank(owner);
        vault.unpause();

        // Deposit
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Withdraw
        vm.prank(alice);
        uint256 sharesBurned = vault.withdraw(withdrawAmount, alice, alice);

        assertEq(sharesBurned, withdrawAmount, "Shares burned should equal withdrawal");
        assertEq(vault.balanceOf(alice), depositAmount - withdrawAmount, "Remaining balance incorrect");
        assertEq(vault.depositPrincipal(), depositAmount - withdrawAmount, "Remaining principal incorrect");
    }

    function testFuzz_RedeemPartial(uint256 depositAmount, uint256 redeemShares) public {
        // Bound deposit amount between 2 and maxDeposits
        depositAmount = bound(depositAmount, 2, maxDeposits);
        // Bound redeem shares between 1 and deposit amount
        redeemShares = bound(redeemShares, 1, depositAmount);

        // Enable withdrawals
        vm.prank(owner);
        vault.unpause();

        // Deposit
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Redeem
        vm.prank(alice);
        uint256 assetsReceived = vault.redeem(redeemShares, alice, alice);

        assertEq(assetsReceived, redeemShares, "Assets received should equal shares for 1:1 ratio");
        assertEq(vault.balanceOf(alice), depositAmount - redeemShares, "Remaining balance incorrect");
        assertEq(vault.depositPrincipal(), depositAmount - redeemShares, "Remaining principal incorrect");
    }

    function testFuzz_NotifyRewardAmount(uint256 depositAmount, uint256 rewardAmount) public {
        // Bound deposit amount between 1 and maxDeposits
        depositAmount = bound(depositAmount, 1, maxDeposits);
        // Bound reward amount between 1 and maxDeposits (reasonable range for rewards)
        rewardAmount = bound(rewardAmount, 1, maxDeposits);

        // Initial deposit
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Add reward
        vm.prank(owner);
        wbera.transfer(address(vault), rewardAmount);
        vm.prank(owner);
        vault.notifyRewardAmount(rewardAmount);

        // Record balance before claim
        uint256 balanceBefore = wbera.balanceOf(alice);

        // Claim rewards
        vm.prank(alice);
        vault.claimRewards();

        // Verify actual rewards received (allow for small rounding differences)
        uint256 rewardsReceived = wbera.balanceOf(alice) - balanceBefore;
        assertApproxEqAbs(rewardsReceived, rewardAmount, 1, "Reward amount received should be approximately equal");
    }

    function testFuzz_MultiUserRewardDistribution(
        uint256 aliceDeposit,
        uint256 bobDeposit,
        uint256 rewardAmount
    ) public {
        // Bound deposits to avoid overflow and unrealistic values
        aliceDeposit = bound(aliceDeposit, 1, maxDeposits / 2);
        bobDeposit = bound(bobDeposit, 1, maxDeposits - aliceDeposit);
        // Bound reward to a reasonable range
        rewardAmount = bound(rewardAmount, 1, maxDeposits);

        // Alice and Bob deposit
        vm.prank(alice);
        vault.deposit(aliceDeposit, alice);
        vm.prank(bob);
        vault.deposit(bobDeposit, bob);

        // Add reward
        vm.prank(owner);
        wbera.transfer(address(vault), rewardAmount);
        vm.prank(owner);
        vault.notifyRewardAmount(rewardAmount);

        // Calculate expected rewards using the same mulDiv logic as the contract
        uint256 totalDeposits = aliceDeposit + bobDeposit;
        uint256 expectedAliceReward = FixedPointMathLib.mulDiv(rewardAmount, aliceDeposit, totalDeposits);
        uint256 expectedBobReward = FixedPointMathLib.mulDiv(rewardAmount, bobDeposit, totalDeposits);

        // Record balances before claims
        uint256 aliceBalanceBefore = wbera.balanceOf(alice);
        uint256 bobBalanceBefore = wbera.balanceOf(bob);

        // Claim rewards
        vm.prank(alice);
        vault.claimRewards();
        vm.prank(bob);
        vault.claimRewards();

        // Verify actual rewards received (allow for small rounding differences)
        uint256 aliceRewardsReceived = wbera.balanceOf(alice) - aliceBalanceBefore;
        uint256 bobRewardsReceived = wbera.balanceOf(bob) - bobBalanceBefore;

        // Verify rewards are approximately equal to expected amounts
        assertApproxEqAbs(aliceRewardsReceived, expectedAliceReward, 1, "Alice rewards should be approximately equal to expected");
        assertApproxEqAbs(bobRewardsReceived, expectedBobReward, 1, "Bob rewards should be approximately equal to expected");
        
        // Verify total rewards distributed are approximately equal to input amount
        uint256 totalRewardsReceived = aliceRewardsReceived + bobRewardsReceived;
        assertApproxEqAbs(totalRewardsReceived, rewardAmount, 1, "Total rewards should be approximately equal to reward amount");
    }
}
