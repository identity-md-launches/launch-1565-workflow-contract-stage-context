# ABI and integration guide

Machine-readable ABI arrays are in `docs/abi/<Contract>.json`. Regenerate after `forge build` with `python3 scripts/export_abis.py`; compare with `--check`. All integer monetary values are minor units: both IMD and LaunchToken have 18 decimals. ABI arrays include inherited ERC-20/ERC-721/ownership functions and custom errors. The following are the principal application calls.

## Collection: Swarmlers

| Function | Caller / purpose |
|---|---|
| `mint() -> tokenId` | Payer; approve exactly 0.25 IMD to the collection first |
| `freeClaim(identityId) -> tokenId` | Identity holder; requires an unused wallet and unused identity, verified recent activity, open minting |
| `eligible(holder, identityId) -> bool` | Read-only UI preflight; returns false on missing configuration or dependency failure; recheck transaction failures |
| `pair(tokenId, identityId)` | Current NFT holder who also holds that verified active identity |
| `totalMinted()`, `MAX_SUPPLY()`, `publicMintOpen()` | Supply and opening state |
| `ownerOf(id)`, `balanceOf(holder)`, `Transfer` | Standard NFT ownership; there is no ERC721Enumerable, so index Transfer logs or enumerate IDs 1–totalMinted |
| `tokenURI(id)`, `rarity(id)`, `pairedIdentity(id)`, `isPaired(id)` | On-chain JSON/SVG and pairing; use the boolean to distinguish unpaired from valid identity ID zero |
| `earned(id)` | Lifetime earned IMD, including already claimed, with current pending time applied and cap enforced |
| `claimable(id)` | Current claim amount: earned minus lifetime claimed |
| `claimed(id)` | Lifetime IMD already paid for that NFT |
| `claimReward(id) -> amount` | Current holder only; funds go to the caller |
| `claimRewards(ids) -> amount` | Current holder only; 1–100 IDs, all must have rewards; duplicate or foreign IDs revert the whole batch |
| `depositProceeds(amount)` | Any payer; approve IMD to the collection first; actual receipts split 90/10 |
| `syncProceeds()` | Recognize a direct unsolicited IMD transfer once, using the same split |
| `withdrawCreator()` | Anyone can trigger; recipient always the fixed creator; reverts if credit is zero |
| `checkpoint()` | Anyone; materialize funded elapsed-time accrual and retire capped cohorts |
| `previewRewardState() -> (index, reserve, firstActiveId)` | Read-only equivalent of the next reward checkpoint |
| `rewardReserve()`, `totalAllocated()`, `totalClaimed()`, `creatorCredit()`, `accountedBalance()` | Stored custody ledger; preview to obtain post-accrual reserve |
| `remainingRewardCapacity()` | 2,500 IMD lifetime bound minus allocated and reserved; exact without a checkpoint; zero means further proceeds are credited to the creator |
| `setRewardDuration(seconds)` | Owner, once; 1–3,650 days |
| `openPublicMint()` | Owner, once; requires duration and configured activity reporter |
| `refreshMetadata(id)` | Anyone; emit ERC-4906 cache refresh |

`Transfer`, `Minted`, `Paired`, `ActivityRecorded`, `MetadataUpdate`, `ProceedsDeposited`, `RewardsCheckpointed`, `RewardClaimed`, and `CreatorPaid` support indexing. `RewardsNotConfigured`, `MintClosed`, `SoldOut`, `NotEligible`, `AlreadyClaimed`, `NotHolder`, `InexactPayment`, `NoRewards`, and `InvalidBatch` identify common failure states. Standard OpenZeppelin errors identify allowance, ownership, or ERC-721 receiver failures.

## Activity: SwarmlerActivity

`setReporter(address)` is owner-only and emits `ReporterConfigured`. `reporter()` being zero means **unset**, not a usable default. Production deployment inputs must not contain a invented reporter address. `recordActivity(uint256 identityId, address holder, uint64 lastActive, uint64 score, bool verified)` is reporter-only and uses a Unix timestamp in seconds. It checks identity ownership, rejects zero/future timestamps, and prevents timestamp rollback for the same holder. `verified = false` revokes that record's eligibility.

`status(identityId, holder) -> (active, lastActive, score)` checks current identity ownership and a verified record bound to the supplied holder; an old owner's record does not certify a new owner. `records(identityId)` exposes the record's holder as well. Unset reporter is an explicit error. For a non-active record the returned timestamp/score can describe historical activity; do not display it as current verification. Identity ERC-721 calls fail closed for eligibility. The UI should surface service status rather than claiming that every false value means a user lacks an identity.

## Helper and child hook

`SwarmlerHookDeployer.poolManager()` is the immutable PoolManager given at launch. `hookCreationCodeHash()` commits to the exact bare creation code produced by this build. `initCodeHash(creationCode)` adds the current owner, manager, collection, and token arguments; it and `predict(creationCode, salt)`, which computes the resulting address, revert with `PoolManagerNotDeployed` while the manager address has no code. `deploy(creationCode, salt)` is owner-only and can succeed once. `hook()` is unset until deployment. Listen for `HookDeployed`.

After deployment, the child's `poolKey()` returns the full sorted `(currency0, currency1, fee, tickSpacing, hooks)` tuple; `getHookPermissions()` returns its v4 permission struct. Callback ABIs match the vendored v4.0.0 release exactly and are reserved for the configured PoolManager.

`setFeeTokenPrice(imdPerToken)` is child-owner-only. `quoteFeeTokens(amount)` returns a rounded-up actual IMD cost; it fails if price is unset. `buyFeeTokens(amount, maxImd)` requires approval of IMD to the child hook and sends the acquired LaunchToken to the caller. `forwardFees()` forwards actual held IMD to the collection. Sale and forwarding emit `FeeTokenPriceSet`, `FeeTokensSold`, `FeesForwarded`; liquidity callbacks emit `FeesCollected`. No routing into this hook's pool can be inferred from the ordinary launch-pool deployment.

## Frontend/service boundaries

Services fill actual contract addresses after deployment. They must not expose the owner as the launch factory, invent an activity reporter, confuse the ERC-20 supply with NFT supply, assume a sale price, or identify the launch pool as the optional hook pool. The website/IPFS assignment consumes these ABIs; it does not need to host metadata images, which already reside in on-chain data URIs. Wallet writes should give exact target address, chain, amounts, and any approvals to the user for review.
