# Swarmlers contracts

This is the contract-stage deliverable for Swarmlers on Ethereum (chain ID 1): the launch-policy ERC-20, the 2,500-item spider-crawler NFT collection, an activity attestation registry, funded holding-time rewards, and a separately deployable Uniswap v4 LP-fee hook. It includes offline dependencies, tests, ABIs, and a local salt miner. Nothing here broadcasts a transaction, publishes a site, or generates `launch.json`.

**Launch-policy conflict requiring a requester decision:** the launch's pool has the protocol's initialization-only guard as its hook and fixed fee beneficiaries (1% of volume to the wallet that paid for the launch, 0.25% to IMD). A v4 hook is part of the immutable pool key, so **no contract in this tree can receive the launch pool's trading fees, and under this policy the launch pool funds 0% of NFT rewards**. The brief's "90% of trading fees" is reachable only by two voluntary routes: the payer deposits what they claim from the launch pool through `depositProceeds` (split 90/10 like every deposit), or liquidity is supplied to the **separate pool** served by `SwarmlerFeeHook`, which routes that pool's realized LP fees 90/10. No launch supply is reserved for that pool. The requester must decide, before the site advertises trading-fee rewards, whether mint-proceeds rewards plus these voluntary routes are acceptable; the contracts cannot settle it and the manifest cannot either. See [review findings](docs/REVIEW.md). Source publication, the manifest, independent review, attestation, admission, deployment, and the IPFS frontend are later service responsibilities.

## Build and check

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abis.py --check
```

Foundry pins Solidity **0.8.26**, Cancun, optimizer 200 runs, `via_ir = true`, and `bytecode_hash = "none"`. All imported sources are ordinary files under `lib/`; no network, submodules, FFI, filesystem permissions, environment variables, or keys are needed by tests. See [dependency versions](docs/DEPENDENCIES.md) and [local validation](docs/VALIDATION.md). The verifier supplies the pinned compiler; no compiler binary is included.

The tests include actual v4 `PoolManager` execution, mined CREATE2 deployment, mint supply limits, permission failures, stale activity, identity transfers and duplicate claims, token and receiver failures, reentrancy attempts, principal conservation, time-weighted rewards, capped cohort retirement, a full 2,500-NFT checkpoint, fuzz cases, and stateful accounting invariants. Local tests do not substitute for the subsequent independent review.

## Contracts and constructor parameters

| Contract | Constructor arguments, in order | Role |
|---|---|---|
| `LaunchToken` | None | Plain ERC-20, name `Swarmlers`, symbol `SWARMLER`, 18 decimals, 1,000,000,000 tokens minted once to its deployer |
| `SwarmlerActivity` | `address initialOwner = $owner` | Owner configures the trusted activity reporter |
| `Swarmlers` | `address initialOwner = $owner`, `address activityRegistry = $contract:SwarmlerActivity` | ERC-721 minting, metadata, pairing, IMD custody and rewards |
| `SwarmlerHookDeployer` | `address initialOwner = $owner`, `address nftCollection = $contract:Swarmlers`, `address token = $token`, `address manager = 0x000000000004444c5dc75cB358380D2e3dE08A90` | Exact-bytecode CREATE2 child deployment against the Ethereum Uniswap v4 PoolManager |
| `SwarmlerFeeHook` | `address initialOwner`, `address manager`, `address nftCollection`, `address token` | Child created by `SwarmlerHookDeployer`; **do not list it as a direct launch application** |

The manifest assignment should list the three application contracts in the order shown after `LaunchToken`. All constructors are nonpayable, take only static address arguments, and make no external calls. The explicit launch owner resolves to **0x3d6a89c8751a45dd577a4c1f3b34e71c58236193**. The factory and transaction origin receive no application authority. Ownership transfers require acceptance; renouncing ownership is disabled so missing settings remain recoverable.

The deployer's fourth argument is the public Uniswap v4 PoolManager on Ethereum, `0x000000000004444c5dc75cB358380D2e3dE08A90`, taken from the pinned chain reference and confirmed read-only on chain id 1 during this assignment (it has code and answers `owner()`). The constructor stores it without probing for code, because launch constructors run on an empty chain; `initCodeHash`, `predict` and `deploy` refuse to run until that address has code. It is immutable: a wrong value in the manifest cannot be corrected after launch, so the manifest and the final review must check it against the chain reference.

Fixed addresses from the brief:

- IMD payment/reward asset: `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals.
- Identity MD ERC-721: `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d`.
- Creator recipient: `0xd2B259c56B252f7be70eaD6d28cD3Cc65aEe8c03`.

The ERC-20 and NFTs are distinct assets. The launch ERC-20 has no mint, owner, pause, blocklist, transfer tax, or upgrade path. The launch factory allocates its fixed supply: 10% to the launch's MerkleDistributor, 88% to launch liquidity, and 2% to the payer or policy treasury. The collection, activity registry, hook deployer, and child hook receive **none of that ERC-20 supply at launch**. The 25 creator NFTs are part of the separate 2,500-NFT supply.

The manifest's launch pool values are paired currency IMD, fee **12500 (1.25%)**, tick spacing **60**, and legacy initial-price field `"79228162514264337593543950336"`. The service derives the actual launch opening price from the policy's 2,500 IMD opening market cap and token ordering. The launch's fee allocation remains 1% of trading volume to the payer and 0.25% to IMD. Application code does not add a fee to this pool.

## Minting, identity and artwork

The `Swarmlers` constructor mints IDs 1–25 directly to the creator. It uses `_mint` without a recipient callback to satisfy empty-chain constructor execution. The creator's supplied wallet must be able to manage ERC-721 assets. Public minting starts closed and the owner opens it once prerequisites are set. There is no later mint pause and no reserve beyond those 25 tokens.

- `mint()` charges the caller exactly **0.25 IMD** (`250000000000000000` minor units), using ERC-20 allowance. Anyone may pay, including an eligible identity holder. ETH is not accepted.
- `freeClaim(identityId)` requires current ownership of that Identity MD NFT, a reporter-verified activity record bound to that same holder, and activity within the preceding **7 days**, inclusive. There is **one free NFT per wallet and per identity ID for the collection's lifetime**. Neither transferring the identity nor transferring the Swarmler resets either limit. Identity ID zero is supported.
- Mint IDs are sequential; creators, paid mints, and free claims share the 2,500 cap. Public mints use safe receiver callbacks and revert atomically if the recipient rejects them.
- An NFT holder can call `pair(tokenId, identityId)` using their currently owned, verified active identity. Free claims pair automatically. Pairing an identity to multiple already-owned Swarmlers is permitted; it grants no additional free claims or rewards.

Artwork and JSON metadata are generated entirely on chain as base64 data URIs. Each spider has its own ID, color, body dimensions and unique 12-bit abdomen pattern; metadata contains the ID, activity status, last activity, score, identity association, and rarity. The five rarity counts over all 2,500 IDs are Common 1,500; Uncommon 625; Rare 250; Epic 100; Legendary 25. The tier uses a fixed permutation of the ID. **Rarity is public and predictable, not random**, and has no effect on reward rates. Buyers can inspect the next ID; transaction ordering may determine who receives a particular rarity.

`tokenURI()` reflects current activity and identity ownership on every read. A transfer carries the pairing ID but does not carry the former owner's activity attestation. Metadata remains readable with a dormant state when the activity dependency fails. The collection implements ERC-4906; pairing and transfers emit `MetadataUpdate`, and anyone may call `refreshMetadata(id)` after a reporter update or natural expiration. Indexers must also observe `ActivityRecorded` and refresh on expiry; passage of time cannot emit an event by itself.

## Rewards and custody

Both mint proceeds and IMD deposited through `depositProceeds(amount)` enter the same ledger. **90%** funds NFT rewards. **10%** is credited exclusively to the fixed creator recipient; anyone may trigger `withdrawCreator()` to send it there. Creator payout is a separate pull operation, so it is not necessarily in the mint transaction. Creator share rounds down to the nearest IMD wei; sub-10-wei dust goes to rewards.

The owner chooses `rewardDuration` once before opening. It is the approximate number of **funded seconds** needed for an NFT to earn 1 IMD; permitted durations are 1–3,650 days. No business duration was supplied, so it is deliberately an owner-settable launch setting, not a fabricated constructor value. The actual integer rate is `floor(1e18 / duration)` wei per NFT per second; reaching the cap can take up to one additional second.

Every uncapped NFT receives that same rate for each funded second that it exists. Earlier mints therefore earn for more seconds than later mints. Funding is checkpointed before new money or a new NFT enters the ledger: an unfunded historical period never becomes a retroactive liability. If the reserve cannot fund the elapsed period, the global index advances only as far as the reserve can afford. Fewer than the active NFT count in reward wei may remain as rounding dust until another deposit. Rewards are denominated and paid in **actual IMD**, so the 1 IMD equivalent cap requires no price oracle.

Accrued, unclaimed rewards **travel with the NFT**. Only its current holder can claim; approved NFT operators cannot. Transfers, claims, pairing, identity changes, and activity scores do not reset the immutable **1 IMD lifetime cap**. Each NFT stops accruing at its cap even if nobody calls its claim function. Free and creator NFTs participate at the same rate as paid NFTs. Activity is a gate for free minting and metadata, not a continuing requirement for reward claims.

The ordered mint cohorts allow cap retirement without touching every NFT on normal actions. A worst-case checkpoint visits at most 2,500 IDs. The accounting identities are:

```
accountedBalance = rewardReserve + totalAllocated - totalClaimed + creatorCredit
IMD received = IMD still held + totalClaimed + totalCreatorPaid
```

Unsolicited IMD transfers are recognized through permissionless `syncProceeds()` and receive the same 90/10 split. There is no administrator withdrawal of reward collateral.

**Lifetime capacity.** The collection can ever owe at most 2,500 × 1 IMD = **2,500 IMD** of rewards. `remainingRewardCapacity()` is that bound minus what is already allocated or held in reserve. Every deposit, mint payment and synced transfer credits the reward share only up to that capacity; **whatever exceeds it is credited to the creator** in the same transaction, and `ProceedsDeposited` reports the actual split. So once the reserve can already fund every possible NFT, or once every NFT has reached its cap, further proceeds (including fees forwarded by the hook) go entirely to the creator instead of into a reserve nobody could claim. The reserve therefore never holds more than the NFTs can still earn. Accidental unrelated tokens and final rounding dust still have no recovery path. An NFT is never burned by this collection. There is no promised yield and claims cannot spend unreceived or anticipated fees. Failed token payments revert without consuming the claim or creator credit.

A checkpoint retires capped mint cohorts one distinct cohort at a time. In the worst case (every NFT minted in a distinct reward state and all capping at once) one checkpoint costs about 8.3 million gas, well inside a block but borne by whoever acts first. Operators should run a keeper `checkpoint()` after large funded periods so ordinary mints and claims do not carry it; see [operations](docs/OPERATIONS.md).

## Hook behavior and fee conversion

For a separate compatible pool, `SwarmlerFeeHook.poolKey()` returns sorted LaunchToken/IMD currencies, fee **1.25%**, tick spacing 60, and itself as hook. Its exact low-14-bit permissions are **0x2503**: before-initialize, after-add-liquidity, after-remove-liquidity, and the two corresponding return-delta permissions. The constructor enforces these address bits. Every callback verifies both the PoolManager caller and the entire pool key. Only the hook owner can initiate pool initialization directly through the manager.

The hook takes **realized LP fees**, never position principal, when liquidity is added, removed, or poked with zero liquidity delta. It returns exactly that fee delta to v4 accounting. LPs who join this pool consent to surrender all their LP fees. The hook adds no swap surcharge and does not intercept protocol fees or other pools' fees. Donations count as fees only when backed by actual tokens; unit and integration tests check this with the real PoolManager.

Fees remain in the hook until forwarded. Anyone calls `forwardFees()` to deposit all held IMD into the collection, producing the 90/10 split. It approves only that exact amount and clears the allowance after use. Failure leaves funds and counters unchanged for retry.

LaunchToken-side fees are **not treated as IMD**. The owner first sets an explicit IMD ask with `setFeeTokenPrice(imdPerToken)`, measured in IMD wei per `1e18` LaunchToken units. Buyers approve IMD to the hook and call `buyFeeTokens(amount, maxImd)`. The quote rounds up and `maxImd` protects against a changed ask. The hook retains the received IMD for permissionless forwarding. No AMM spot price, fabricated exchange rate, arbitrary router, or guessed oracle is used. Until the owner supplies a price, the sale reverts with `PriceNotConfigured`; until a buyer purchases the fees, those tokens generate no rewards. The owner is trusted to choose a fair price and can otherwise sell fee inventory too cheaply, including to themselves. A fixed ask on a volatile asset fills only while it is at or below market, and a pending ask increase can be front-run at the old ask, so the ledger realizes at most the ask the owner set; the loss is bounded to the token-side inventory the hook holds at that moment. The owner should set the ask close to market, raise it before inventory grows, and treat `FeeTokensSold` as a signal to review it.

## After launch

The owner, or an operator explicitly appointed by the owner, must perform these actions. The launch factory makes no initialization calls.

1. Call `SwarmlerActivity.setReporter(address)`. Supply the real Identity MD integration/backend operator's address, obtained from the owner-controlled verified-activity service. The reporter can be a wallet or a contract. It must independently verify agent activity and call `recordActivity(identityId, currentHolder, lastActive, score, verified)`. Records may be refreshed or revoked. The registry checks identity ownership and disallows future or backwards timestamps for the same holder, but it cannot independently prove off-chain work. No fake reporter, default key, or placeholder address is deployed.
2. Call `Swarmlers.setRewardDuration(seconds)` with the owner's chosen release schedule. This is one-time and cannot be changed. Then call `openPublicMint()`. It requires a reporter and reward duration, and the 25 creator tokens already exist. Payments/deposits before reward configuration fail clearly.
3. Decide the launch-pool question before representing trading rewards as live: the launch pool pays its fees to the payer and IMD and cannot be repurposed by these contracts. If the payer wants the brief's split honoured for those fees, they claim them and call `depositProceeds` with the amount; the ledger applies 90/10. A separate hook pool requires its own liquidity; none is reserved out of the policy supply.
4. Confirm that `SwarmlerHookDeployer.poolManager()` is the Ethereum Uniswap v4 PoolManager, `0x000000000004444c5dc75cB358380D2e3dE08A90`, on chain id 1. It was set by the manifest at launch and is immutable; the helper refuses to deploy a child while that address has no code.
5. Obtain the exact `SwarmlerFeeHook` creation bytecode from the pinned build, compare its hash with `hookCreationCodeHash()`, and get `initCodeHash(creationCode)` from the deployer. Run the local [salt miner](docs/OPERATIONS.md). The owner calls `deploy(creationCode, salt)` on the helper. It rejects arbitrary bytecode, incorrect permission salts, nonowners, and a second deployment. Changing the deployer owner changes the init-code hash and requires re-mining.
6. The child hook owner initializes its exact `poolKey()` through PoolManager at a consciously selected price, supplies liquidity through suitable position management tooling, and sets the fee-token sale price based on an independently evaluated IMD quote. This is an owner transaction after launch, not a call made by this assignment or the launch factory. The manifest's legacy one-to-one price is not an instruction to initialize this separate pool at that price.
7. LP position operators periodically poke/modify positions to realize fees; any keeper forwards IMD, buyers convert token-side inventory, and anyone withdraws the creator share. LP fee harvesting requires the position's actual owner/operator; the hook cannot unilaterally harvest every external position. Monitor the activity reporter, funding reserve, remaining reward capacity, fee inventory, sale price, cap status and payout failures, and run a keeper `checkpoint()` after large funded periods.

## Integration handoff

See [ABI/function guide](docs/ABI.md), [operations](docs/OPERATIONS.md), and exported ABI arrays in [docs/abi](docs/abi). The frontend service should show mint cost and balance, identity claim eligibility and attestation age, remaining NFT supply, on-chain artwork, pairing instructions, current-owner reward entitlement, lifetime paid amount/cap, available backing, remaining reward capacity, and whether a fee pool is actually configured. It must not advertise launch-pool trading fees as a reward source unless the requester has decided to route them through `depositProceeds`. It must distinguish the ERC-20 from the NFTs and the policy launch pool from the optional separate hook pool. Use the exact deployed pool key from service handoff. Deployment addresses and a public IPFS website URL do not exist in this source-only assignment and must not be invented.
