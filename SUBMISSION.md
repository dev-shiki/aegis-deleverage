# AegisDeleverage: DoraHacks Reactive Omni Buildathon Submission

Autonomous cross-chain stop-loss and cascading deleverage vault built on **`Reactive-Network/reactive-lib-omni`** for **Track 1: Every Second Counts**.

- **Live Web Console:** https://dev-shiki.github.io/aegis-deleverage/
- **Repository:** https://github.com/dev-shiki/aegis-deleverage
- **Demo Video:** https://youtu.be/QGzu6UltIy4

---

## Problem
DeFi borrowers with leveraged collateral positions depend on centralized keeper bots or off-chain cron jobs to prevent liquidation during sudden price drops. Keepers stall, skip small positions, and give users zero on-chain verification that their stop-loss threshold is actively monitored.

## Solution
AegisDeleverage replaces off-chain keepers with an autonomous cross-chain loop between **Base Sepolia (`84532`)** and **Reactive Lasna (`5318007`)** using **`reactive-lib-omni`**:
1. **Origin (`src/PriceOracle.sol` on Base Sepolia `84532`):** Emits `PriceUpdated` whenever asset prices move.
2. **Reactive Omni Brain (`src/AegisDeleverage.sol` on Reactive Lasna `5318007`):** Subscribes to `GuardConfigured` and `PriceUpdated` via `SYSTEM` (`0x8888...8888`) and dispatches callbacks via `SYSTEM.requestCallbackV_1_0` under `onlySystem`.
3. **Destination (`src/ProtectedVault.sol` on Base Sepolia `84532`):** Bound to the Base Sepolia Omni Callback Proxy (`0x476F44b11F5C942c58f4c8E3d0300E5710743585`). Verifies `onlyServiceProvider` + `callbackSender`, enforces `nonReentrant`, configurable cooldowns, `50%` max repay/step, `5/day` cap, and pause circuit breaker, then atomically deleverages the user's position.

## Deployed Contract Addresses

| Component | Network | Address |
| --- | --- | --- |
| `PriceOracle` | Base Sepolia (`84532`) | [`0x06Df840a5aE025A8d86Dde667E02E7cff0cFf4c4`](https://sepolia.basescan.org/address/0x06Df840a5aE025A8d86Dde667E02E7cff0cFf4c4) |
| `ProtectedVault` | Base Sepolia (`84532`) | [`0x8AeD78c80024C2C5d8E90F346B87298174CeBcce`](https://sepolia.basescan.org/address/0x8AeD78c80024C2C5d8E90F346B87298174CeBcce) |
| `AegisDeleverage` | Reactive Lasna (`5318007`) | [`0x5dee49560FcE0a1BC26EBb6591F58B7A2aF313F1`](https://lasna.reactscan.net/address/0x5dee49560FcE0a1BC26EBb6591F58B7A2aF313F1) |

## Verified On-Chain Transactions & Measured Loop Latency (`2.33s` avg)

- **Deploy `AegisDeleverage` (Reactive Lasna `5318007`):** [`0x570e012731792f171341a34139b3ecdeee9ee15fff0c9fa8968c8d64396949f7`](https://lasna.reactscan.net/tx/0x570e012731792f171341a34139b3ecdeee9ee15fff0c9fa8968c8d64396949f7)
- **Setup (`setCallbackSender`, `deposit`, `borrow $3.00`, `configureGuard`):** [`0x9132b1ecb46b98ef139781f77d5e09ace90c56e98065eba8f8d8b4b431aacac0`](https://sepolia.basescan.org/tx/0x9132b1ecb46b98ef139781f77d5e09ace90c56e98065eba8f8d8b4b431aacac0)

| Run | Trigger Price | Origin `PriceUpdated` Tx (Block) | Callback `ProtectionExecuted` Tx (Block) | Block Delta | Wall Latency |
| --- | --- | --- | --- | --- | --- |
| 1 | `$1,900` | [`0xa7f55f1a...049e8c93`](https://sepolia.basescan.org/tx/0xa7f55f1a5548445c0e6323cfb9d1948ff7039bece41f850c85b34218049e8c93) (`#60528253`) | [`0x2b360778...38a44037`](https://sepolia.basescan.org/tx/0x2b36077887ec9a78282f8796860f8f852dc4b12d11682041ec2b806838a44037) (`#60528263`) | `+10` | **`2s`** |
| 2 | `$1,750` | [`0xae503812...861cba4f`](https://sepolia.basescan.org/tx/0xae503812ea7c0056898a55a6177128e53a4391bc2efa77a041068a76861cba4f) (`#60529380`) | [`0x2f52e0d7...443a83aa`](https://sepolia.basescan.org/tx/0x2f52e0d754e79003d46ccd76a49026bef1a0394f2007fafe09cb779c443a83aa) (`#60529392`) | `+12` | **`3s`** |
| 3 | `$1,600` | [`0x543ffffe...74838fa9`](https://sepolia.basescan.org/tx/0x543ffffee8683bee3bc93166a8c3d997bac4812e8b115c2c62ece31d74838fa9) (`#60529442`) | [`0x057ce08b...030ac922`](https://sepolia.basescan.org/tx/0x057ce08b8321f278715099788fc3f19598544c646ff91f03f66cca21030ac922) (`#60529455`) | `+13` | **`2s`** |

## Test Proof

Foundry test suite (`forge test -vvv`) passes **`9 passed; 0 failed; 0 skipped`**:
- `test_EndToEnd_OriginToOmniSystemToCallback`
- `test_MultiUserSimultaneousBatchDispatchAndDedupe`
- `test_CascadingMultiStepDeleverage`
- `test_CrossChainOriginBaseToUnichainTarget`
- `test_CallbackSecurityAndSafetyCaps`
- `test_OnlySystemCanInvokeReact`
- `test_PausedCircuitBreaker`
- `test_SubscriptionsAndReserveAccounting`
- `testFuzz_DeleverageConservesDebtAndCollateral` (`256 runs`)
