# Contributor test coverage

Run `forge build` and `forge test` from the repository root. The added tests use only
checked-in dependencies and run with `forge test --offline`; no RPC, environment
changes, private keys, FFI, or network service is required. Existing tests are retained.

| Added suite | Properties and failure cases |
| --- | --- |
| `RewardsAdversarial.t.sol` | Failed pulls and payouts restore balances, allowances, checkpoints and counters; false/no-return ERC-20 behavior; dust; batch limits and atomicity; checkpoint partition independence. |
| `ActivityBoundaries.t.sol` | Exact freshness boundary, revocation, report validation, dependency outage and recovery, pairing permissions, constructor validation, two-step ownership and duration bounds. |
| `HookAdversarial.t.sol` | Every pool-key field and callback caller authenticated; negative fee deltas; real v4 fee routing in both currency orders; rounding and uint256 quote limits; stale quotes, insufficient allowance/inventory, taxed transfers, reentrancy and retryable forwarding; deployer ownership binding. |
| `ReceiverCallbacks.t.sol` | Mint state and free-claim pairing are complete before receiver callbacks; six value-moving entry points reject reentrancy; transferring the NFT inside the callback preserves ownership and accounting. |
| `Metadata.t.sol` | Decode actual base64 JSON and SVG; distinct images for different IDs; exact activity fields; pairing, expiry and ownership changes; metadata refresh events and invalid IDs. |
| `LaunchTokenStateful.t.sol` | Four actors with independently tracked balances and allowances; finite/unlimited approvals, revocation, direct/delegated/self/zero/full-supply transfers, rejected overspending; supply remains 10^27. |
| `RewardsStateful.t.sol` | Four actors, paid/free mints, transfers, deposits, unsynchronized donations, time, checkpoints, single/batch claims and creator withdrawals; independent cash flows, ownership, claims and creator allocations; pending entitlement backing and permanent caps. |
| `HookStateful.t.sol` | Real v4 swaps, donations, add/remove/poke liquidity, inventory gifts, price changes, three buyers, conversion, forwarding and payouts; independent fee custody, both asset supplies, LP principal settlement and cleared approvals. |

Each new invariant campaign uses inline configuration for **256 runs × 64 calls**,
with unexpected reverts treated as failures. Only explicitly selected handler methods
are randomized. Expected rejection paths verify the concrete error. Deterministic
handler scenarios demonstrate that successful claims, synchronization, fee harvesting,
sales and forwarding are reachable; the call tables expose selector coverage.

The rewards campaign deliberately advances time without immediately checkpointing and
allows donations to remain unrecognized across intervening calls. At the end of every
sequence it synchronizes donations and pays all claimable rewards and creator credit,
then checks that only the unallocated reserve remains. The hook campaign removes all
remaining LP liquidity and forwards IMD at the end of every sequence. These teardown
checks test withdrawal liveness in addition to accounting equalities.

Arithmetic and activity-boundary fuzz tests run 1,000 cases each. Metadata fuzzing runs
256 cases, including arbitrary uint64 scores and timestamps. Known boundaries are
also pinned as unit tests. Constructor rejection cases are isolated because Foundry's
dynamic deployment linking can propagate an expected constructor revert out of the
test function, bypassing assertions that follow it.

## Scope and assumptions

The real accepted collection, activity registry, launch token, hook and deployer are
used. Hook integration uses the real vendored PoolManager and actual CREATE2 deployment.
Only the external IMD and Identity contracts are local test doubles, installed at the
addresses the implementation uses. The adversarial IMD cases model transfer failures,
inexact receipts, callbacks, and nonstandard ERC-20 return data. They do not establish
the behavior of the live token or identity registry.

The ordinary custody properties assume the specified non-rebasing, 18-decimal IMD
token. Fee conversion uses the explicit owner-set ask; these tests do not certify its
economic fairness. Reward duration and activity reporting in fixtures are test inputs.

The existing launch-pool routing conflict in `docs/REVIEW.md` remains unresolved by
these tests: the supplied hook handles a separately initialized pool, while the policy
launch pool uses the factory's guard and fee recipients. Passing tests do not establish
that launch-pool trading fees fund NFT rewards. No assertion blesses that mismatch.

Live-chain fork validation of the supplied IMD and Identity contracts and the deployed
PoolManager is still owed by integration work; this suite makes no live-state claim.
