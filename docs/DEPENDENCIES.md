# Offline source dependencies

All dependencies are vendored as ordinary source files, never submodules. Exact upstream versions:

| Directory | Upstream | Version / commit | Used for |
|---|---|---|---|
| `lib/openzeppelin-contracts` | https://github.com/OpenZeppelin/openzeppelin-contracts | v5.1.0 / `69c8def5f222ff96f2b5beff05dfba996368aa79` | ERC-20, ERC-721, two-step ownership, SafeERC20, reentrancy guard, metadata utilities |
| `lib/forge-std` | https://github.com/foundry-rs/forge-std | v1.9.7 / `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | Test framework and cheatcode interfaces |
| `lib/v4-core` | https://github.com/Uniswap/v4-core | v4.0.0 / `e50237c43811bd9b526eff40f26772152a42daba` | Hook interfaces/types, real PoolManager integration tests |
| `lib/solmate` | https://github.com/transmissions11/solmate | `4b47a19038b798b4a33d9749d25e570443520647` (v4-core's pinned dependency) | PoolManager test dependency |

Retained source files are unmodified upstream code. License files accompany each package, including v4's `licenses/MIT_LICENSE` and `licenses/BUSL_LICENSE`. Per-file SPDX declarations identify the applicable license. The production hook imports the MIT v4 interfaces/utilities; the PoolManager implementation is used only in tests and is not a launch application.

No package manager, downloads, remapping outside the repository, compiler binaries, or runtime RPC are required for build/test. Source documents and tests use the v4.0.0 `IPoolManager.ModifyLiquidityParams` API, not an unpinned later API.
