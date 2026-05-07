// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStaking {
    struct LockTier {
        bool enabled;
        uint64 duration;
        uint32 multiplierBps;
    }

    struct Stake {
        uint128 amount;
        uint128 boostedAmount;
        uint8 tierId;
        uint64 startTime;
        uint64 unlockTime;
        bool withdrawn;
    }

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

    error ZeroAmount();
    error AmountTooSmall(uint256 provided, uint256 minimum);
    error ZeroAddress();
    error TierDisabled(uint8 tierId);
    error TierNotFound(uint8 tierId);
    error StakeNotFound(uint256 stakeId);
    error StakeAlreadyWithdrawn(uint256 stakeId);
    error StakeLocked(uint256 stakeId, uint64 unlockTime);
    error TooManyStakes(uint256 maxStakes);
    error TooManyRewardTokens(uint256 max);
    error TooManyTiers(uint256 max);
    error RewardTokenNotListed(address token);
    error RewardTokenAlreadyListed(address token);
    error RewardDurationOutOfRange(uint256 provided, uint256 min, uint256 max);
    error RewardAmountTooLow(uint256 provided, uint256 min);
    error PenaltyAmountTooLow(uint256 provided, uint256 minimum);
    error NoQueuedPenalty();
    error PenaltyTooHigh(uint256 provided, uint256 max);
    error BoostOutOfRange(uint32 provided, uint256 min, uint256 max);
    error CannotRecoverStakingToken();
    error CannotRecoverRewardToken(address token);
    error PrimaryRewardNotListed(address token);
    error NothingToClaim();
    error CompoundRequiresStakingTokenReward();

    function stake(uint128 amount, uint8 tierId) external returns (uint256 stakeId);
    function unstake(uint256 stakeId) external;
    function emergencyUnstake(uint256 stakeId) external;
    function claim() external;
    function claim(address rewardToken) external;
    function compound(uint8 tierId) external returns (uint256 stakeId);
    function flushPenalty() external;

    function rewardPerToken(address rewardToken) external view returns (uint256);
    function earned(address user, address rewardToken) external view returns (uint256);
    function getUserStakes(address user) external view returns (Stake[] memory);
    function getUserStake(address user, uint256 stakeId) external view returns (Stake memory);
    function getRewardTokens() external view returns (address[] memory);
    function getLockTier(uint8 tierId) external view returns (LockTier memory);
    function getActiveStakeCount(address user) external view returns (uint256);

    function addRewardToken(address token, uint64 duration) external;
    function notifyRewardAmount(address token, uint256 amount) external;
    function setLockTier(uint64 duration, uint32 multiplierBps) external returns (uint8 tierId);
    function disableLockTier(uint8 tierId) external;
    function setEarlyUnstakePenalty(uint256 bps) external;
    function setPrimaryRewardToken(address token) external;
    function setRewardsDuration(address token, uint64 duration) external;
    function recoverERC20(address token, uint256 amount) external;
    function pause() external;
    function unpause() external;
}
