# ReactiveVaultGuard: DoraHacks Reactive Omni Buildathon Submission

Automated Cross-Chain Stop-Loss and Deleverage Guard built with Reactive Smart Contracts (Reactive Lasna `5318007`) protecting collateral vaults on Base Sepolia (`84532`).

- **Live Web Console:** https://dev-shiki.github.io/reactive-vault-guard/
- **Repository:** https://github.com/dev-shiki/reactive-vault-guard

---

## Problem

DeFi borrowers with leveraged collateral positions depend on centralized keeper bots or off-chain cron jobs to prevent liquidation during sudden price drops. When keepers stall, go offline, or miss a fast market move, borrowers suffer full liquidation penalties instead of a partial, controlled debt reduction. Users also cannot easily inspect or verify whether a third-party keeper is actively monitoring their specific stop-loss threshold.

## Architecture

ReactiveVaultGuard replaces off-chain keepers with an autonomous three-contract loop across Base Sepolia (`84532`) and Reactive Lasna (`5318007`):

1. **Origin (`src/PriceOracle.sol` on Base Sepolia `84532`)**
   - Stores USD prices scaled to `1e8` (`pricesE8`) and emits `PriceUpdated(address indexed asset, uint256 oldPriceE8, uint256 newPriceE8, uint256 timestamp)` whenever `setPrice(address asset, uint256 newPriceE8)` runs.
2. **Reactive Brain (`src/ReactiveVaultGuard.sol` on Reactive Lasna `5318007`)**
   - Inherits `AbstractReactive` and subscribes in its constructor (`if (!vm)`) via `SERVICE_ADDR` (`0x0000000000000000000000000000000000fffFfF`) to two Base Sepolia events: `GuardConfigured` from `ProtectedVault` and `PriceUpdated` from `PriceOracle`.
   - Syncs per-user guard thresholds (`asset`, `stopLossPriceE8`, `minHealthFactorBps`, `enabled`) into ReactVM storage via `react(LogRecord calldata log)`.
   - On `PriceUpdated`, checks registered watchers for that asset (`assetWatchers[asset]`). When `guard.enabled` is true, `newPriceE8 <= guard.stopLossPriceE8`, and `log.block_number > guard.lastTriggeredBlock` (preventing same-block replay), it emits `Callback(destinationChainId, protectedVault, CALLBACK_GAS_LIMIT, payload)` with `CALLBACK_GAS_LIMIT = 500_000` calling `executeProtection(address,address,uint256)` and emits `ProtectionDispatched(user, asset, newPriceE8)`.
3. **Destination (`src/ProtectedVault.sol` on Base Sepolia `84532`)**
   - Inherits `AbstractCallback` bound to the Base Sepolia Callback Proxy (`0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6`).
   - Users deposit native ETH (`deposit`), borrow USD debt up to `MIN_BORROW_HF_BPS` (`12000` bps / 120% collateralization), and configure personal parameters via `configureGuard`.
   - `executeProtection(address rvmId, address user, uint256 triggerPriceE8)` enforces `authorizedSenderOnly`, `rvmIdOnly(rvmId)`, `whenNotPaused`, `MIN_COOLDOWN_SECONDS` (`>= 30` seconds), `MAX_REPAY_BPS` (`5000` bps / 50% cap per execution), and `MAX_DAILY_PROTECTIONS` (`5` executions per day). It reduces debt by `repayBps` and deducts equivalent collateral at `triggerPriceE8`, restoring the user's health factor without external keeper infrastructure.

## Buildathon Track Fit

### Track 1: Every Second Counts
- **Sub-second event-driven reaction:** `ReactiveVaultGuard.react()` evaluates incoming `PriceUpdated` logs immediately upon block ingestion in ReactVM, removing polling latency and off-chain cron intervals.
- **Same-block deduplication:** Tracks `lastTriggeredBlock` per watcher so duplicate or intra-block price logs never emit redundant callbacks.

### Track 2: Set It and Forget It
- **One-transaction rule registration:** Users call `ProtectedVault.configureGuard(...)` once on Base Sepolia. `ReactiveVaultGuard` automatically captures the `GuardConfigured` log and maintains the watcher list on Reactive Lasna.
- **Bounded autonomous execution:** Per-user `repayBps` caps (max 50%), `cooldownSeconds` (>= 30s), daily execution caps (5/day), and an owner-controlled `setPaused(bool)` circuit breaker bound autonomous callbacks within predictable risk limits.

## Verified Testnet Parameters

| Component | Value |
| --- | --- |
| Reactive Lasna RPC | `https://lasna-rpc.rnk.dev/` |
| Reactive Lasna Chain ID | `5318007` (`0x512577`) |
| Reactive System Contract | `0x0000000000000000000000000000000000fffFfF` |
| Base Sepolia RPC | `https://sepolia.base.org` |
| Base Sepolia Chain ID | `84532` (`0x14a34`) |
| Base Sepolia Callback Proxy | `0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6` |
| lREACT Faucet (Base Sepolia) | `0x2afaFD298b23b62760711756088F75B7409f5967` (`1 ETH -> 100 lREACT`, max 5 ETH) |
| lREACT Faucet (Ethereum Sepolia) | `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` (`1 ETH -> 100 lREACT`, max 5 ETH) |

## Test Proof

Foundry test suite (`forge test -vvv`) passes `6 passed; 0 failed; 0 skipped`:

```text
Ran 6 tests for test/ReactiveVaultGuard.t.sol:ReactiveVaultGuardTest
[PASS] testFuzz_DeleverageConservesDebtAndCollateral(uint96,uint64,uint16,uint64) (runs: 256)
[PASS] test_CallbackSecurityAndSafetyCaps()
[PASS] test_EndToEnd_OriginToReactiveToCallback()
[PASS] test_MultiUserIsolationAndSameBlockDedupe()
[PASS] test_PausedCircuitBreaker()
[PASS] test_SubscriptionsRegisteredOnReactiveNetwork()
```

Additional verified checks:
- Python CLI syntax check: `python -m py_compile scripts/guard_cli.py` exits `0`.
- Live Frontend / GitHub Pages Console: `frontend/index.html` and `docs/index.html` are byte-identical and provide read-only telemetry against `https://sepolia.base.org` and `https://lasna-rpc.rnk.dev/` plus MetaMask transaction controls.

## Deployed Contract Addresses & Transaction Hashes

| Item | Network | Value |
| --- | --- | --- |
| `PriceOracle` Address | Base Sepolia (`84532`) | [`0x2AfEEC24f2a810D726DB47CAEa3A76AaF6A7D50E`](https://sepolia.basescan.org/address/0x2AfEEC24f2a810D726DB47CAEa3A76AaF6A7D50E) (Deploy Tx: [`0x75e1bae4...a7fad798`](https://sepolia.basescan.org/tx/0x75e1bae43cab67ff29d1b21229607f5f278c001da82fc5cf5abb2796a7fad798)) |
| `ProtectedVault` Address | Base Sepolia (`84532`) | [`0x5dEE49560fcE0a1bc26EBB6591f58B7A2Af313F1`](https://sepolia.basescan.org/address/0x5dEE49560fcE0a1bc26EBB6591f58B7A2Af313F1) (Deploy Tx: [`0xad2a191e...2bc10353`](https://sepolia.basescan.org/tx/0xad2a191e1e85f5d482aac292d1edcdcb9f3d4e260df0f985f71f260b2bc10353)) |
| `ReactiveVaultGuard` Address | Reactive Lasna (`5318007`) | [`0x2AfEEC24f2a810D726DB47CAEa3A76AaF6A7D50E`](https://lasna.reactscan.net/address/0x2AfEEC24f2a810D726DB47CAEa3A76AaF6A7D50E) (Block `8636631`, Deploy & Subscribe Tx: [`0xb86b0d0d...09d0777d`](https://lasna.reactscan.net/tx/0xb86b0d0d96c6e94ce5438132b6e00805256499ad59256107cb8e796009d0777d)) |
| Vault `deposit(0.002 ETH)` Tx | Base Sepolia (`84532`) | [`0x60cb66d8e4acee2c75239f350fb2f4b84ff571a9639d740f05108bee8ff3bdea`](https://sepolia.basescan.org/tx/0x60cb66d8e4acee2c75239f350fb2f4b84ff571a9639d740f05108bee8ff3bdea) |
| Vault `borrow($3.00 USD)` Tx | Base Sepolia (`84532`) | [`0x158160ddd9d26b191625cbf79fa1db74af691b4a18c7d9c4865d5a8a0385f699`](https://sepolia.basescan.org/tx/0x158160ddd9d26b191625cbf79fa1db74af691b4a18c7d9c4865d5a8a0385f699) |
| Origin `configureGuard` Tx | Base Sepolia (`84532`) | [`0x640aa152aa1c9134ed5cc0ee53ed2a1691c5e1cc361e9cd34037c97908966273`](https://sepolia.basescan.org/tx/0x640aa152aa1c9134ed5cc0ee53ed2a1691c5e1cc361e9cd34037c97908966273) |
| Origin `PriceUpdated` Crash Tx (`$2,500 -> $1,800`) | Base Sepolia (`84532`) | [`0xc3435fcaf38e37af16a7a1df545f8bdc2e93124ecd8670faf4bb9c2815661617`](https://sepolia.basescan.org/tx/0xc3435fcaf38e37af16a7a1df545f8bdc2e93124ecd8670faf4bb9c2815661617) |
