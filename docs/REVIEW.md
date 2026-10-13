# Builder findings and independent-review handoff

These are implementation notes from the source-producing contributor, **not an independent audit or approval of a manifest**. The manifest step and final independent contributor must inspect accepted source, exact constructor arguments, and policy together. No `launch.json` is authored here.

## R1 — High: launch pool cannot provide the requested fee routing

**Evidence:** the supplied launch policy assigns the launch pool's hook to the factory's initialization guard and assigns its 1.25% fee to the payer (1%) and IMD (0.25%). A Uniswap v4 pool's hook is part of its immutable pool key. The launch also does not mine application salts for hook permission bits. No collection function can claim those third-party fees, and no launch application here owns the launch LP allocation.

**Impact:** mint rewards work once configured, but a statement that 90% of the *policy launch pool's* trading fees funds NFTs would be false. `SwarmlerFeeHook` implements that split for realized LP fees in a separate, explicitly initialized pool, after token-side fees are exchanged for actual IMD. Uniswap protocol fees, if any, remain outside its authority. Thus this alternative must not be presented as 90% of every fee on the launch pool.

**Disposition:** retained as a concrete policy/application conflict for independent review; the independent reviewer confirmed it on 2026-10-13 and it is not fixable in source. The deployer helper solves permission-addressed child deployment; it does not change policy, grant LP rights, initialize a pool, or reserve liquidity. The pinned launch terms state that the pool's fee beneficiaries are decided by the launch and are not an open question, so the only routes to the brief's split are voluntary: the payer deposits claimed launch-pool fees through `depositProceeds`, or liquidity is supplied to the separate hook pool. **The requester must decide whether that is acceptable before the site advertises trading-fee rewards.** Do not silently change manifest fee, guard, supply allocation, or beneficiaries to disguise this conflict.

## R2 — Required operations: activity reporting and reward timing

The supplied brief gives the Identity MD NFT contract, but not a cryptographic source of recent off-chain activity or an operator. `SwarmlerActivity` checks that exact identity contract's `ownerOf` and requires an owner-appointed reporter's verified, recent record. The reporter is unset at deployment and must be configured. A compromised owner/reporter can falsely certify activity and authorize a free claim for an actual identity owner; neither can mint beyond the 2,500 cap, duplicate a used identity/wallet claim, or directly drain rewards. The seven-day activity window and one-free-claim-per-wallet-and-identity rule are explicit implementation assumptions.

The reward release duration was unspecified. It is a one-time owner setting, bounded to 1–3,650 days, that is required before opening or accepting proceeds. Review the chosen duration in the operational handoff. The sample test duration of 30 days is **test configuration**, not a hidden production default.

## R3 — Medium trust assumption: fee conversion price

The child hook owner sets a public ask for LaunchToken-side fee inventory in IMD. An underpriced ask can transfer fee value to a buyer, including the owner. `maxImd` protects the buyer against an adverse price increase, not reward holders against owner underpricing. This is an explicit owner trust responsibility, used instead of inventing an oracle or treating the two assets as equal. Unconverted tokens create no IMD entitlement. Review the sale policy and keeper process before pool use.

The independent review added the unprivileged amplifier: a fixed ask fills only while at or below market, and a pending ask increase can be front-run at the stale ask, so the ledger realizes min(ask, market) on whatever inventory the hook holds. That loss is the same as the ask having been below market before the raise; the raise does not create new exposure. It is bounded to the token-side inventory held at the moment, never touches IMD-side fees or the collection's reserve, and is left as designed: a rising-only floor, a decrease delay or a per-block fill cap each add state and still leave the owner trusted for the number itself. Operational mitigation: set the ask near market, raise it before inventory grows, and keep inventory small by converting often.

## R4 — Liveness and economic assumptions

- Reward funding depends on received mint proceeds, optional deposits, and fees actually harvested/converted/forwarded. There is no guarantee of reaching 1 IMD per NFT.
- LP fees realize when the position owner/operator modifies or pokes its position; the hook does not force other LPs to harvest. Any keeper may forward held IMD and trigger the fixed creator payout.
- Unclaimed entitlement and the permanent cap follow each NFT to the buyer. Sellers should claim before selling if they intend to retain earned rewards; a buyer can acquire the NFT and immediately claim its existing entitlement. Transfers never manufacture entitlement.
- Capped NFTs cease consuming funds without needing to claim. The reserve never exceeds what the NFTs can still earn (see R5), so nothing is left to sweep after all NFTs cap. Accidental unrelated tokens cannot be rescued. This favors custody restrictions over recoverability and must be disclosed.
- A checkpoint retires capped cohorts one distinct cohort at a time; the worst case (2,475 distinct cohorts capping at once) measured about 8.3 million gas in one call, inside the block limit and borne by the first caller. Liveness holds; operators should budget a keeper `checkpoint()` after large funded periods so a mint or claim does not pay it.

## R5 — Fixed on revision: funding beyond lifetime capacity

**Finding (independent review, 2026-10-13):** `_accountProceeds` credited 90% of every deposit to the reserve regardless of how much the NFTs could still earn. Once all 2,500 NFTs reached their 1 IMD cap, fees forwarded by the hook or any further deposit were credited to a reserve nobody could claim and no function could move. Reproduced locally: 765.875 IMD stranded after a 3,000 IMD deposit onto a sold-out, fully capped collection.

**Fix:** `remainingRewardCapacity()` is 2,500 × 1 IMD minus what is allocated or reserved; the reward share of any deposit is credited only up to it and the rest goes to `creatorCredit` in the same transaction. The checkpoint moves reserve into allocation without changing their sum, so the bound is exact. Tests cover the arithmetic of the split, the sold-out fully capped case, and the shared solvency check asserts `totalAllocated + rewardReserve <= 2,500 IMD` in every unit, fuzz and invariant run. Design choice to review: the overflow goes to the brief's other named beneficiary, the creator, rather than refusing deposits, because a refusal would leave fees stuck in the hook forever.

## R6 — Fixed on revision: PoolManager as a constructor argument

**Finding (independent review, 2026-10-13):** the helper left the public Ethereum PoolManager to a post-launch owner setter, so the child's init-code hash, salt and pool key depended on an unattested owner transaction. **Fix:** the deployer takes the PoolManager as its fourth, immutable constructor argument, stored without a code probe so the launch's empty-chain constructor check passes; `initCodeHash`, `predict` and `deploy` refuse to run while that address has no code. The setter is gone. The manifest fills it with `0x000000000004444c5dc75cB358380D2e3dE08A90`, which the final review must check against the chain reference, since it cannot be changed after launch.
- Creator payouts are pull-based and permissionless to trigger, with a fixed recipient. Payment failures roll back credit consumption. There is no unrestricted rescue, upgrade, arbitrary call, delegatecall, burn or emergency withdrawal.
- Rarity is deterministic and visible before minting; it is not suitable as verifiable randomness. It has no effect on rewards. Sequential mints can be reordered by block builders.
- Timestamp differences determine accrual and activity freshness; small validator timing variation is possible. Timestamps are never used to select winners or assign hidden rarity.
- Administrators cannot pause public minting once opened or change reward duration after setting it. This also limits incident-response options. They can rotate reporters and transfer ownership in two steps.

## Validation scope

Local checks use the pinned compiler, the real vendored v4 PoolManager, local IMD and Identity MD test doubles, fuzz cases, strict stateful invariants, and an application-runtime opcode scan. They do not use a mainnet fork or rely on network at test time. Read-only RPC probes confirmed the supplied identity reports ERC-721 support and name `identity.md`, supplied IMD reports symbol `IMD` and 18 decimals, and the referenced Ethereum PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90` has runtime code and answers `owner()` on chain id 1 (re-checked on 2026-10-13). These probes do not establish the services' future availability or certify arbitrary code at those addresses.

No Slither/Mythril result, mainnet transaction, explorer verification, IPFS publication, signed attestation, or independent audit is claimed. Those service artifacts are not prerequisites for this bounded source assignment. Frontend and deployment work must use accepted artifacts and actual deployment addresses.
