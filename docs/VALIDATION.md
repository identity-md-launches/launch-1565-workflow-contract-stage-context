# Local validation record

Validated with Foundry 1.8.4 and the repository-pinned Solidity 0.8.26, using the checked-in optimization and metadata settings. These are builder results, not an independent audit, deployment attestation, or manifest approval.

| Check | Result |
|---|---|
| `forge build` | Passed |
| `forge test` | 43 reported results passed across 8 suites; no failures or skips (revision of 2026-10-13: two capacity tests added, deployer tests reworked for the constructor argument) |
| `forge test --offline --threads 4` with a minimal environment | Passed after the final test-helper change |
| `forge fmt --check` | Passed |
| `python3 scripts/export_abis.py --check` | All five ABI exports match build artifacts; no unresolved library links |
| Fresh copied project, no cache, no `.imd`, no scratch files; `forge build --offline` and `forge test --offline --threads 4` | Passed with only `PATH` supplied in the environment; all production bytecode and ABIs matched the original build |
| Metadata inspection | A generated token URI decoded into valid JSON and SVG XML; activity, rarity, and pairing attributes checked |
| Delivery inspection | All dependencies are ordinary files; no prohibited nested paths, symlinks, environment-dependent tests, broadcasts, FFI, or contributor `launch.json` |

The three stateful invariants are grouped into one reported Foundry result. Each invariant campaign performs 64 runs of 64 randomized actions (4,096 actions), with `fail_on_revert = true` and zero handler reverts. They check collateral conservation, aggregate NFT entitlement against the global ledger, irreversible supply/cap behavior, and that allocated plus reserved rewards never exceed the 2,500 IMD lifetime capacity (the handler's deposits of up to 500 IMD each drive the ledger past that bound within a run). Two fuzz tests each run 256 cases. Time-changing tests read Foundry's simulated clock with `vm.getBlockTimestamp()` to avoid compiler reuse of an earlier timestamp.

The real v4 tests cover permission-salt mining through the delivered script, CREATE2 deployment and ownership, both swap directions in exact-input and exact-output modes, fee collection on add/remove/poke, donations, preservation of LP principal, access control, wrong pools and salts, conversion slippage/rounding, atomic failure, and retryable forwarding. The helper-only empty-chain test confirms application constructors preserve the factory's entire launch supply and scans actual deployed runtime for forbidden escape opcodes.

Final production runtime sizes:

| Contract | Runtime bytes | Constructor arguments |
|---|---:|---:|
| LaunchToken | 1,503 | 0 |
| SwarmlerActivity | 2,084 | 1 |
| Swarmlers | 14,490 | 2 |
| SwarmlerHookDeployer | 1,750 | 4 |
| SwarmlerFeeHook (child only) | 5,318 | 4 |

All are below EIP-170's 24,576-byte bound. The test that retires all 2,500 capped NFTs in one checkpoint checks that the checkpoint itself consumes less than 12 million gas; constructing a sold-out collection inside a test intentionally spans much more work than one production transaction.

Foundry's lint output also flags conservative patterns such as timestamp use for time accrual, intentional receipt equality, the constructor's callback-free creator mint, narrowing fee values after explicit nonnegative checks, and packed concatenation for JSON/init-code assembly. No compiler errors remain. No Slither, Mythril, live transaction, mainnet fork, public IPFS deployment, or independent audit is claimed. See `REVIEW.md` for the launch-pool conflict and privileged-operation assumptions.
