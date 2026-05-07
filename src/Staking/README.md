# Staking — Lock-Tiered Staking with Multi-Reward Distribution

Users stake a single ERC-20 token under one of several configurable lock tiers (e.g., 30/60/90 days) and accrue rewards in multiple reward tokens. Longer locks apply a boost multiplier. Early unstaking forfeits a portion of principal; forfeitures feed a penalty pool that redistributes through the reward stream.

## Conceptual Model

Two intertwined accounting systems meet at `totalBoostedSupply`:

1. **Reward accumulator (per reward token).** Synthetix `StakingRewards` pattern. Each reward token has a `rewardRate`, `periodFinish`, `rewardPerTokenStored`, `lastUpdateTime`. Users track `userRewardPerTokenPaid` vs. current `rewardPerToken()`, weighted by boosted stake.

2. **Per-stake principal with lock + boost.** Each user has an array of stake positions (immutable). Principal is separate from rewards: `unstake` returns principal, `claim` pulls rewards.

Stakes are **immutable** — no partial unstake. User unstakes whole positions only.

## External Surface

User:
- `stake(amount, tierId) → stakeId`
- `unstake(stakeId)` — only after `unlockTime`; callable while paused
- `emergencyUnstake(stakeId)` — only before `unlockTime`; applies penalty
- `claim()` / `claim(rewardToken)` — all or single reward token
- `compound(tierId) → stakeId` — restake primary-reward balance; primary == staking token
- `flushPenalty()` — public, moves `queuedPenalty` into the reward stream without extending `periodFinish` if active

Views: `rewardPerToken`, `earned`, `getUserStakes`, `getUserStake`, `getRewardTokens`, `getLockTier`, `getActiveStakeCount`. `earned` must match what a `claim` would pay.

Admin (owner):
- `addRewardToken`, `notifyRewardAmount`, `setLockTier`, `disableLockTier`
- `setEarlyUnstakePenalty`, `setPrimaryRewardToken` (must equal staking token)
- `setRewardsDuration` (only if period ended), `recoverERC20` (rejects staking + reward tokens)
- `pause`, `unpause`

## Constants

| Name | Value |
|---|---|
| `PRECISION` | 1e18 (reward-per-token precision) |
| `MAX_REWARD_TOKENS` | 4 |
| `MAX_LOCK_TIERS` | 6 |
| `MIN_REWARD_DURATION` | 1 day |
| `MAX_REWARD_DURATION` | 365 days |
| `MAX_BOOST_BPS` / `MIN_BOOST_BPS` | 30_000 (3×) / 10_000 (1×) |
| `MAX_PENALTY_BPS` | 5_000 (50%) |
| `MAX_STAKES_PER_USER` | 64 |
| `MIN_STAKE_AMOUNT` | 1e12 |

## Key Design Choices

- **`primaryRewardToken == stakingToken` is a load-bearing invariant.** Constructor registers the staking token as a reward token and seeds it as primary. Simplifies penalty routing (no swap logic). Enforced by `setPrimaryRewardToken`.
- **Lock tier IDs are monotonic and never reused.** Disabling a tier doesn't affect active stakes on it; changing a tier in place would retroactively mutate user unlock terms, so disallowed by design.
- **Penalty routing.** `emergencyUnstake` adds the penalty to `rewardData[primary].queuedPenalty` (tokens stay in the contract since primary == staking). `flushPenalty` later moves it into the reward stream. If the stream is active, `periodFinish` is preserved and `rewardRate` recalculated via leftover-carry; if idle, a fresh full-duration window starts.
- **Expired-but-unclaimed stakes continue earning at boosted rate.** Intentional; users must unstake to stop accruing.
- **Cached per-user state.** `_userActiveStakeCount[user]` and `_userBoostedAmount[user]` keep reward-update reads O(1) regardless of historical stake count.

## Key Invariants

1. `totalRawSupply == sum of active stakes' amount`.
2. `totalBoostedSupply == sum of active stakes' boostedAmount`.
3. `rewardPerTokenStored` monotonically non-decreasing over time.
4. `lastUpdateTime <= block.timestamp` and `<= periodFinish`.
5. After `_updateRewardUser`: `userRewardPerTokenPaid[user][token] <= rewardPerTokenStored`.
6. `stakingToken.balanceOf(this) >= totalRawSupply + queuedPenalty + unstreamed primary-reward budget`. The staking token and the primary reward token are the same contract balance; it has to cover both at once.
7. `stake.withdrawn == false` for stakes counted in the totals.

## Trust / Scope Notes

- Reentrancy via reward-token or staking-token callbacks is mitigated by `ReentrancyGuard` + CEI on all user-facing functions.
- Fee-on-transfer tokens are rejected via pre/post balance deltas on `stake` and `notifyRewardAmount`.
- `recoverERC20` cannot pull the staking token or any reward token.
- Admin is assumed honest. Admin-only exploits are out of scope.

## Hotspots for Auditors

- **Reward accumulator ordering.** `_updateRewardAll(user)` must run before any mutation of `_userBoostedAmount[user]` or `totalBoostedSupply`. Any path that mutates boosted state without snapshotting first leaks reward accounting.
- **`compound` flow.** Zero the reward balance before creating the new stake (CEI), since the token is already in the contract.
- **`flushPenalty` rate recalc.** `periodFinish` must not be extended if the stream is already active; leftover-carry math is the right lens.
- **Boundary between active-period and post-period rewards.** `lastUpdateTime` should clamp at `periodFinish`.
- **Primary-reward balance accounting.** Invariant 7 binds staking and reward budgets to the same balance — any change that touches one must respect the other.
