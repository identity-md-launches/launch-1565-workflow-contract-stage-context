# Operations and artifact handoff

## Launch service inputs

The manifest producer describes the accepted source with `LaunchToken`, then `SwarmlerActivity($owner)`, `Swarmlers($owner, $contract:SwarmlerActivity)`, and `SwarmlerHookDeployer($owner, $contract:Swarmlers, $token)`. It does not list libraries, test harnesses, `MineHookSalt`, the child hook, or protocol-owned PoolInitializationGuard/MerkleDistributor as contributor applications. Do not deploy the child hook through the project factory: a random factory salt will not produce its required permission bits.

All child ownership, references and immutable values must be included in independent review even though the child is deployed later. Source/signed artifact linkage, admission and publishing are service responsibilities. The [policy conflict](REVIEW.md#r1--high-launch-pool-cannot-provide-the-requested-fee-routing) remains a substantive finding rather than an omitted manifest field.

## Salt mining without a wallet

`script/MineHookSalt.s.sol` accepts a deployer address, **full init-code hash**, starting counter and bounded number of attempts. It is a pure computation and contains no broadcast, environment access, RPC, or filesystem calls. Use it only after the deployed helper's owner and PoolManager have been set to their real values. Get the bare child creation code from `out/SwarmlerFeeHook.sol/SwarmlerFeeHook.json` at `bytecode.object`, verify its hash against `hookCreationCodeHash()`, and call the helper's `initCodeHash(creationCode)` for the full hash.

The local invocation is:

```text
forge script script/MineHookSalt.s.sol:MineHookSalt \
  --sig 'run(address,bytes32,uint256,uint256)' \
  <actual-helper-address> <full-init-code-hash> <starting-counter> <attempts>
```

These are command argument descriptions, not deployable placeholder addresses. For example, a search budget of 1,000,000 attempts is allowed. If it exhausts, start the next search at `starting-counter + attempts`. Expected work is about 16,384 hashes. Do not enable broadcasting for this script. Its returned address must match the helper's `predict(creationCode, salt)` and have `uint160(address) & 0x3fff == 0x2503`. Hook tests run this exact miner and deploy the resulting code with CREATE2.

The owner later submits `deploy(creationCode, salt)` through their normal wallet process. The helper checks the bare-code hash and constructs arguments itself; it cannot be used to deploy arbitrary code or a hook with a stolen owner. A change to compiler settings, source, manager or current owner invalidates an earlier full hash/salt. There is no key or RPC secret to put in repository configuration.

## Monitoring and recovery

- Maintain the actual reporter and verify off-chain activity before submitting records. Rotate a compromised reporter with the owner; ownership is two-step. Reporter rotation does not erase historical records, which remain eligible until revoked, expired, or invalidated by identity ownership change.
- Configure the release duration before accepting deposits/opening mint. The setting is permanent. Creator NFT ownership is already established in the constructor.
- For the separate pool, initialize only the exact key reported by the child and choose the opening price deliberately. Position operators supply their own bought/deposited tokens; no launch supply is preallocated to the application. LP principal remains theirs while LP fees are surrendered.
- Realize LP fees through the position owner/operator's tooling. Convert LaunchToken inventory at an owner-reviewed IMD ask, forward actual IMD, and trigger creator withdrawals. The hook can remain live while activity reporting is unavailable: fee collection does not call the reporter or collection.
- Monitor `accountedBalance` against collection IMD balance; a positive difference is an unrecognized transfer, while a deficit indicates a violated payment-token assumption. IMD is assumed to be the specified plain, non-rebasing, 18-decimal token. Receipts with transfer taxes are rejected. There is no reward rescue function.
- Token failures leave mint/payment/claim operations atomic. Retry payout/forwarding after the external asset resumes normal behavior. NFTs with no current claimable amount cause batch claims to revert, so filter batches with current reads. A reward claim just before a sale changes what the buyer inherits.
- `tokenURI` requires no external web server. Marketplaces may cache it; call `refreshMetadata` and index activity/transfer events. Natural seven-day expiry also requires a scheduled frontend refresh.

The deployment services publish source, verify deployed artifacts, and provide actual addresses and pool keys. The frontend service builds the website and publishes the public IPFS URL after those addresses exist. This contract contribution neither signs transactions nor operates a funded wallet.
