// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IStaking} from "src/interfaces/IStaking.sol";
import {Staking} from "src/Staking/Staking.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {BaseTest} from "test/helpers/BaseTest.sol";

contract StakingHandler is Test {
    uint64 internal constant REWARD_DURATION = 30 days;
    uint256 internal constant MAX_NOTIFY = 1_000 ether;
    uint256 internal constant MAX_STAKE = 5_000 ether;

    Staking internal immutable staking;
    MockERC20 internal immutable stakingToken;
    MockERC20 internal immutable bonusToken;
    address internal immutable owner;
    address[] internal actors;

    mapping(address => uint256) internal lastRewardPerTokenStored;
    bool internal rewardPerTokenMonotonic = true;

    constructor(
        Staking staking_,
        MockERC20 stakingToken_,
        MockERC20 bonusToken_,
        address owner_,
        address[] memory actors_
    ) {
        staking = staking_;
        stakingToken = stakingToken_;
        bonusToken = bonusToken_;
        owner = owner_;
        actors = actors_;

        _syncRewardSnapshots();
    }

    function stake(uint256 actorSeed, uint256 amountSeed, uint256 tierSeed) external {
        address actor = _actor(actorSeed);
        uint8 tierId = uint8(tierSeed % staking.nextLockTierId());

        uint256 balance = stakingToken.balanceOf(actor);
        if (balance == 0) {
            _syncRewardSnapshots();
            return;
        }

        uint256 maxAmount = balance < MAX_STAKE ? balance : MAX_STAKE;
        uint128 amount = uint128(bound(amountSeed, 1, maxAmount));

        vm.prank(actor);
        try staking.stake(amount, tierId) {} catch {}

        _syncRewardSnapshots();
    }

    function unstake(uint256 actorSeed, uint256 stakeSeed) external {
        address actor = _actor(actorSeed);
        IStaking.Stake[] memory stakes = staking.getUserStakes(actor);
        if (stakes.length == 0) {
            _syncRewardSnapshots();
            return;
        }

        uint256 stakeId = stakeSeed % stakes.length;

        vm.prank(actor);
        try staking.unstake(stakeId) {} catch {}

        _syncRewardSnapshots();
    }

    function emergencyUnstake(uint256 actorSeed, uint256 stakeSeed) external {
        address actor = _actor(actorSeed);
        IStaking.Stake[] memory stakes = staking.getUserStakes(actor);
        if (stakes.length == 0) {
            _syncRewardSnapshots();
            return;
        }

        uint256 stakeId = stakeSeed % stakes.length;

        vm.prank(actor);
        try staking.emergencyUnstake(stakeId) {} catch {}

        _syncRewardSnapshots();
    }

    function claim(uint256 actorSeed) external {
        vm.prank(_actor(actorSeed));
        try staking.claim() {} catch {}

        _syncRewardSnapshots();
    }

    function claimSingle(uint256 actorSeed, uint256 tokenSeed) external {
        address[] memory rewardTokens = staking.getRewardTokens();
        address rewardToken = rewardTokens[tokenSeed % rewardTokens.length];

        vm.prank(_actor(actorSeed));
        try staking.claim(rewardToken) {} catch {}

        _syncRewardSnapshots();
    }

    function compound(uint256 actorSeed, uint256 tierSeed) external {
        vm.prank(_actor(actorSeed));
        try staking.compound(uint8(tierSeed % staking.nextLockTierId())) {} catch {}

        _syncRewardSnapshots();
    }

    function notifyRewardAmount(uint256 tokenSeed, uint256 amountSeed) external {
        address[] memory rewardTokens = staking.getRewardTokens();
        address rewardToken = rewardTokens[tokenSeed % rewardTokens.length];
        uint256 amount = bound(amountSeed, 1 ether, MAX_NOTIFY);

        vm.prank(owner);
        try staking.notifyRewardAmount(rewardToken, amount) {} catch {}

        _syncRewardSnapshots();
    }

    function flushPenalty() external {
        try staking.flushPenalty() {} catch {}

        _syncRewardSnapshots();
    }

    function advanceTime(uint256 secondsSeed) external {
        uint256 jump = bound(secondsSeed, 1, 15 days);
        vm.warp(block.timestamp + jump);
        vm.roll(block.number + ((jump + 11) / 12));

        _syncRewardSnapshots();
    }

    function monotonicRewardPerTokenOk() external view returns (bool) {
        return rewardPerTokenMonotonic;
    }

    function _syncRewardSnapshots() internal {
        address[] memory rewardTokens = staking.getRewardTokens();
        uint256 length = rewardTokens.length;
        for (uint256 i; i < length; ++i) {
            address rewardToken = rewardTokens[i];
            (,,,,, uint256 rewardPerTokenStored,) = staking.rewardData(rewardToken);
            if (rewardPerTokenStored < lastRewardPerTokenStored[rewardToken]) {
                rewardPerTokenMonotonic = false;
            }
            lastRewardPerTokenStored[rewardToken] = rewardPerTokenStored;
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}

contract StakingInvariants is StdInvariant, BaseTest {
    uint64 internal constant REWARD_DURATION = 30 days;
    uint256 internal constant INITIAL_BALANCE = 1_000_000 ether;

    MockERC20 internal stakingToken;
    MockERC20 internal bonusToken;
    Staking internal staking;
    StakingHandler internal handler;
    address[] internal actors;

    function setUp() public override {
        super.setUp();

        stakingToken = deployMockToken("STK", 18);
        bonusToken = deployMockToken("BON", 18);

        vm.startPrank(owner);
        staking = new Staking(IERC20(address(stakingToken)), address(stakingToken), 1_000);
        staking.setLockTier(30 days, 10_000);
        staking.setLockTier(60 days, 20_000);
        staking.setLockTier(90 days, 30_000);
        staking.addRewardToken(address(bonusToken), REWARD_DURATION);

        stakingToken.mint(owner, INITIAL_BALANCE);
        bonusToken.mint(owner, INITIAL_BALANCE);
        stakingToken.approve(address(staking), type(uint256).max);
        bonusToken.approve(address(staking), type(uint256).max);
        vm.stopPrank();

        actors.push(alice);
        actors.push(bob);
        actors.push(charlie);

        for (uint256 i; i < actors.length; ++i) {
            mintAndApprove(stakingToken, actors[i], address(staking), INITIAL_BALANCE);
        }

        handler = new StakingHandler(staking, stakingToken, bonusToken, owner, actors);
        targetContract(address(handler));
    }

    function invariant_stakingAccountingHolds() public view {
        (uint256 rawSupply, uint256 boostedSupply) = _sumActiveStakes();
        assertEq(staking.totalRawSupply(), rawSupply);
        assertEq(staking.totalBoostedSupply(), boostedSupply);

        assertEq(staking.primaryRewardToken(), address(stakingToken));
        assertTrue(handler.monotonicRewardPerTokenOk());

        address[] memory rewardTokens = staking.getRewardTokens();
        uint256 rewardLength = rewardTokens.length;
        for (uint256 i; i < rewardLength; ++i) {
            address rewardToken = rewardTokens[i];
            (
                ,
                uint64 periodFinish,
                uint64 lastUpdateTime,
                uint128 rewardRate,
                uint64 rewardsDuration,
                uint256 rewardPerTokenStored,
                uint256 queuedPenalty
            ) = staking.rewardData(rewardToken);

            assertLe(lastUpdateTime, block.timestamp);
            assertLe(lastUpdateTime, periodFinish);
            assertLe(rewardsDuration, staking.MAX_REWARD_DURATION());

            for (uint256 j; j < actors.length; ++j) {
                assertLe(staking.userRewardPerTokenPaid(actors[j], rewardToken), rewardPerTokenStored);
            }

            if (rewardToken == address(stakingToken)) {
                uint256 unstreamedBudget = _unstreamedBudget(periodFinish, rewardRate);
                uint256 requiredBalance = staking.totalRawSupply() + queuedPenalty + unstreamedBudget;
                assertGe(stakingToken.balanceOf(address(staking)), requiredBalance);
            }
        }
    }

    function _sumActiveStakes() internal view returns (uint256 rawSupply, uint256 boostedSupply) {
        for (uint256 i; i < actors.length; ++i) {
            IStaking.Stake[] memory stakes = staking.getUserStakes(actors[i]);
            for (uint256 j; j < stakes.length; ++j) {
                if (!stakes[j].withdrawn) {
                    rawSupply += stakes[j].amount;
                    boostedSupply += stakes[j].boostedAmount;
                }
            }
        }
    }

    function _unstreamedBudget(uint64 periodFinish, uint128 rewardRate) internal view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return ((periodFinish - block.timestamp) * uint256(rewardRate)) / staking.PRECISION();
    }
}
