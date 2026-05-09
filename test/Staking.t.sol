// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStaking} from "src/interfaces/IStaking.sol";
import {Staking} from "src/Staking/Staking.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {BaseTest} from "test/helpers/BaseTest.sol";

contract FeeOnTransferERC20 is ERC20, Ownable {
    uint256 internal constant BPS = 10_000;

    uint8 private immutable _decimals;
    uint256 public immutable feeBps;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 feeBps_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        _decimals = decimals_;
        feeBps = feeBps_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _feeTransfer(_msgSender(), to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);
        _feeTransfer(from, to, amount);
        return true;
    }

    function _feeTransfer(address from, address to, uint256 amount) internal {
        uint256 fee = amount * feeBps / BPS;
        uint256 received = amount - fee;
        _transfer(from, to, received);
        if (fee != 0) _transfer(from, address(this), fee);
    }
}

contract ReentrantERC20 is ERC20, Ownable {
    enum HookType {
        None,
        Transfer,
        TransferFrom
    }

    uint8 private immutable _decimals;
    HookType public hookType;
    address public target;
    bytes public payload;
    bool private entered;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) Ownable(msg.sender) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function setHook(HookType hookType_, address target_, bytes calldata payload_) external onlyOwner {
        hookType = hookType_;
        target = target_;
        payload = payload_;
    }

    function clearHook() external onlyOwner {
        hookType = HookType.None;
        target = address(0);
        delete payload;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        _maybeReenter(HookType.Transfer);
        return success;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        _maybeReenter(HookType.TransferFrom);
        return success;
    }

    function _maybeReenter(HookType expectedHook) internal {
        if (entered || hookType != expectedHook || target == address(0)) return;

        entered = true;
        (bool success, bytes memory reason) = target.call(payload);
        entered = false;

        if (!success) {
            assembly {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}

contract StakingTest is BaseTest {
    event Staked(
        address indexed user,
        uint256 indexed stakeId,
        uint128 amount,
        uint8 tierId,
        uint64 unlockTime,
        uint128 boostedAmount
    );
    event Unstaked(address indexed user, uint256 indexed stakeId, uint128 amount);
    event EmergencyUnstaked(address indexed user, uint256 indexed stakeId, uint128 amountReturned, uint128 penalty);
    event RewardClaimed(address indexed user, address indexed rewardToken, uint256 amount);
    event Compounded(address indexed user, uint8 tierId, uint256 amount, uint256 newStakeId);
    event RewardNotified(address indexed rewardToken, uint256 amount, uint64 periodFinish);
    event RewardTokenAdded(address indexed rewardToken, uint64 duration);
    event LockTierSet(uint8 indexed tierId, uint64 duration, uint32 multiplierBps, bool enabled);
    event EarlyUnstakePenaltyUpdated(uint256 bps);
    event PenaltyQueued(address indexed rewardToken, uint256 amount);
    event PenaltyFlushed(address indexed rewardToken, uint256 amount, uint64 newPeriodFinish);
    event PrimaryRewardTokenSet(address indexed rewardToken);
    event RecoveredToken(address indexed token, uint256 amount);
    event Paused(address account);
    event Unpaused(address account);

    uint64 internal constant REWARD_DURATION = 30 days;
    uint128 internal constant DEFAULT_STAKE = 100 ether;
    uint128 internal constant LARGE_STAKE = 1_000 ether;
    uint256 internal constant DUST_TOLERANCE = 1_000;
    uint256 internal constant CLAIM_GAS_HISTORY_DELTA_MAX = 20_000;

    MockERC20 internal stakingToken;
    MockERC20 internal bonusToken;
    Staking internal staking;
    uint8 internal tier30;
    uint8 internal tier60;
    uint8 internal tier90;

    function setUp() public override {
        super.setUp();

        stakingToken = deployMockToken("STK", 18);
        bonusToken = deployMockToken("BON", 18);

        vm.startPrank(owner);
        staking = new Staking(IERC20(address(stakingToken)), address(stakingToken), 1_000);
        tier30 = staking.setLockTier(30 days, 10_000);
        tier60 = staking.setLockTier(60 days, 20_000);
        tier90 = staking.setLockTier(90 days, 30_000);
        staking.addRewardToken(address(bonusToken), REWARD_DURATION);

        stakingToken.mint(owner, type(uint128).max);
        bonusToken.mint(owner, type(uint128).max);
        stakingToken.approve(address(staking), type(uint256).max);
        bonusToken.approve(address(staking), type(uint256).max);
        vm.stopPrank();

        mintAndApprove(stakingToken, alice, address(staking), type(uint120).max);
        mintAndApprove(stakingToken, bob, address(staking), type(uint120).max);
        mintAndApprove(stakingToken, charlie, address(staking), type(uint120).max);
    }

    function testSingleStakerHappyPathStakeUnstakeAndClaim() public {
        uint256 stakeId = _stake(alice, DEFAULT_STAKE, tier30);

        _notify(address(stakingToken), 300 ether);

        warp(30 days);

        uint256 accrued = staking.earned(alice, address(stakingToken));
        assertApproxEqAbs(accrued, 300 ether, DUST_TOLERANCE);

        vm.expectEmit(true, true, false, true);
        emit Unstaked(alice, stakeId, DEFAULT_STAKE);

        vm.prank(alice);
        staking.unstake(stakeId);

        vm.expectEmit(true, true, false, true);
        emit RewardClaimed(alice, address(stakingToken), accrued);

        vm.prank(alice);
        staking.claim(address(stakingToken));

        assertEq(stakingToken.balanceOf(alice), type(uint120).max + accrued);
        assertEq(staking.totalRawSupply(), 0);
        assertEq(staking.totalBoostedSupply(), 0);
    }

    function testTwoStakersDifferentTiersSplitRewardsByBoost() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        _stake(bob, DEFAULT_STAKE, tier60);
        _notify(address(stakingToken), 90 ether);

        warp(30 days);

        uint256 aliceEarned = staking.earned(alice, address(stakingToken));
        uint256 bobEarned = staking.earned(bob, address(stakingToken));

        assertApproxEqAbs(aliceEarned, 30 ether, DUST_TOLERANCE);
        assertApproxEqAbs(bobEarned, 60 ether, DUST_TOLERANCE);
    }

    function testTwoRewardTokensAccrueIndependently() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        _notify(address(stakingToken), 300 ether);
        _notify(address(bonusToken), 600 ether);

        warp(15 days);

        uint256 primaryAccrued = staking.earned(alice, address(stakingToken));
        uint256 bonusAccrued = staking.earned(alice, address(bonusToken));

        vm.prank(alice);
        staking.claim();

        assertEq(stakingToken.balanceOf(alice), type(uint120).max - DEFAULT_STAKE + primaryAccrued);
        assertEq(bonusToken.balanceOf(alice), bonusAccrued);
    }

    function testCompoundCreatesNewStakeAndZerosPrimaryReward() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        _notify(address(stakingToken), 300 ether);

        warp(15 days);

        uint256 accrued = staking.earned(alice, address(stakingToken));

        vm.expectEmit(true, false, false, true);
        emit Compounded(alice, tier60, accrued, 1);

        vm.prank(alice);
        uint256 newStakeId = staking.compound(tier60);

        assertEq(newStakeId, 1);
        assertEq(staking.rewards(alice, address(stakingToken)), 0);

        IStaking.Stake memory newStake = staking.getUserStake(alice, newStakeId);
        assertEq(newStake.amount, accrued);
        assertEq(newStake.boostedAmount, accrued * 2);
        assertEq(staking.totalRawSupply(), DEFAULT_STAKE + accrued);
        assertEq(staking.totalBoostedSupply(), DEFAULT_STAKE + (accrued * 2));
    }

    function testEmergencyUnstakeQueuesPenaltyAndReturnsNetAmount() public {
        uint256 stakeId = _stake(alice, DEFAULT_STAKE, tier30);

        vm.expectEmit(true, true, false, true);
        emit PenaltyQueued(address(stakingToken), 10 ether);
        vm.expectEmit(true, true, false, true);
        emit EmergencyUnstaked(alice, stakeId, 90 ether, 10 ether);

        vm.prank(alice);
        staking.emergencyUnstake(stakeId);

        (, uint64 periodFinish,,,,, uint256 queuedPenalty) = staking.rewardData(address(stakingToken));
        assertEq(periodFinish, 0);
        assertEq(queuedPenalty, 10 ether);
        assertEq(stakingToken.balanceOf(alice), type(uint120).max - 10 ether);
    }

    function test_flushPenalty_revertsWhenNoPenaltyQueued() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        _notify(address(stakingToken), 1 ether);

        vm.expectRevert(IStaking.NoQueuedPenalty.selector);
        staking.flushPenalty();
    }

    function test_flushPenalty_doesNotExtendActiveStream() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        _notify(address(stakingToken), 15 ether);

        (, uint64 periodFinishBefore,,,,,) = staking.rewardData(address(stakingToken));
        warp(10 days);

        vm.prank(alice);
        staking.emergencyUnstake(0);

        (,,, uint128 oldRewardRate,, uint256 rewardPerTokenStored, uint256 queuedPenalty) =
            staking.rewardData(address(stakingToken));
        assertEq(queuedPenalty, 10 ether);
        assertGt(rewardPerTokenStored, 0);
        staking.flushPenalty();

        (, uint64 newPeriodFinish,, uint128 newRewardRate,,, uint256 postQueuedPenalty) =
            staking.rewardData(address(stakingToken));

        assertEq(postQueuedPenalty, 0);
        assertEq(newPeriodFinish, periodFinishBefore);
        assertGt(newRewardRate, oldRewardRate);

        warp(periodFinishBefore - block.timestamp);

        uint256 aliceEarned = staking.earned(alice, address(stakingToken));

        assertApproxEqAbs(aliceEarned, 5 ether, DUST_TOLERANCE);

        vm.prank(alice);
        staking.claim(address(stakingToken));

        assertEq(stakingToken.balanceOf(alice), type(uint120).max - 10 ether + aliceEarned);
    }

    function testEmergencyUnstakeDistributesPenaltyImmediatelyWhenEligible() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        _stake(bob, DEFAULT_STAKE, tier30);

        vm.expectEmit(true, true, false, true);
        emit PenaltyFlushed(address(stakingToken), 10 ether, 0);

        vm.prank(bob);
        staking.emergencyUnstake(0);

        (
            ,
            uint64 periodFinish,
            uint64 lastUpdateTime,
            uint128 rewardRate,
            ,
            uint256 rewardPerTokenStored,
            uint256 queuedPenalty
        ) = staking.rewardData(address(stakingToken));

        assertEq(periodFinish, 0);
        assertEq(lastUpdateTime, 0);
        assertEq(rewardRate, 0);
        assertGt(rewardPerTokenStored, 0);
        assertEq(queuedPenalty, 0);

        assertApproxEqAbs(staking.earned(alice, address(stakingToken)), 10 ether, DUST_TOLERANCE);
        assertEq(staking.earned(bob, address(stakingToken)), 0);
    }

    function testEmergencyPenaltyJustInTimeStakerReceivesDocumentedShare() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        _stake(bob, DEFAULT_STAKE, tier30);
        _stake(charlie, DEFAULT_STAKE, tier30);

        vm.prank(charlie);
        staking.emergencyUnstake(0);

        (,,,,,, uint256 queuedPenalty) = staking.rewardData(address(stakingToken));
        assertEq(queuedPenalty, 0);

        // Option A intentionally accepts the R2 JIT limitation: current non-penalized
        // stakers, including a just-in-time stake, share the immediate penalty bump.
        assertApproxEqAbs(staking.earned(alice, address(stakingToken)), 5 ether, DUST_TOLERANCE);
        assertApproxEqAbs(staking.earned(bob, address(stakingToken)), 5 ether, DUST_TOLERANCE);
        assertEq(staking.earned(charlie, address(stakingToken)), 0);
    }

    function testEmergencyPenaltyStillRewardsOlderIncumbent() public {
        _stake(bob, DEFAULT_STAKE, tier30);
        _stake(alice, DEFAULT_STAKE, tier30);

        vm.prank(alice);
        staking.emergencyUnstake(0);

        (,,,,,, uint256 queuedPenalty) = staking.rewardData(address(stakingToken));
        assertEq(queuedPenalty, 0);

        assertApproxEqAbs(staking.earned(bob, address(stakingToken)), 10 ether, DUST_TOLERANCE);
    }

    function testEmergencyPenaltyRewardsOlderIncumbentAfterLaterStakeExits() public {
        vm.prank(owner);
        uint8 unlockedTier = staking.setLockTier(0, 10_000);

        _stake(alice, DEFAULT_STAKE, tier30);
        _stake(bob, DEFAULT_STAKE, tier30);
        _stake(charlie, DEFAULT_STAKE, unlockedTier);

        vm.prank(charlie);
        staking.unstake(0);

        vm.prank(bob);
        staking.emergencyUnstake(0);

        (,,,,,, uint256 queuedPenalty) = staking.rewardData(address(stakingToken));
        assertEq(queuedPenalty, 0);

        assertApproxEqAbs(staking.earned(alice, address(stakingToken)), 10 ether, DUST_TOLERANCE);
        assertEq(staking.earned(bob, address(stakingToken)), 0);
        assertEq(staking.earned(charlie, address(stakingToken)), 0);
    }

    function testEmergencyPenaltyIgnoresWithdrawnStakeHistory() public {
        vm.prank(owner);
        uint8 unlockedTier = staking.setLockTier(0, 10_000);

        _stake(alice, DEFAULT_STAKE, tier30);
        _stake(bob, DEFAULT_STAKE, tier30);
        _stake(charlie, uint128(staking.MIN_STAKE_AMOUNT()), unlockedTier);

        vm.prank(charlie);
        staking.unstake(0);

        vm.prank(bob);
        staking.emergencyUnstake(0);

        _stake(charlie, DEFAULT_STAKE * 9, tier30);

        assertApproxEqAbs(staking.earned(alice, address(stakingToken)), 10 ether, DUST_TOLERANCE);
        assertEq(staking.earned(charlie, address(stakingToken)), 0);
    }

    function testEmergencyPenaltyDistributesToAllCurrentNonPenalizedStakers() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        _stake(bob, DEFAULT_STAKE, tier30);
        _stake(charlie, DEFAULT_STAKE, tier30);

        vm.prank(bob);
        staking.emergencyUnstake(0);

        (,,,,,, uint256 queuedPenalty) = staking.rewardData(address(stakingToken));
        assertEq(queuedPenalty, 0);
        assertApproxEqAbs(staking.earned(alice, address(stakingToken)), 5 ether, DUST_TOLERANCE);
        assertApproxEqAbs(staking.earned(charlie, address(stakingToken)), 5 ether, DUST_TOLERANCE);
        assertEq(staking.earned(bob, address(stakingToken)), 0);
    }

    function testEmergencyPenaltyDistributesToCurrentRestakedUser() public {
        vm.prank(owner);
        uint8 unlockedTier = staking.setLockTier(0, 10_000);

        _stake(alice, DEFAULT_STAKE, tier30);
        _stake(bob, DEFAULT_STAKE, tier30);
        _stake(charlie, DEFAULT_STAKE, unlockedTier);

        vm.prank(charlie);
        staking.unstake(0);

        _stake(charlie, DEFAULT_STAKE, tier30);

        vm.prank(bob);
        staking.emergencyUnstake(0);

        (,,,,,, uint256 queuedPenalty) = staking.rewardData(address(stakingToken));
        assertEq(queuedPenalty, 0);
        assertApproxEqAbs(staking.earned(alice, address(stakingToken)), 5 ether, DUST_TOLERANCE);
        assertApproxEqAbs(staking.earned(charlie, address(stakingToken)), 5 ether, DUST_TOLERANCE);
        assertEq(staking.earned(bob, address(stakingToken)), 0);
    }

    function testEmergencyPenaltyCannotBeCapturedByLateStaker() public {
        _stake(bob, DEFAULT_STAKE, tier30);
        _stake(alice, DEFAULT_STAKE, tier30);

        vm.prank(alice);
        staking.emergencyUnstake(0);

        _stake(charlie, DEFAULT_STAKE * 9, tier30);

        assertApproxEqAbs(staking.earned(bob, address(stakingToken)), 10 ether, DUST_TOLERANCE);
        assertEq(staking.earned(charlie, address(stakingToken)), 0);
    }

    function testAdminPrimaryRewardUsesFullSupplyAfterPriorPenaltyFlush() public {
        _stake(alice, DEFAULT_STAKE, tier30);

        vm.prank(alice);
        staking.emergencyUnstake(0);

        _stake(bob, DEFAULT_STAKE, tier30);
        staking.flushPenalty();

        warp(REWARD_DURATION);
        _stake(charlie, DEFAULT_STAKE, tier30);
        _notify(address(stakingToken), 30 ether);

        warp(12 hours);

        assertApproxEqAbs(staking.earned(bob, address(stakingToken)), 10.25 ether, DUST_TOLERANCE);
        assertApproxEqAbs(staking.earned(charlie, address(stakingToken)), 0.25 ether, DUST_TOLERANCE);
    }

    function test_flushPenalty_revertsBelowMin() public {
        uint128 amount = uint128(staking.MIN_STAKE_AMOUNT());
        _stake(alice, amount, tier30);

        vm.prank(alice);
        staking.emergencyUnstake(0);

        (,,,,,, uint256 queuedPenalty) = staking.rewardData(address(stakingToken));
        uint256 minimumFlushPenalty = staking.MIN_FLUSH_PENALTY_AMOUNT();

        assertLt(queuedPenalty, minimumFlushPenalty);

        vm.expectRevert(
            abi.encodeWithSelector(IStaking.PenaltyAmountTooLow.selector, queuedPenalty, minimumFlushPenalty)
        );
        staking.flushPenalty();

        (,,,,,, uint256 queuedPenaltyAfter) = staking.rewardData(address(stakingToken));
        assertEq(queuedPenaltyAfter, queuedPenalty);
    }

    function testStakeBeforeRewardNotificationDoesNotEarnRetroactively() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        warp(5 days);
        assertEq(staking.earned(alice, address(stakingToken)), 0);

        _notify(address(stakingToken), 30 ether);
        warp(10 days);

        assertApproxEqAbs(staking.earned(alice, address(stakingToken)), 10 ether, DUST_TOLERANCE);
    }

    function testRewardAccumulatorCarriesRemainderThroughMinStakeSpam() public {
        uint128 incumbentStake = 10 ether;
        uint256 streamAmount = 2_159_460;
        uint256 spamBlocks = 25;
        uint128 minStake = uint128(staking.MIN_STAKE_AMOUNT());
        address[] memory attackers = new address[](spamBlocks);

        _stake(alice, incumbentStake, tier30);
        _notify(address(stakingToken), streamAmount);

        for (uint256 i; i < spamBlocks; ++i) {
            advanceBlocks(1);

            address attacker = _roundingAttacker(i);
            attackers[i] = attacker;
            mintAndApprove(stakingToken, attacker, address(staking), minStake);

            vm.prank(attacker);
            staking.stake(minStake, tier30);
        }

        warp(REWARD_DURATION - (spamBlocks * SECONDS_PER_BLOCK));

        uint256 totalEarned = staking.earned(alice, address(stakingToken));
        for (uint256 i; i < spamBlocks; ++i) {
            totalEarned += staking.earned(attackers[i], address(stakingToken));
        }

        assertApproxEqAbs(totalEarned, streamAmount, 10);
    }

    function testRewardAccumulatorDistributesLowRateStreamWithoutSpam() public {
        uint128 incumbentStake = 10 ether;
        uint256 streamAmount = 2_159_460;

        _stake(alice, incumbentStake, tier30);
        _notify(address(stakingToken), streamAmount);

        warp(REWARD_DURATION);

        assertApproxEqAbs(staking.earned(alice, address(stakingToken)), streamAmount, 1);
    }

    function testRewardAccumulatorDoesNotLeakPriorCohortResidualToDustStaker() public {
        uint128 incumbentStake = type(uint128).max;
        uint128 dustStake = uint128(staking.MIN_STAKE_AMOUNT());
        uint256 streamAmount = 1_000 ether;

        mintAndApprove(stakingToken, alice, address(staking), incumbentStake);

        _stake(alice, incumbentStake, tier30);

        vm.prank(owner);
        staking.setRewardsDuration(address(stakingToken), 365 days);
        _notify(address(stakingToken), streamAmount);

        warp(30 days);

        _stake(bob, dustStake, tier30);

        vm.prank(alice);
        staking.unstake(0);

        warp(1);

        uint256 bobBalanceBefore = stakingToken.balanceOf(bob);

        vm.prank(bob);
        staking.claim(address(stakingToken));

        uint256 bobClaimed = stakingToken.balanceOf(bob) - bobBalanceBefore;
        uint256 maxLegitimateOneSecondReward = (streamAmount / 365 days) + DUST_TOLERANCE;
        assertLe(bobClaimed, maxLegitimateOneSecondReward);
    }

    function testExpiredStakeKeepsBoostUntilWithdrawn() public {
        _stake(alice, DEFAULT_STAKE, tier60);

        vm.prank(owner);
        staking.setRewardsDuration(address(stakingToken), 60 days);

        _notify(address(stakingToken), 60 ether);

        warp(45 days);

        assertApproxEqAbs(staking.earned(alice, address(stakingToken)), 45 ether, DUST_TOLERANCE);
        assertEq(staking.getUserStake(alice, 0).withdrawn, false);
    }

    function testDisableLockTierDoesNotAffectExistingStake() public {
        _stake(alice, DEFAULT_STAKE, tier30);

        vm.expectEmit(true, false, false, true);
        emit LockTierSet(tier30, 30 days, 10_000, false);

        vm.prank(owner);
        staking.disableLockTier(tier30);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaking.TierDisabled.selector, tier30));
        staking.stake(DEFAULT_STAKE, tier30);

        warp(30 days);
        vm.prank(alice);
        staking.unstake(0);
    }

    function testNotifyRewardAmountCarriesLeftoverWhenMidPeriod() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        _notify(address(stakingToken), 30 ether);

        (,, uint64 lastUpdateBefore, uint128 oldRewardRate,,,) = staking.rewardData(address(stakingToken));
        assertEq(lastUpdateBefore, block.timestamp);

        warp(10 days);

        vm.expectEmit(true, false, false, true);
        emit RewardNotified(address(stakingToken), 30 ether, uint64(block.timestamp + REWARD_DURATION));

        _notify(address(stakingToken), 30 ether);

        (,,, uint128 rewardRate, uint64 rewardsDuration,,) = staking.rewardData(address(stakingToken));
        uint256 leftover = (uint256(REWARD_DURATION - 10 days) * oldRewardRate) / 1e18;
        assertEq(rewardsDuration, REWARD_DURATION);
        assertEq(rewardRate, ((30 ether + leftover) * 1e18) / REWARD_DURATION);

        warp(REWARD_DURATION);
        assertApproxEqAbs(staking.earned(alice, address(stakingToken)), 60 ether, DUST_TOLERANCE);
    }

    function testPauseBlocksStakeAndCompoundButAllowsClaimAndExitPaths() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        _notify(address(stakingToken), 30 ether);
        warp(10 days);

        vm.expectEmit(false, false, false, true);
        emit Paused(owner);

        vm.prank(owner);
        staking.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staking.stake(1 ether, tier30);

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staking.compound(tier30);

        vm.prank(alice);
        staking.claim(address(stakingToken));

        warp(20 days);

        vm.prank(alice);
        staking.unstake(0);
    }

    function test_claim_worksWhilePaused() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        _notify(address(stakingToken), 30 ether);
        _notify(address(bonusToken), 60 ether);
        warp(10 days);

        uint256 primaryAccrued = staking.earned(alice, address(stakingToken));
        uint256 bonusAccrued = staking.earned(alice, address(bonusToken));

        vm.prank(owner);
        staking.pause();

        vm.prank(alice);
        staking.claim();

        assertEq(stakingToken.balanceOf(alice), type(uint120).max - DEFAULT_STAKE + primaryAccrued);
        assertEq(bonusToken.balanceOf(alice), bonusAccrued);
    }

    function testEmergencyUnstakeIsAllowedWhilePaused() public {
        _stake(alice, DEFAULT_STAKE, tier30);

        vm.prank(owner);
        staking.pause();

        vm.prank(alice);
        staking.emergencyUnstake(0);

        assertEq(staking.totalRawSupply(), 0);
    }

    function testViewHelpersReturnCurrentState() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        _stake(alice, 50 ether, tier60);

        IStaking.Stake[] memory stakes = staking.getUserStakes(alice);
        assertEq(stakes.length, 2);
        assertEq(staking.getUserStake(alice, 1).boostedAmount, 100 ether);
        assertEq(staking.getActiveStakeCount(alice), 2);

        IStaking.LockTier memory tier = staking.getLockTier(tier60);
        assertEq(tier.duration, 60 days);
        assertEq(tier.multiplierBps, 20_000);

        address[] memory rewardTokens = staking.getRewardTokens();
        assertEq(rewardTokens.length, 2);
        assertEq(rewardTokens[0], address(stakingToken));
        assertEq(rewardTokens[1], address(bonusToken));
    }

    function test_constructor_primaryRewardIsListed() public view {
        (bool enabled,,,, uint64 rewardsDuration,,) = staking.rewardData(address(stakingToken));
        assertTrue(enabled);
        assertEq(rewardsDuration, REWARD_DURATION);
    }

    function testAdminFunctionsRejectUnauthorizedCaller() public {
        MockERC20 extraReward = deployMockToken("EXT", 18);

        vm.startPrank(alice);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.addRewardToken(address(extraReward), REWARD_DURATION);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.notifyRewardAmount(address(stakingToken), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.setLockTier(7 days, 10_000);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.disableLockTier(tier30);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.setEarlyUnstakePenalty(100);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.setPrimaryRewardToken(address(stakingToken));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.setRewardsDuration(address(stakingToken), 31 days);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.recoverERC20(address(extraReward), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.pause();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.unpause();

        vm.stopPrank();
    }

    function testRewardTokenAddedEvent() public {
        Staking fresh = _deployFreshStaking(IERC20(address(stakingToken)), 1_000);
        MockERC20 thirdReward = deployMockToken("THIRD", 18);

        vm.expectEmit(true, false, false, true);
        emit RewardTokenAdded(address(thirdReward), REWARD_DURATION);

        vm.prank(owner);
        fresh.addRewardToken(address(thirdReward), REWARD_DURATION);
    }

    function testSetLockTierEmitsEvent() public {
        Staking fresh = _deployFreshStaking(IERC20(address(stakingToken)), 1_000);

        vm.expectEmit(true, false, false, true);
        emit LockTierSet(0, 14 days, 15_000, true);

        vm.prank(owner);
        fresh.setLockTier(14 days, 15_000);
    }

    function testSetPrimaryRewardTokenEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit PrimaryRewardTokenSet(address(stakingToken));

        vm.prank(owner);
        staking.setPrimaryRewardToken(address(stakingToken));
    }

    function testSetEarlyUnstakePenaltyEmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit EarlyUnstakePenaltyUpdated(500);

        vm.prank(owner);
        staking.setEarlyUnstakePenalty(500);
    }

    function testRecoverERC20EmitsEvent() public {
        MockERC20 extraToken = deployMockToken("DUST", 18);

        vm.prank(owner);
        extraToken.mint(address(staking), 5 ether);

        vm.expectEmit(true, false, false, true);
        emit RecoveredToken(address(extraToken), 5 ether);

        vm.prank(owner);
        staking.recoverERC20(address(extraToken), 5 ether);

        assertEq(extraToken.balanceOf(owner), 5 ether);
    }

    function testStakeEmitsEvent() public {
        uint64 unlockTime = uint64(block.timestamp + 30 days);

        vm.expectEmit(true, true, false, true);
        emit Staked(alice, 0, DEFAULT_STAKE, tier30, unlockTime, DEFAULT_STAKE);

        vm.prank(alice);
        staking.stake(DEFAULT_STAKE, tier30);
    }

    function testClaimSingleRewardEmitsEvent() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        _notify(address(bonusToken), 30 ether);
        warp(15 days);

        uint256 accrued = staking.earned(alice, address(bonusToken));

        vm.expectEmit(true, true, false, true);
        emit RewardClaimed(alice, address(bonusToken), accrued);

        vm.prank(alice);
        staking.claim(address(bonusToken));
    }

    function testStakeRejectsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IStaking.ZeroAmount.selector);
        staking.stake(0, tier30);
    }

    function test_stake_belowMinReverts() public {
        uint128 minimum = uint128(staking.MIN_STAKE_AMOUNT());

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaking.AmountTooSmall.selector, minimum - 1, minimum));
        staking.stake(minimum - 1, tier30);
    }

    function testStakeRejectsUnknownTier() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaking.TierNotFound.selector, 99));
        staking.stake(DEFAULT_STAKE, 99);
    }

    function testStakeRejectsFeeOnTransferStakingToken() public {
        FeeOnTransferERC20 feeToken = _deployFeeToken("Fee", "FEE", 18, 100);
        Staking fresh = _deployFreshStaking(IERC20(address(feeToken)), 500);

        vm.startPrank(owner);
        fresh.setLockTier(7 days, 10_000);
        feeToken.mint(alice, 100 ether);
        vm.stopPrank();

        vm.prank(alice);
        feeToken.approve(address(fresh), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Staking.UnsupportedToken.selector, address(feeToken)));
        fresh.stake(100 ether, 0);
    }

    function testStakeRejectsTooManyStakes() public {
        Staking fresh = _deployFreshStaking(IERC20(address(stakingToken)), 500);

        vm.prank(owner);
        fresh.setLockTier(7 days, 10_000);

        mintAndApprove(stakingToken, alice, address(fresh), 1_000 ether);

        vm.startPrank(alice);
        for (uint256 i; i < fresh.MAX_STAKES_PER_USER(); ++i) {
            fresh.stake(1 ether, 0);
        }

        vm.expectRevert(abi.encodeWithSelector(IStaking.TooManyStakes.selector, fresh.MAX_STAKES_PER_USER()));
        fresh.stake(1 ether, 0);
        vm.stopPrank();
    }

    function test_stake_cap_onActivePositions() public {
        Staking fresh = _deployFreshStaking(IERC20(address(stakingToken)), 500);

        vm.prank(owner);
        fresh.setLockTier(7 days, 10_000);

        mintAndApprove(stakingToken, alice, address(fresh), 1_000 ether);

        vm.startPrank(alice);
        for (uint256 i; i < fresh.MAX_STAKES_PER_USER(); ++i) {
            fresh.stake(1 ether, 0);
        }
        vm.stopPrank();

        warp(7 days);

        vm.startPrank(alice);
        for (uint256 i; i < fresh.MAX_STAKES_PER_USER(); ++i) {
            fresh.unstake(i);
        }

        uint256 recycledStakeId = fresh.stake(1 ether, 0);
        assertEq(recycledStakeId, fresh.MAX_STAKES_PER_USER());

        for (uint256 i = 1; i < fresh.MAX_STAKES_PER_USER(); ++i) {
            fresh.stake(1 ether, 0);
        }

        vm.expectRevert(abi.encodeWithSelector(IStaking.TooManyStakes.selector, fresh.MAX_STAKES_PER_USER()));
        fresh.stake(1 ether, 0);
        vm.stopPrank();
    }

    function test_claimGas_remainsConstantWithHistoricalStakeChurn() public {
        Staking fresh = _deployFreshStaking(IERC20(address(stakingToken)), 500);

        vm.startPrank(owner);
        uint8 shortTier = fresh.setLockTier(1, 10_000);
        uint8 longTier = fresh.setLockTier(365 days, 10_000);
        fresh.addRewardToken(address(bonusToken), REWARD_DURATION);
        stakingToken.approve(address(fresh), type(uint256).max);
        bonusToken.approve(address(fresh), type(uint256).max);
        vm.stopPrank();

        mintAndApprove(stakingToken, alice, address(fresh), 1_000_000 ether);

        vm.prank(alice);
        fresh.stake(DEFAULT_STAKE, longTier);

        vm.prank(owner);
        fresh.notifyRewardAmount(address(bonusToken), 30 ether);

        warp(1 days);
        uint256 gasBefore = _claimGas(fresh, alice, address(bonusToken));

        for (uint256 i; i < 200; ++i) {
            vm.prank(alice);
            fresh.stake(1 ether, shortTier);

            warp(1);

            vm.prank(alice);
            fresh.unstake(i + 1);
        }

        assertEq(fresh.getActiveStakeCount(alice), 1);

        warp(1 days);
        uint256 gasAfter = _claimGas(fresh, alice, address(bonusToken));

        assertLe(gasAfter, gasBefore + CLAIM_GAS_HISTORY_DELTA_MAX);
    }

    function testUnstakeRejectsLockedStake() public {
        _stake(alice, DEFAULT_STAKE, tier30);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaking.StakeLocked.selector, 0, uint64(block.timestamp + 30 days)));
        staking.unstake(0);
    }

    function testUnstakeRejectsMissingStake() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaking.StakeNotFound.selector, 0));
        staking.unstake(0);
    }

    function testUnstakeRejectsAlreadyWithdrawnStake() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        warp(30 days);

        vm.prank(alice);
        staking.unstake(0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaking.StakeAlreadyWithdrawn.selector, 0));
        staking.unstake(0);
    }

    function testEmergencyUnstakeRejectsUnlockedStake() public {
        _stake(alice, DEFAULT_STAKE, tier30);
        warp(30 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Staking.StakeUnlocked.selector, 0, uint64(block.timestamp)));
        staking.emergencyUnstake(0);
    }

    function testClaimAllRejectsNothingToClaim() public {
        vm.prank(alice);
        vm.expectRevert(IStaking.NothingToClaim.selector);
        staking.claim();
    }

    function testClaimSingleRejectsUnlistedRewardToken() public {
        MockERC20 rogueReward = deployMockToken("ROGUE", 18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaking.RewardTokenNotListed.selector, address(rogueReward)));
        staking.claim(address(rogueReward));
    }

    function testClaimSingleRejectsNothingToClaim() public {
        _stake(alice, DEFAULT_STAKE, tier30);

        vm.prank(alice);
        vm.expectRevert(IStaking.NothingToClaim.selector);
        staking.claim(address(stakingToken));
    }

    function testCompoundRejectsNothingToClaim() public {
        _stake(alice, DEFAULT_STAKE, tier30);

        vm.prank(alice);
        vm.expectRevert(IStaking.NothingToClaim.selector);
        staking.compound(tier30);
    }

    function testAddRewardTokenRejectsZeroAddress() public {
        vm.expectRevert(IStaking.ZeroAddress.selector);
        vm.prank(owner);
        staking.addRewardToken(address(0), REWARD_DURATION);
    }

    function testAddRewardTokenRejectsAlreadyListedToken() public {
        vm.expectRevert(abi.encodeWithSelector(IStaking.RewardTokenAlreadyListed.selector, address(stakingToken)));
        vm.prank(owner);
        staking.addRewardToken(address(stakingToken), REWARD_DURATION);
    }

    function testAddRewardTokenRejectsTooManyTokens() public {
        Staking fresh = _deployFreshStaking(IERC20(address(stakingToken)), 500);

        for (uint256 i; i < fresh.MAX_REWARD_TOKENS() - 1; ++i) {
            MockERC20 reward = deployMockToken(string.concat("R", vm.toString(i)), 18);
            vm.prank(owner);
            fresh.addRewardToken(address(reward), REWARD_DURATION);
        }

        MockERC20 extraReward = deployMockToken("EXTRA", 18);
        vm.expectRevert(abi.encodeWithSelector(IStaking.TooManyRewardTokens.selector, fresh.MAX_REWARD_TOKENS()));
        vm.prank(owner);
        fresh.addRewardToken(address(extraReward), REWARD_DURATION);
    }

    function testAddRewardTokenRejectsDurationOutOfRange() public {
        MockERC20 extraReward = deployMockToken("EXTRA", 18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IStaking.RewardDurationOutOfRange.selector,
                uint256(12 hours),
                staking.MIN_REWARD_DURATION(),
                staking.MAX_REWARD_DURATION()
            )
        );
        vm.prank(owner);
        staking.addRewardToken(address(extraReward), 12 hours);
    }

    function testNotifyRewardAmountRejectsUnlistedToken() public {
        MockERC20 rogueReward = deployMockToken("ROGUE", 18);

        vm.expectRevert(abi.encodeWithSelector(IStaking.RewardTokenNotListed.selector, address(rogueReward)));
        vm.prank(owner);
        staking.notifyRewardAmount(address(rogueReward), 1 ether);
    }

    function testNotifyRewardAmountRejectsTooSmallAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IStaking.RewardAmountTooLow.selector, 0, 1));
        vm.prank(owner);
        staking.notifyRewardAmount(address(stakingToken), 0);
    }

    function test_notifyRewardAmount_zeroAmountReverts() public {
        _notify(address(stakingToken), 30 ether);
        warp(10 days);

        vm.expectRevert(abi.encodeWithSelector(IStaking.RewardAmountTooLow.selector, 0, 1));
        vm.prank(owner);
        staking.notifyRewardAmount(address(stakingToken), 0);
    }

    function test_zeroSupplyRewardStreamPausesUntilStakeExists() public {
        _notify(address(bonusToken), 30 ether);
        (, uint64 periodFinishBefore,, uint128 rewardRateBefore,,,) = staking.rewardData(address(bonusToken));

        vm.warp(block.timestamp + 10 days);

        _stake(alice, DEFAULT_STAKE, tier30);

        assertEq(staking.earned(alice, address(bonusToken)), 0);

        (, uint64 periodFinishAfter,, uint128 rewardRateAfter,,,) = staking.rewardData(address(bonusToken));
        assertEq(periodFinishAfter, periodFinishBefore + 10 days);
        assertEq(rewardRateAfter, rewardRateBefore);

        vm.warp(block.timestamp + 1 days);

        assertApproxEqAbs(staking.earned(alice, address(bonusToken)), 1 ether, DUST_TOLERANCE);
    }

    function testNotifyRewardAmountRejectsFeeOnTransferRewardToken() public {
        FeeOnTransferERC20 feeReward = _deployFeeToken("FeeReward", "FRWD", 18, 100);
        Staking fresh = _deployFreshStaking(IERC20(address(stakingToken)), 500);

        vm.startPrank(owner);
        fresh.addRewardToken(address(feeReward), REWARD_DURATION);
        feeReward.mint(owner, 100 ether);
        feeReward.approve(address(fresh), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Staking.UnsupportedToken.selector, address(feeReward)));
        fresh.notifyRewardAmount(address(feeReward), 100 ether);
        vm.stopPrank();
    }

    function testSetLockTierRejectsTooManyTiers() public {
        Staking fresh = _deployFreshStaking(IERC20(address(stakingToken)), 500);

        vm.startPrank(owner);
        for (uint256 i; i < fresh.MAX_LOCK_TIERS(); ++i) {
            fresh.setLockTier(uint64(i + 1 days), 10_000);
        }

        vm.expectRevert(abi.encodeWithSelector(IStaking.TooManyTiers.selector, fresh.MAX_LOCK_TIERS()));
        fresh.setLockTier(7 days, 10_000);
        vm.stopPrank();
    }

    function testSetLockTierRejectsOutOfRangeBoost() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaking.BoostOutOfRange.selector, uint32(9_999), staking.MIN_BOOST_BPS(), staking.MAX_BOOST_BPS()
            )
        );
        vm.prank(owner);
        staking.setLockTier(7 days, 9_999);
    }

    function testDisableLockTierRejectsUnknownTier() public {
        vm.expectRevert(abi.encodeWithSelector(IStaking.TierNotFound.selector, 99));
        vm.prank(owner);
        staking.disableLockTier(99);
    }

    function testSetEarlyUnstakePenaltyRejectsTooHighPenalty() public {
        vm.expectRevert(
            abi.encodeWithSelector(IStaking.PenaltyTooHigh.selector, uint256(5_001), staking.MAX_PENALTY_BPS())
        );
        vm.prank(owner);
        staking.setEarlyUnstakePenalty(5_001);
    }

    function testSetPrimaryRewardTokenRejectsZeroAddress() public {
        vm.expectRevert(IStaking.ZeroAddress.selector);
        vm.prank(owner);
        staking.setPrimaryRewardToken(address(0));
    }

    function testSetPrimaryRewardTokenRejectsNonStakingToken() public {
        vm.expectRevert(IStaking.CompoundRequiresStakingTokenReward.selector);
        vm.prank(owner);
        staking.setPrimaryRewardToken(address(bonusToken));
    }

    function testSetRewardsDurationRejectsUnlistedRewardToken() public {
        MockERC20 rogueReward = deployMockToken("ROGUE", 18);

        vm.expectRevert(abi.encodeWithSelector(IStaking.RewardTokenNotListed.selector, address(rogueReward)));
        vm.prank(owner);
        staking.setRewardsDuration(address(rogueReward), 31 days);
    }

    function testSetRewardsDurationRejectsOutOfRangeDuration() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaking.RewardDurationOutOfRange.selector,
                uint256(366 days),
                staking.MIN_REWARD_DURATION(),
                staking.MAX_REWARD_DURATION()
            )
        );
        vm.prank(owner);
        staking.setRewardsDuration(address(stakingToken), 366 days);
    }

    function testSetRewardsDurationRejectsActivePeriod() public {
        _notify(address(stakingToken), 30 ether);

        vm.expectRevert(
            abi.encodeWithSelector(Staking.RewardPeriodNotFinished.selector, uint64(block.timestamp + REWARD_DURATION))
        );
        vm.prank(owner);
        staking.setRewardsDuration(address(stakingToken), 31 days);
    }

    function testRecoverERC20RejectsStakingToken() public {
        vm.expectRevert(IStaking.CannotRecoverStakingToken.selector);
        vm.prank(owner);
        staking.recoverERC20(address(stakingToken), 1 ether);
    }

    function testRecoverERC20RejectsRewardToken() public {
        vm.expectRevert(abi.encodeWithSelector(IStaking.CannotRecoverRewardToken.selector, address(bonusToken)));
        vm.prank(owner);
        staking.recoverERC20(address(bonusToken), 1 ether);
    }

    function testClaimReentrancyIsBlocked() public {
        ReentrantERC20 rewardToken = _deployReentrantToken("Reward", "RWD", 18);
        Staking fresh = _deployFreshStaking(IERC20(address(stakingToken)), 500);

        vm.startPrank(owner);
        fresh.setLockTier(30 days, 10_000);
        fresh.addRewardToken(address(rewardToken), REWARD_DURATION);
        rewardToken.mint(owner, 30 ether);
        rewardToken.approve(address(fresh), type(uint256).max);
        vm.stopPrank();

        mintAndApprove(stakingToken, alice, address(fresh), 100 ether);

        vm.prank(alice);
        fresh.stake(100 ether, 0);

        vm.prank(owner);
        fresh.notifyRewardAmount(address(rewardToken), 30 ether);

        warp(REWARD_DURATION);

        vm.prank(owner);
        rewardToken.setHook(
            ReentrantERC20.HookType.Transfer,
            address(fresh),
            abi.encodeWithSignature("claim(address)", address(rewardToken))
        );

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        fresh.claim(address(rewardToken));
    }

    function testStakeReentrancyIsBlocked() public {
        ReentrantERC20 reentrantStakeToken = _deployReentrantToken("Stake", "RSTK", 18);
        Staking fresh = _deployFreshStaking(IERC20(address(reentrantStakeToken)), 500);

        vm.prank(owner);
        fresh.setLockTier(30 days, 10_000);

        vm.startPrank(owner);
        reentrantStakeToken.mint(alice, 200 ether);
        reentrantStakeToken.setHook(
            ReentrantERC20.HookType.TransferFrom, address(fresh), abi.encodeCall(Staking.stake, (1 ether, uint8(0)))
        );
        vm.stopPrank();

        vm.prank(alice);
        reentrantStakeToken.approve(address(fresh), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        fresh.stake(100 ether, 0);
    }

    function testFlushPenaltyReentrancyIsBlocked() public {
        ReentrantERC20 reentrantStakeToken = _deployReentrantToken("Stake", "RSTK", 18);
        Staking fresh = _deployFreshStaking(IERC20(address(reentrantStakeToken)), 500);

        vm.prank(owner);
        fresh.setLockTier(30 days, 10_000);

        vm.startPrank(owner);
        reentrantStakeToken.mint(alice, 200 ether);
        reentrantStakeToken.setHook(
            ReentrantERC20.HookType.TransferFrom, address(fresh), abi.encodeCall(Staking.flushPenalty, ())
        );
        vm.stopPrank();

        vm.prank(alice);
        reentrantStakeToken.approve(address(fresh), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        fresh.stake(100 ether, 0);
    }

    function testNotifyRewardAmountReentrancyIntoFlushPenaltyIsBlocked() public {
        ReentrantERC20 reentrantStakeToken = _deployReentrantToken("Stake", "RSTK", 18);
        Staking fresh = _deployFreshStaking(IERC20(address(reentrantStakeToken)), 1_000);

        vm.prank(owner);
        fresh.setLockTier(30 days, 10_000);

        vm.startPrank(owner);
        reentrantStakeToken.mint(owner, 30 ether);
        reentrantStakeToken.mint(alice, 100 ether);
        reentrantStakeToken.approve(address(fresh), type(uint256).max);
        vm.stopPrank();

        vm.prank(alice);
        reentrantStakeToken.approve(address(fresh), type(uint256).max);

        vm.prank(alice);
        fresh.stake(100 ether, 0);

        vm.prank(alice);
        fresh.emergencyUnstake(0);

        vm.prank(owner);
        reentrantStakeToken.setHook(
            ReentrantERC20.HookType.TransferFrom, address(fresh), abi.encodeCall(Staking.flushPenalty, ())
        );

        vm.prank(owner);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        fresh.notifyRewardAmount(address(reentrantStakeToken), 30 ether);
    }

    function testStakeOverflowReverts() public {
        Staking fresh = _deployFreshStaking(IERC20(address(stakingToken)), 500);

        vm.prank(owner);
        fresh.setLockTier(7 days, 30_000);

        vm.prank(owner);
        stakingToken.mint(alice, type(uint128).max);

        vm.prank(alice);
        stakingToken.approve(address(fresh), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(Staking.Overflow.selector);
        fresh.stake(type(uint128).max, 0);
    }

    function testFlushPenaltyChecksPrimaryRewardBacking() public {
        _stake(alice, DEFAULT_STAKE, tier30);

        vm.prank(alice);
        staking.emergencyUnstake(0);

        vm.prank(owner);
        stakingToken.burn(address(staking), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                Staking.InsufficientRewardBalance.selector, address(stakingToken), 10 ether - 1, 9 ether
            )
        );
        staking.flushPenalty();
    }

    function testFlushPenaltyOverflowDoesNotExtendActiveStream() public {
        _stake(alice, 4_000 ether, tier30);
        _notify(address(stakingToken), 1 ether);

        (, uint64 periodFinishBefore,,,,,) = staking.rewardData(address(stakingToken));

        vm.warp(periodFinishBefore - 1);

        vm.prank(alice);
        staking.emergencyUnstake(0);

        (,,,,,, uint256 queuedPenaltyBefore) = staking.rewardData(address(stakingToken));
        assertGt(queuedPenaltyBefore, 340 ether);

        vm.expectRevert(Staking.Overflow.selector);
        staking.flushPenalty();

        (, uint64 periodFinishAfter,,,,, uint256 queuedPenaltyAfter) = staking.rewardData(address(stakingToken));
        assertEq(periodFinishAfter, periodFinishBefore);
        assertEq(queuedPenaltyAfter, queuedPenaltyBefore);
    }

    function testConstructorRejectsInvalidPrimaryRewardToken() public {
        vm.expectRevert(IStaking.CompoundRequiresStakingTokenReward.selector);
        vm.prank(owner);
        new Staking(IERC20(address(stakingToken)), address(bonusToken), 500);
    }

    function testConstructorRejectsPenaltyAboveCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(IStaking.PenaltyTooHigh.selector, uint256(5_001), staking.MAX_PENALTY_BPS())
        );
        vm.prank(owner);
        new Staking(IERC20(address(stakingToken)), address(stakingToken), 5_001);
    }

    function _deployFreshStaking(IERC20 token, uint256 penaltyBps) internal returns (Staking fresh) {
        vm.prank(owner);
        fresh = new Staking(token, address(token), penaltyBps);
    }

    function _deployFeeToken(string memory name_, string memory symbol_, uint8 decimals_, uint256 feeBps_)
        internal
        returns (FeeOnTransferERC20 token)
    {
        vm.prank(owner);
        token = new FeeOnTransferERC20(name_, symbol_, decimals_, feeBps_);
    }

    function _deployReentrantToken(string memory name_, string memory symbol_, uint8 decimals_)
        internal
        returns (ReentrantERC20 token)
    {
        vm.prank(owner);
        token = new ReentrantERC20(name_, symbol_, decimals_);
    }

    function _stake(address user, uint128 amount, uint8 tierId) internal returns (uint256 stakeId) {
        vm.prank(user);
        stakeId = staking.stake(amount, tierId);
    }

    function _notify(address token, uint256 amount) internal {
        vm.prank(owner);
        staking.notifyRewardAmount(token, amount);
    }

    function _roundingAttacker(uint256 index) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked("round7-rounding-attacker", index)))));
    }

    function _claimGas(Staking staking_, address user, address rewardToken) internal returns (uint256 gasUsed) {
        vm.prank(user);
        uint256 gasStart = gasleft();
        staking_.claim(rewardToken);
        gasUsed = gasStart - gasleft();
    }
}
