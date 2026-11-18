# AegisDeleverage

Autonomous cross-chain stop-loss and cascading deleverage vault built on **`Reactive-Network/reactive-lib-omni`** for the **Reactive Omni Buildathon** (Track 1: *Every Second Counts*).

- **Live Web Console:** https://dev-shiki.github.io/aegis-deleverage/
- **Repository:** https://github.com/dev-shiki/aegis-deleverage

## Architecture

1. **Origin (`src/PriceOracle.sol` on Base Sepolia `84532`)**
   - Emits `PriceUpdated(address indexed asset, uint256 oldPriceE8, uint256 newPriceE8, uint256 timestamp)`.
2. **Reactive Omni Brain (`src/AegisDeleverage.sol` on Reactive Lasna `5318007`)**
   - Inherits `AbstractReactive` (`SYSTEM = 0x8888888888888888888888888888888888888888`), subscribes to `GuardConfigured` and `PriceUpdated`, and dispatches cross-chain callbacks via `SYSTEM.requestCallbackV_1_0` under `onlySystem`.
   - Tracks `triggersDispatched`, enforces per-user `lastTriggeredBlock` deduplication, and supports arbitrary `_originChainId -> _destinationChainId` routing (e.g., Base Sepolia `84532` or Unichain Sepolia `1301`).
3. **Destination (`src/ProtectedVault.sol` on Base Sepolia `84532`)**
   - Inherits `AbstractCallback` bound to the Base Sepolia Omni Callback Proxy (`0x476F44b11F5C942c58f4c8E3d0300E5710743585`).
   - Enforces `onlyServiceProvider`, `callbackSender` verification, `nonReentrant`, configurable `cooldownSeconds`, `MAX_REPAY_BPS` (`50%`), `MAX_DAILY_PROTECTIONS` (`5/day`), and `paused` circuit breaker.
   - Separates `totalUserCollateralWei` from `callbackGasReserveWei()` so user collateral and Omni `AbstractPayer` gas reserves never mix.

## Deployed Contracts (Reactive Omni)

| Component | Network | Address |
| --- | --- | --- |
| `PriceOracle` | Base Sepolia (`84532`) | [`0x06Df840a5aE025A8d86Dde667E02E7cff0cFf4c4`](https://sepolia.basescan.org/address/0x06Df840a5aE025A8d86Dde667E02E7cff0cFf4c4) |
| `ProtectedVault` | Base Sepolia (`84532`) | [`0x8AeD78c80024C2C5d8E90F346B87298174CeBcce`](https://sepolia.basescan.org/address/0x8AeD78c80024C2C5d8E90F346B87298174CeBcce) |
| `AegisDeleverage` | Reactive Lasna (`5318007`) | [`0x5dee49560FcE0a1BC26EBb6591F58B7A2aF313F1`](https://lasna.reactscan.net/address/0x5dee49560FcE0a1BC26EBb6591F58B7A2aF313F1) |
| Omni Callback Proxy | Base Sepolia (`84532`) | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` |
| Omni System Contract | Reactive Lasna (`5318007`) | `0x8888888888888888888888888888888888888888` |

## Measured End-to-End Omni Loop Latency (`latency.csv`)

Three consecutive crash triggers (`$1,900 -> $1,750 -> $1,600`) reduced vault debt from `$3.00` to `$1.265625` (`3` cascading `25%` deleverages) with **`2.33s` average end-to-end latency**:

| Run | Trigger Price | Origin `PriceUpdated` Tx (Block) | Callback `ProtectionExecuted` Tx (Block) | Block Delta | Wall Latency |
| --- | --- | --- | --- | --- | --- |
| 1 | `$1,900` | [`0xa7f55f1a...049e8c93`](https://sepolia.basescan.org/tx/0xa7f55f1a5548445c0e6323cfb9d1948ff7039bece41f850c85b34218049e8c93) (`#60528253`) | [`0x2b360778...38a44037`](https://sepolia.basescan.org/tx/0x2b36077887ec9a78282f8796860f8f852dc4b12d11682041ec2b806838a44037) (`#60528263`) | `+10` | **`2s`** |
| 2 | `$1,750` | [`0xae503812...861cba4f`](https://sepolia.basescan.org/tx/0xae503812ea7c0056898a55a6177128e53a4391bc2efa77a041068a76861cba4f) (`#60529380`) | [`0x2f52e0d7...443a83aa`](https://sepolia.basescan.org/tx/0x2f52e0d754e79003d46ccd76a49026bef1a0394f2007fafe09cb779c443a83aa) (`#60529392`) | `+12` | **`3s`** |
| 3 | `$1,600` | [`0x543ffffe...74838fa9`](https://sepolia.basescan.org/tx/0x543ffffee8683bee3bc93166a8c3d997bac4812e8b115c2c62ece31d74838fa9) (`#60529442`) | [`0x057ce08b...030ac922`](https://sepolia.basescan.org/tx/0x057ce08b8321f278715099788fc3f19598544c646ff91f03f66cca21030ac922) (`#60529455`) | `+13` | **`2s`** |

## Build & Test

```bash
forge test -vvv
```

`9 passed; 0 failed; 0 skipped` (Solc `0.8.29`, including `testFuzz_DeleverageConservesDebtAndCollateral` 256 runs, multi-user simultaneous batch dispatch, cross-chain Base->Unichain routing, and 3-step cascading deleverage).
