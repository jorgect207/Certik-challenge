# Stump the AI Auditor

CertiK is running a public 2-week challenge. The goal: see if you can sneak a real fund-draining bug past our AI Auditor.

## Challenge Window

**2026-04-29, 9:00 AM ET to 2026-05-13, 23:59 ET.** Rolling submissions. Deadline is firm.

- Apply: https://docs.google.com/forms/d/1dPBQaHMjTGleUUfIo0CJtqygHTSuFULY_l-pQX6kQ-4
- Submit: https://docs.google.com/forms/d/1p7BsPZZkrYneSITfsY2hrOq81ohX-f-DTgoUGYTLap0
- Results: Wed 2026-05-20

## Prizes

| Place | Prize |
|---|---|
| 1st | $1,000 AI Auditor credits + interview fast-track |
| 2nd | $500 AI Auditor credits + interview fast-track |
| 3rd | $250 AI Auditor credits + interview fast-track |

Every valid stump gets public recognition (opt-in). Interview fast-track means your profile goes directly to CertiK's auditor hiring team with the challenge context.

## How To Stump Us

1. **Apply.** Submit the application form. We're reviewing on a rolling basis throughout the challenge.
2. **Get whitelisted on AI Auditor.** Approved applicants are whitelisted on https://aiauditor.certik.com. Sign up (Google or magic link) and your account is pre-loaded with **4 Lite scan credits**.
3. **Pick a contract.** Fork this repo. Choose one of `Vault`, `Staking`, or `Lending`. Read the per-contract README to understand the mechanics.
4. **Plant a vulnerability.** Modify your chosen contract, 50 lines or fewer. The bug must be:
   - Critical or High severity (real fund drain - see severity bar)
   - Subtle enough to slip past AI Auditor Lite
   - Realistic enough that a senior engineer could plausibly ship it
5. **Scan in Lite mode.** Run AI Auditor against your modified contract. **Lite mode only. Do not use Max** - Max is disabled for the challenge, would invalidate your submission, and burns credits faster. Each Lite scan costs one credit; you have 4 total.
6. **Iterate.** If Lite flags your bug, the scan is consumed and you have 3 left. Tweak and rescan. If Lite misses it, you have a stump.
7. **Submit.** One stump = one Lite scan that missed a real Critical or High vulnerability you planted. Submit via the form above. **One submission per person, total.** Pick your best.

### Bonus: bugs in the unmodified base contracts (for fun)

The base contracts may contain real, intentional vulnerabilities. If you find one while studying the code, send us a Foundry PoC and we'll give you public recognition for it. Bonus path only - it doesn't compete for the top-3 prize, just bragging rights.

## Severity Bar

**Critical** - direct theft of user funds, permanent freezing of user funds, protocol insolvency.
**High** - theft or permanent freezing of unclaimed yield, temporary freezing of user funds.

Rejected: Medium and below, exploits requiring admin action, exploits requiring external conditions you don't control (oracle depegs, MEV on out-of-scope pools).

## Auto-Disqualified

- Unrestricted `drain()` / `rescue()` / `emergencyWithdraw()`
- Hardcoded attacker address
- Removed `onlyOwner` / `whenNotPaused` / `nonReentrant` with no replacement
- Inverted access control

If a senior engineer wouldn't plausibly ship your diff as a mistake, it's sabotage and won't count.

## Trust Model

The owner (`Ownable2Step`) is assumed honest. Admin-only exploits are out of scope. Bugs must be exploitable by an unprivileged attacker, or require only normal admin actions (config changes, reward issuance).

External conditions the attacker doesn't control (oracle depegs, MEV on out-of-scope pools) are also out of scope.

Contracts use `Ownable2Step`, `ReentrancyGuard`, `Pausable`, and `SafeERC20`. Fee-on-transfer and rebasing tokens are explicitly rejected via pre/post balance deltas.

## The Three Contracts

### `src/Vault/Vault.sol` - Multi-Asset Vault

ERC-4626-inspired vault over multiple whitelisted stablecoins. Shares claim pro-rata on WAD-normalized assets. Management fee (time-based) plus performance fee (on per-share HWM lift). Block-based withdrawal timelock with proportional pending-side yield share. Virtual-share offset blocks first-depositor inflation. Full mechanics: [`src/Vault/README.md`](./src/Vault/README.md).

### `src/Staking/Staking.sol` - Lock-Tiered Staking

Synthetix `StakingRewards` x MasterChef x veToken-lite. Users stake into tiered locks with boost multipliers, accrue rewards in multiple tokens, and early-unstake penalties redistribute to remaining stakers. `primaryRewardToken == stakingToken` is a load-bearing invariant. Full mechanics: [`src/Staking/README.md`](./src/Staking/README.md).

### `src/Lending/Lending.sol` - Lending Pool

Aave v2-lite. Scaled-balance supply/borrow, kinked interest curve, oracle-priced collateral, health-factor liquidation. Scales: **RAY** (1e27) for indices and rates, **WAD** (1e18) for USD and HF, **BPS** (10_000) for config params, **1e8** for raw Chainlink-style oracle prices. Full mechanics: [`src/Lending/README.md`](./src/Lending/README.md).

## Where to Look

Good stumps live where **two features interact**:

- **Vault** - fee accrual x pending withdrawals, reportYield x active/pending skew
- **Staking** - reward accumulator x compound/emergency ordering, penalty flush x rate recalc
- **Lending** - interest accrual x liquidation, oracle staleness x health factor, index rounding x long-horizon drift

Single-line rounding flips often beat multi-line reworks. Diff size isn't judged - severity, subtlety, realism, and novelty are.

## Getting Started

```bash
git clone --recurse-submodules https://github.com/CertiKProject/stump-the-auditor-contracts
cd stump-the-auditor-contracts
forge build
forge test
```

Invariant + fuzz coverage:

```bash
forge test --match-path "test/invariants/*"
forge test --fuzz-runs 1000
```

**PoC template:** copy `test/PlantPoC.t.sol.example` to `test/PlantPoC.t.sol`, plant your bug, and prove the exploit with a Foundry test before submitting.

## Requirements

- [Foundry](https://book.getfoundry.sh/) - install via `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- Solidity `^0.8.24`, EVM version `cancun`
- OpenZeppelin Contracts v5.1 (pinned submodule)

If `forge build` fails on a fresh clone of the unmodified base, email us.

## Submission Contents

Submit via the form above. Provide:

- Which contract (Vault / Staking / Lending)
- AI Auditor Lite scan URL (proof Lite missed your bug)
- GitHub repo URL of your fork (we read your code from there)
- Severity claim (Critical or High) with subclass and one-paragraph justification
- Writeup: what the bug is, exploit steps, impact, why it's a realistic dev mistake

One submission per person.

## Contact

**dickson.wu@certik.com** for rules questions or anything else.

## License

MIT. See [LICENSE](./LICENSE).
