// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test, console2} from "forge-std/Test.sol";
import {fatBERA} from "../src/fatBERA.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract fatBERATest is Test {
    uint256 public maxDeposits  = 36000000 ether;
    address public admin        = makeAddr("admin");
    address public alice        = makeAddr("alice");
    address public bob          = makeAddr("bob");
    address public charlie      = makeAddr("charlie");

    fatBERA public vault;
    MockWETH public wbera;
    MockERC20 public rewardToken1;
    MockERC20 public rewardToken2;

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
            admin,  // Now initial admin
            maxDeposits
        );

        // Deploy proxy using the implementation - match deployment script approach
        address proxy = Upgrades.deployUUPSProxy(
            "fatBERA.sol:fatBERA",
            initData
        );
        vault = fatBERA(payable(proxy));

        // Debug logs
        console2.log("Admin address:", admin);
        console2.log("Proxy address:", address(proxy));
        console2.log("Implementation address:", Upgrades.getImplementationAddress(address(proxy)));
        console2.log("Admin has DEFAULT_ADMIN_ROLE:", vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        console2.log("Admin has REWARD_NOTIFIER_ROLE:", vault.hasRole(vault.REWARD_NOTIFIER_ROLE(), admin));

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
        vm.prank(admin);
        wbera.approve(address(vault), type(uint256).max);

        // Fund test accounts with ETH
        vm.deal(alice, INITIAL_MINT);
        vm.deal(bob, INITIAL_MINT);
        vm.deal(charlie, INITIAL_MINT);
    }

    function test_Initialize() public view {
        // Check roles instead of owner
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "Admin should have DEFAULT_ADMIN_ROLE");
        assertEq(address(vault.asset()), address(wbera));
        assertEq(vault.paused(), true);
        (uint256 rewardPerShareStored, uint256 totalRewards) = vault.rewardData(address(wbera));
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
        vm.prank(admin);
        wbera.transfer(address(vault), 10e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera), 10e18);

        // Manual calculation for first reward
        uint256 expectedRewardPerShare = (10e18 * 1e36) / 100e18; // Should be 0.1e36
        uint256 expectedAliceReward = (100e18 * expectedRewardPerShare) / 1e36; // Should be 10e18

        (uint256 rewardPerShareStored, uint256 totalRewards) = vault.rewardData(address(wbera));
        assertEq(rewardPerShareStored, expectedRewardPerShare, "Reward per share calculation mismatch");
        assertEq(totalRewards, 10e18, "Total rewards should be 10 WBERA");
        assertEq(vault.previewRewards(alice, address(wbera)), expectedAliceReward, "First reward preview mismatch");
        assertEq(vault.previewRewards(alice, address(wbera)), 10e18, "First reward should be 10 WBERA");

        // Bob deposits 100 WBERA
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // Second reward: 20 WBERA
        vm.prank(admin);
        wbera.transfer(address(vault), 20e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera), 20e18);

        // Manual calculation for second reward
        uint256 secondRewardPerShare = (20e18 * 1e36) / 200e18; // Should be 0.1e36

        // Alice's total expected: First reward (10) + (100 shares * 0.1 from second reward)
        uint256 expectedAliceTotalReward = 10e18 + ((100e18 * secondRewardPerShare) / 1e36);
        // Bob's expected: (100 shares * 0.1 from second reward only)
        uint256 expectedBobReward = (100e18 * secondRewardPerShare) / 1e36;

        assertEq(vault.previewRewards(alice, address(wbera)), expectedAliceTotalReward, "Alice's second reward preview mismatch");
        assertEq(vault.previewRewards(alice, address(wbera)), 20e18, "Alice should have 20 WBERA total rewards");
        assertEq(vault.previewRewards(bob, address(wbera)), expectedBobReward, "Bob's reward preview mismatch");
        assertEq(vault.previewRewards(bob, address(wbera)), 10e18, "Bob should have 10 WBERA rewards");

        // Verify reward tracking after Alice claims
        vm.prank(alice);
        vault.claimRewards(address(alice));
        assertEq(vault.previewRewards(alice, address(wbera)), 0, "Alice should have 0 rewards after claim");
        assertEq(vault.previewRewards(bob, address(wbera)), 10e18, "Bob's rewards unchanged after Alice's claim");
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
        vm.prank(admin);
        wbera.transfer(address(vault), 10e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera), 10e18);

        // Check Alice's claimable rewards
        assertEq(vault.previewRewards(alice, address(wbera)), 10e18, "All rewards should go to Alice");
    }

    function test_MultipleDepositorsRewardDistribution() public {
        vm.prank(admin);
        vault.unpause();

        // Alice deposits 100 WBERA
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Admin adds 10 WBERA reward
        vm.prank(admin);
        wbera.transfer(address(vault), 10e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),10e18);

        // Bob deposits 100 WBERA
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // Admin adds another 10 WBERA reward
        vm.prank(admin);
        wbera.transfer(address(vault), 10e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),10e18);

        // Check rewards
        assertEq(vault.previewRewards(alice, address(wbera)), 15e18, "Alice should have first reward + half of second");
        assertEq(vault.previewRewards(bob, address(wbera)), 5e18, "Bob should have half of second reward only");
    }

    function test_ClaimRewards() public {
        vm.prank(admin);
        vault.unpause();

        // Alice deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Add reward
        vm.prank(admin);
        wbera.transfer(address(vault), 10e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),10e18);

        // Record balance before claim
        uint256 balanceBefore = wbera.balanceOf(alice);

        // Claim rewards
        vm.prank(alice);
        vault.claimRewards(address(alice));

        // Verify reward received
        assertEq(wbera.balanceOf(alice) - balanceBefore, 10e18, "Should receive full reward");
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

    function test_WithdrawWithRewards() public {
        vm.prank(admin);
        vault.unpause();

        // Alice deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Add reward
        vm.prank(admin);
        wbera.transfer(address(vault), 10e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),10e18);

        // Record balance before withdrawal
        uint256 balanceBefore = wbera.balanceOf(alice);

        // Withdraw half
        vm.startPrank(alice);
        vault.withdraw(50e18, alice, alice);
        vault.claimRewards(address(alice));
        vm.stopPrank();

        // Verify
        uint256 totalReceived = wbera.balanceOf(alice) - balanceBefore;
        assertEq(totalReceived, 60e18, "Should receive withdrawal + rewards");
        assertEq(vault.balanceOf(alice), 50e18, "Should have half shares left");
    }

    function test_RedeemWithRewards() public {
        vm.prank(admin);
        vault.unpause();

        // Alice deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Add reward
        vm.prank(admin);
        wbera.transfer(address(vault), 10e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),10e18);

        // Record balance before redeem
        uint256 balanceBefore = wbera.balanceOf(alice);

        // Redeem half shares
        vm.startPrank(alice);
        vault.redeem(50e18, alice, alice);
        vault.claimRewards(address(alice));
        vm.stopPrank();

        // Verify
        uint256 totalReceived = wbera.balanceOf(alice) - balanceBefore;
        assertEq(totalReceived, 60e18, "Should receive redemption + rewards");
        assertEq(vault.balanceOf(alice), 50e18, "Should have half shares left");
    }

    function test_CannotWithdrawWhenPaused() public {
        vm.prank(admin);
        vault.unpause();

        // Alice deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Pause vault
        vm.prank(admin);
        vault.pause();

        // Try to withdraw
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(50e18, alice, alice);
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
        vm.prank(admin);
        wbera.transfer(address(vault), 10e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),10e18);

        // Alice claims
        vm.prank(alice);
        vault.claimRewards(address(alice));

        // Second reward cycle
        vm.prank(admin);
        wbera.transfer(address(vault), 10e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),10e18);

        // Verify rewards
        assertEq(vault.previewRewards(alice, address(wbera)), 5e18, "Alice should have half of second reward");
        assertEq(vault.previewRewards(bob, address(wbera)), 10e18, "Bob should have unclaimed rewards from both cycles");
    }

    function test_RewardDistributionWithPartialClaims() public {
        // Alice deposits 100
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // First reward: 10 WBERA
        vm.prank(admin);
        wbera.transfer(address(vault), 10e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),10e18);

        // Bob deposits 100
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // Alice claims her first reward
        vm.prank(alice);
        vault.claimRewards(address(alice));

        // Second reward: 20 WBERA (split between Alice and Bob)
        vm.prank(admin);
        wbera.transfer(address(vault), 20e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),20e18);

        // Charlie deposits 200
        vm.prank(charlie);
        vault.deposit(200e18, charlie);

        // Third reward: 30 WBERA (split between all three)
        vm.prank(admin);
        wbera.transfer(address(vault), 40e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),40e18);

        // Verify final reward states
        assertEq(vault.previewRewards(alice, address(wbera)), 20e18, "Alice should have share of second and third rewards");
        assertEq(vault.previewRewards(bob, address(wbera)), 20e18, "Bob should have all unclaimed rewards");
        assertEq(vault.previewRewards(charlie, address(wbera)), 20e18, "Charlie should have share of third reward only");
    }

    function test_SequentialDepositsAndRewards() public {
        // Alice deposits 100
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Reward 1: 10 WBERA
        vm.prank(admin);
        wbera.transfer(address(vault), 10e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),10e18);

        // Bob deposits 200
        vm.prank(bob);
        vault.deposit(200e18, bob);

        // Reward 2: 30 WBERA
        vm.prank(admin);
        wbera.transfer(address(vault), 30e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),30e18);

        // Alice claims
        vm.prank(alice);
        vault.claimRewards(address(alice));

        // Charlie deposits 300
        vm.prank(charlie);
        vault.deposit(300e18, charlie);

        // Reward 3: 60 WBERA
        vm.prank(admin);
        wbera.transfer(address(vault), 60e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),60e18);

        // Verify complex reward distribution
        assertEq(vault.previewRewards(alice, address(wbera)), 10e18, "Alice's new rewards after claim");
        assertEq(vault.previewRewards(bob, address(wbera)), 40e18, "Bob's accumulated rewards");
        assertEq(vault.previewRewards(charlie, address(wbera)), 30e18, "Charlie's portion of last reward");
    }

    function test_WithdrawAfterMultipleRewardCycles() public {
        // Alice and Bob deposit 100 each
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // First reward cycle
        vm.prank(admin);
        wbera.transfer(address(vault), 20e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),20e18);

        // Alice claims but Bob doesn't
        vm.prank(alice);
        vault.claimRewards(address(alice));

        // Second reward cycle
        vm.prank(admin);
        wbera.transfer(address(vault), 10e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),10e18);

        // Enable withdrawals
        vm.prank(admin);
        vault.unpause();

        // Alice withdraws half
        vm.startPrank(alice);
        vault.claimRewards(address(alice));
        vault.withdraw(50e18, alice, alice);
        vm.stopPrank();

        // Third reward cycle
        vm.prank(admin);
        wbera.transfer(address(vault), 30e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),30e18);

        // Verify final states
        assertEq(vault.balanceOf(alice), 50e18, "Alice's remaining shares");
        assertEq(vault.balanceOf(bob), 100e18, "Bob's unchanged shares");
        assertEq(vault.previewRewards(alice, address(wbera)), 10e18, "Alice's new rewards");
        assertEq(vault.previewRewards(bob, address(wbera)), 35e18, "Bob's total unclaimed rewards");
    }

    function test_notifyRewardAmount() public {
        // Try to notify reward with no deposits
        vm.prank(admin);
        wbera.transfer(address(vault), 10e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),10e18);

        // Alice deposits after failed reward
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Verify no rewards from before deposit
        assertEq(vault.previewRewards(alice, address(wbera)), 0, "Should have no rewards from before deposit");

        // New reward should work
        vm.prank(admin);
        wbera.transfer(address(vault), 10e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),10e18);
        assertEq(vault.previewRewards(alice, address(wbera)), 10e18, "Should receive new rewards");
    }

    function test_ComplexWithdrawScenario() public {
        // Initial deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(200e18, bob);

        // First reward
        vm.prank(admin);
        wbera.transfer(address(vault), 30e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),30e18);

        // bob balance before claim
        uint256 bobBalanceBefore = wbera.balanceOf(bob);

        // Bob claims
        vm.prank(bob);
        vault.claimRewards(address(bob));

        // verify bob received rewards
        assertEq(wbera.balanceOf(bob) - bobBalanceBefore, 20e18, "Bob should have received 20 WBERA");

        // Charlie deposits
        vm.prank(charlie);
        vault.deposit(300e18, charlie);

        // Second reward
        vm.prank(admin);
        wbera.transfer(address(vault), 60e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),60e18);

        // Enable withdrawals
        
        vm.prank(admin);
        vault.unpause();

        // Record balances before withdrawals
        uint256 aliceBalanceBefore = wbera.balanceOf(alice);
        bobBalanceBefore = wbera.balanceOf(bob);

        // Alice and Bob withdraw half
        vm.startPrank(alice);
        vault.withdraw(50e18, alice, alice);
        vault.claimRewards(address(alice));
        vm.stopPrank();

        vm.startPrank(bob);
        vault.claimRewards(address(bob));
        vault.withdraw(100e18, bob, bob);
        vm.stopPrank();

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
        vm.prank(admin);
        wbera.transfer(address(vault), 90e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),90e18);

        // Verify final reward state
        assertEq(vault.previewRewards(alice, address(wbera)), 10e18, "Alice's new rewards");
        assertEq(vault.previewRewards(bob, address(wbera)), 20e18, "Bob's new rewards");
        assertEq(vault.previewRewards(charlie, address(wbera)), 90e18, "Charlie's total rewards");
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
        vm.prank(admin);
        wbera.transfer(address(vault), 30e18);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),30e18);

        // Verify rewards still work correctly
        assertEq(vault.previewRewards(alice, address(wbera)), 15e18, "Alice's reward share");
        assertEq(vault.previewRewards(bob, address(wbera)), 15e18, "Bob's reward share");
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

        // Try to set max deposits below current (now using admin)
        vm.prank(admin);
        vm.expectRevert(fatBERA.InvalidMaxDeposits.selector);
        vault.setMaxDeposits(400_000 ether);

        // Update max deposits
        vm.prank(admin);
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
        vm.prank(admin);
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
        vm.prank(admin);
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
        depositAmount = bound(depositAmount, 1 ether / 10000, maxDeposits);
        // Bound reward amount between 1 and maxDeposits (reasonable range for rewards)
        rewardAmount = bound(rewardAmount, 1 ether / 1000, maxDeposits);

        // Initial deposit
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Add reward
        vm.prank(admin);
        wbera.transfer(address(vault), rewardAmount);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),rewardAmount);

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

    function testFuzz_MultiUserRewardDistribution(
        uint256 aliceDeposit,
        uint256 bobDeposit,
        uint256 rewardAmount
    ) public {
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
        vm.prank(admin);
        wbera.transfer(address(vault), rewardAmount);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera),rewardAmount);

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
            aliceRewardsReceived,
            expectedAliceReward,
            1e11,
            "Alice rewards should be approximately equal to expected"
        );
        assertApproxEqRel(
            bobRewardsReceived,
            expectedBobReward,
            1e11,
            "Bob rewards should be approximately equal to expected"
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
        vm.startPrank(admin);
        rewardToken1.transfer(address(vault), 20e18);
        vault.notifyRewardAmount(address(rewardToken1), 20e18);
        vm.stopPrank();

        // Add second reward token
        vm.startPrank(admin);
        rewardToken2.transfer(address(vault), 40e18);
        vault.notifyRewardAmount(address(rewardToken2), 40e18);
        vm.stopPrank();

        // Verify reward preview for both tokens
        assertEq(vault.previewRewards(alice, address(rewardToken1)), 10e18, "Alice's RWD1 rewards incorrect");
        assertEq(vault.previewRewards(alice, address(rewardToken2)), 20e18, "Alice's RWD2 rewards incorrect");
        assertEq(vault.previewRewards(bob, address(rewardToken1)), 10e18, "Bob's RWD1 rewards incorrect");
        assertEq(vault.previewRewards(bob, address(rewardToken2)), 20e18, "Bob's RWD2 rewards incorrect");

        // Claim rewards and verify balances
        uint256 aliceRwd1Before = rewardToken1.balanceOf(alice);
        uint256 aliceRwd2Before = rewardToken2.balanceOf(alice);

        vm.prank(alice);
        vault.claimRewards(address(alice));

        assertEq(rewardToken1.balanceOf(alice) - aliceRwd1Before, 10e18, "Alice's RWD1 claim incorrect");
        assertEq(rewardToken2.balanceOf(alice) - aliceRwd2Before, 20e18, "Alice's RWD2 claim incorrect");
    }

    function test_MultiTokenRewardsWithPartialClaims() public {
        // Initial deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(100e18, bob);

        // First reward cycle with both tokens
        vm.startPrank(admin);
        rewardToken1.transfer(address(vault), 20e18);
        rewardToken2.transfer(address(vault), 40e18);
        vault.notifyRewardAmount(address(rewardToken1), 20e18);
        vault.notifyRewardAmount(address(rewardToken2), 40e18);
        vm.stopPrank();

        // Alice claims only rewardToken1
        vm.prank(alice);
        vault.claimRewards(address(rewardToken1), address(alice));

        // Second reward cycle
        vm.startPrank(admin);
        rewardToken1.transfer(address(vault), 30e18);
        rewardToken2.transfer(address(vault), 60e18);
        vault.notifyRewardAmount(address(rewardToken1), 30e18);
        vault.notifyRewardAmount(address(rewardToken2), 60e18);
        vm.stopPrank();

        // Verify rewards state
        assertEq(vault.previewRewards(alice, address(rewardToken1)), 15e18, "Alice's RWD1 rewards after partial claim");
        assertEq(vault.previewRewards(alice, address(rewardToken2)), 50e18, "Alice's RWD2 rewards accumulated");
        assertEq(vault.previewRewards(bob, address(rewardToken1)), 25e18, "Bob's RWD1 total rewards");
        assertEq(vault.previewRewards(bob, address(rewardToken2)), 50e18, "Bob's RWD2 total rewards");
    }

    function test_MultiTokenRewardsWithDepositsAndWithdrawals() public {
        vm.prank(admin);
        vault.unpause();

        // Initial deposits
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(bob);
        vault.deposit(200e18, bob);

        // First reward cycle
        vm.startPrank(admin);
        rewardToken1.transfer(address(vault), 30e18);
        rewardToken2.transfer(address(vault), 60e18);
        vault.notifyRewardAmount(address(rewardToken1), 30e18);
        vault.notifyRewardAmount(address(rewardToken2), 60e18);
        vm.stopPrank();

        // Bob withdraws half
        vm.prank(bob);
        vault.withdraw(100e18, bob, bob);

        // Second reward cycle
        vm.startPrank(admin);
        rewardToken1.transfer(address(vault), 40e18);
        rewardToken2.transfer(address(vault), 80e18);
        vault.notifyRewardAmount(address(rewardToken1), 40e18);
        vault.notifyRewardAmount(address(rewardToken2), 80e18);
        vm.stopPrank();

        // Verify final reward states
        assertEq(vault.previewRewards(alice, address(rewardToken1)), 30e18, "Alice's final RWD1 rewards");
        assertEq(vault.previewRewards(alice, address(rewardToken2)), 60e18, "Alice's final RWD2 rewards");
        assertEq(vault.previewRewards(bob, address(rewardToken1)), 40e18, "Bob's final RWD1 rewards");
        assertEq(vault.previewRewards(bob, address(rewardToken2)), 80e18, "Bob's final RWD2 rewards");
    }

    function test_GetRewardTokensList() public {
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

        // Add rewards
        vm.startPrank(admin);
        rewardToken1.transfer(address(vault), reward1Amount);
        rewardToken2.transfer(address(vault), reward2Amount);
        vault.notifyRewardAmount(address(rewardToken1), reward1Amount);
        vault.notifyRewardAmount(address(rewardToken2), reward2Amount);
        vm.stopPrank();

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
            rewardToken1.balanceOf(alice) - aliceReward1Before,
            expectedAliceReward1,
            1e11,
            "Alice reward1 mismatch"
        );
        assertApproxEqRel(
            rewardToken2.balanceOf(alice) - aliceReward2Before,
            expectedAliceReward2,
            1e11,
            "Alice reward2 mismatch"
        );
        assertApproxEqRel(
            rewardToken1.balanceOf(bob) - bobReward1Before,
            expectedBobReward1,
            1e11,
            "Bob reward1 mismatch"
        );
        assertApproxEqRel(
            rewardToken2.balanceOf(bob) - bobReward2Before,
            expectedBobReward2,
            1e11,
            "Bob reward2 mismatch"
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

        assertEq(
            vault.depositPrincipal(),
            nativeDeposit + erc20Deposit,
            "Should track both deposit types"
        );
        assertEq(
            vault.balanceOf(alice),
            nativeDeposit + erc20Deposit,
            "Shares should be cumulative"
        );
    }

    function test_NativeDepositWithRewards() public {
        uint256 depositAmount = 10 ether;
        
        vm.prank(alice);
        vault.depositNative{value: depositAmount}(alice);

        // Add rewards
        vm.prank(admin);
        wbera.transfer(address(vault), 10 ether);
        vm.prank(admin);
        vault.notifyRewardAmount(address(wbera), 10 ether);

        // Verify rewards
        assertEq(
            vault.previewRewards(alice, address(wbera)),
            10 ether,
            "Should accrue rewards correctly"
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

    function testFuzz_MixedDepositTypes(
        uint256 nativeAmount,
        uint256 erc20Amount
    ) public {
        nativeAmount = bound(nativeAmount, 1 wei, maxDeposits / 2);
        erc20Amount = bound(erc20Amount, 1 wei, maxDeposits - nativeAmount);
        vm.deal(alice, nativeAmount);

        // Native deposit
        vm.prank(alice);
        vault.depositNative{value: nativeAmount}(alice);

        // ERC20 deposit
        vm.prank(alice);
        vault.deposit(erc20Amount, alice);

        assertEq(
            vault.depositPrincipal(),
            nativeAmount + erc20Amount,
            "Total principal should sum both types"
        );
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
        console2.log("newNotifier", newNotifier);

        bytes32 role = vault.REWARD_NOTIFIER_ROLE();

        // Test that non-admin cannot grant roles
        vm.startPrank(newNotifier);
        vm.expectRevert();
        vault.grantRole(role, alice);
        vm.stopPrank();
    }
}
