# Builder findings and independent-review handoff

These are implementation notes from the source-producing contributor, **not an independent audit or approval of a manifest**. The manifest step and final independent contributor must inspect accepted source, exact constructor arguments, and policy together. No `launch.json` is authored here.

## R1 — High: launch pool cannot provide the requested fee routing

**Evidence:** the supplied launch policy assigns the launch pool's hook to the factory's initialization guard and assigns its 1.25% fee to the payer (1%) and IMD (0.25%). A Uniswap v4 pool's hook is part of its immutable pool key. The launch also does not mine application salts for hook permission bits. No collection function can claim those third-party fees, and no launch application here owns the launch LP allocation.

**Impact:** mint rewards work once configured, but a statement that 90% of the *policy launch pool's* trading fees funds NFTs would be false. `SwarmlerFeeHook` implements that split for realized LP fees in a separate, explicitly initialized pool, after token-side fees are exchanged for actual IMD. Uniswap protocol fees, if any, remain outside its authority. Thus this alternative must not be presented as 90% of every fee on the launch pool.

**Disposition:** retained as a concrete policy/application conflict for independent review. The deployer helper solves permission-addressed child deployment; it does not change policy, grant LP rights, initialize a pool, or reserve liquidity. Launch services and the owner must settle the intended pool integration before advertising automatic trading rewards. Do not silently change manifest fee, guard, supply allocation, or beneficiaries to disguise this conflict.

## R2 — Required operations: activity reporting and reward timing

The supplied brief gives the Identity MD NFT contract, but not a cryptographic source of recent off-chain activity or an operator. `SwarmlerActivity` checks that exact identity contract's `ownerOf` and requires an owner-appointed reporter's verified, recent record. The reporter is unset at deployment and must be configured. A compromised owner/reporter can falsely certify activity and authorize a free claim for an actual identity owner; neither can mint beyond the 2,500 cap, duplicate a used identity/wallet claim, or directly drain rewards. The seven-day activity window and one-free-claim-per-wallet-and-identity rule are explicit implementation assumptions.

The reward release duration was unspecified. It is a one-time owner setting, bounded to 1–3,650 days, that is required before opening or accepting proceeds. Review the chosen duration in the operational handoff. The sample test duration of 30 days is **test configuration**, not a hidden production default.

## R3 — Medium trust assumption: fee conversion price

The child hook owner sets a public ask for LaunchToken-side fee inventory in IMD. An underpriced ask can transfer fee value to a buyer, including the owner. `maxImd` protects the buyer against an adverse price increase, not reward holders against owner underpricing. This is an explicit owner trust responsibility, used instead of inventing an oracle or treating the two assets as equal. Unconverted tokens create no IMD entitlement. Review the sale policy and keeper process before pool use.

## R4 — Liveness and economic assumptions

- Reward funding depends on received mint proceeds, optional deposits, and fees actually harvested/converted/forwarded. There is no guarantee of reaching 1 IMD per NFT.
- LP fees realize when the position owner/operator modifies or pokes its position; the hook does not force other LPs to harvest. Any keeper may forward held IMD and trigger the fixed creator payout.
- Unclaimed entitlement and the permanent cap follow each NFT to the buyer. Sellers should claim before selling if they intend to retain earned rewards; a buyer can acquire the NFT and immediately claim its existing entitlement. Transfers never manufacture entitlement.
- Capped NFTs cease consuming funds without needing to claim. Residual or excess funds after all NFTs cap cannot be swept by the owner. Accidental unrelated tokens cannot be rescued. This favors custody restrictions over recoverability and must be disclosed.
- Creator payouts are pull-based and permissionless to trigger, with a fixed recipient. Payment failures roll back credit consumption. There is no unrestricted rescue, upgrade, arbitrary call, delegatecall, burn or emergency withdrawal.
- Rarity is deterministic and visible before minting; it is not suitable as verifiable randomness. It has no effect on rewards. Sequential mints can be reordered by block builders.
- Timestamp differences determine accrual and activity freshness; small validator timing variation is possible. Timestamps are never used to select winners or assign hidden rarity.
- Administrators cannot pause public minting once opened or change reward duration after setting it. This also limits incident-response options. They can rotate reporters and transfer ownership in two steps.

## Validation scope

Local checks use the pinned compiler, the real vendored v4 PoolManager, local IMD and Identity MD test doubles, fuzz cases, strict stateful invariants, and an application-runtime opcode scan. They do not use a mainnet fork or rely on network at test time. Read-only RPC probes confirmed the supplied identity reports ERC-721 support and name `identity.md`, supplied IMD reports symbol `IMD` and 18 decimals, and the referenced Ethereum PoolManager has runtime code. These probes do not establish the services' future availability or certify arbitrary code at those addresses.

No Slither/Mythril result, mainnet transaction, explorer verification, IPFS publication, signed attestation, or independent audit is claimed. Those service artifacts are not prerequisites for this bounded source assignment. Frontend and deployment work must use accepted artifacts and actual deployment addresses.
