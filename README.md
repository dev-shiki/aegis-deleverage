# ReactiveVaultGuard

Automated DeFi Health-Factor & Stop-Loss Guard built for the **Reactive Omni Buildathon** (Track 1: *Every Second Counts* & Track 2: *Set It and Forget It*).

## Architecture

1. **Origin (`PriceOracle.sol` on Base Sepolia `84532`)**
   - Emits `PriceUpdated(address indexed asset, uint256 oldPriceE8, uint256 newPriceE8, uint256 timestamp)`.
2. **Reactive Brain (`ReactiveVaultGuard.sol` on Reactive Lasna `5318007`)**
   - Subscribes to both `GuardConfigured` (from `ProtectedVault`) and `PriceUpdated` (from `PriceOracle`) via `SERVICE_ADDR` (`0x0000000000000000000000000000000000fffFfF`).
   - Maintains per-user stop-loss thresholds in ReactVM state and dispatches `Callback(84532, protectedVault, 500_000, payload)` when `newPriceE8 <= stopLossPriceE8`.
3. **Destination (`ProtectedVault.sol` on Base Sepolia `84532`)**
   - Inherits `AbstractCallback` bound to Base Sepolia Callback Proxy (`0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6`).
   - Enforces `authorizedSenderOnly`, `rvmIdOnly(rvmId)`, `cooldownSeconds` (>= 30s), `MAX_REPAY_BPS` (50%), `MAX_DAILY_PROTECTIONS` (5/day), and `paused` circuit breaker.
   - Atomically deleverages the position when triggered, restoring collateralization ratio.

## Verified Network & Contract Parameters

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
| Deployed `PriceOracle` (Base Sepolia `84532`) | [`0x2AfEEC24f2a810D726DB47CAEa3A76AaF6A7D50E`](https://sepolia.basescan.org/address/0x2AfEEC24f2a810D726DB47CAEa3A76AaF6A7D50E) (Tx: [`0x75e1bae4...a7fad798`](https://sepolia.basescan.org/tx/0x75e1bae43cab67ff29d1b21229607f5f278c001da82fc5cf5abb2796a7fad798)) |
| Deployed `ProtectedVault` (Base Sepolia `84532`) | [`0x5dee49560FcE0a1BC26EBb6591F58B7A2aF313F1`](https://sepolia.basescan.org/address/0x5dee49560FcE0a1BC26EBb6591F58B7A2aF313F1) (Tx: [`0xad2a191e...2bc10353`](https://sepolia.basescan.org/tx/0xad2a191e1e85f5d482aac292d1edcdcb9f3d4e260df0f985f71f260b2bc10353)) |
| Deployed `ReactiveVaultGuard` (Reactive Lasna `5318007`) | [`0x2AfEEC24f2a810D726DB47CAEa3A76AaF6A7D50E`](https://lasna.reactscan.net/address/0x2AfEEC24f2a810D726DB47CAEa3A76AaF6A7D50E) (Blk `8636631`, Tx: [`0xb86b0d0d...09d0777d`](https://lasna.reactscan.net/tx/0xb86b0d0d96c6e94ce5438132b6e00805256499ad59256107cb8e796009d0777d)) |

### Live Verified End-to-End Transactions (Blocks `60334206` & `60334389` / Lasna `8636631`)

| Step | Network | Action | Explorer Transaction Hash |
| --- | --- | --- | --- |
| 1 | Base Sepolia (`84532`) | Deploy `PriceOracle` (`0x2AfE...D50E`) | [`0x75e1bae4...a7fad798`](https://sepolia.basescan.org/tx/0x75e1bae43cab67ff29d1b21229607f5f278c001da82fc5cf5abb2796a7fad798) |
| 2 | Base Sepolia (`84532`) | Deploy `ProtectedVault` (`0x5dEE...13F1`) | [`0xad2a191e...2bc10353`](https://sepolia.basescan.org/tx/0xad2a191e1e85f5d482aac292d1edcdcb9f3d4e260df0f985f71f260b2bc10353) |
| 3 | Reactive Lasna (`5318007`) | Deploy `ReactiveVaultGuard` & Subscribe via `0x...fffFfF` | [`0xb86b0d0d...09d0777d`](https://lasna.reactscan.net/tx/0xb86b0d0d96c6e94ce5438132b6e00805256499ad59256107cb8e796009d0777d) |
| 4 | Base Sepolia (`84532`) | `deposit(ETH_ASSET)` (`0.002 ETH`) | [`0x60cb66d8...ff3bdea`](https://sepolia.basescan.org/tx/0x60cb66d8e4acee2c75239f350fb2f4b84ff571a9639d740f05108bee8ff3bdea) |
| 5 | Base Sepolia (`84532`) | `borrow(3e8)` (`$3.00 USD`, HF `166.66%`) | [`0x158160dd...0385f699`](https://sepolia.basescan.org/tx/0x158160ddd9d26b191625cbf79fa1db74af691b4a18c7d9c4865d5a8a0385f699) |
| 6 | Base Sepolia (`84532`) | `configureGuard(ETH, $2,000, 130%, 50%, 30s, true)` | [`0x640aa152...08966273`](https://sepolia.basescan.org/tx/0x640aa152aa1c9134ed5cc0ee53ed2a1691c5e1cc361e9cd34037c97908966273) |
| 7 | Base Sepolia (`84532`) | `setPrice(ETH, 1800e8)` (Crash Trigger `$2,500 -> $1,800`) | [`0xc3435fca...15661617`](https://sepolia.basescan.org/tx/0xc3435fcaf38e37af16a7a1df545f8bdc2e93124ecd8670faf4bb9c2815661617) |

## Build & Test

```bash
forge test -vvv
```

Verified suite (`6 passed; 0 failed; 0 skipped`, including 256-run fuzz conservation tests `testFuzz_DeleverageConservesDebtAndCollateral` and `test_MultiUserIsolationAndSameBlockDedupe`).

## Web Console & Docker Packaging

```bash
# Run locally without Docker
python -m http.server 8080 --directory frontend

# Or package via Docker
docker build -t reactive-vault-guard .
docker run --rm -p 8080:8080 reactive-vault-guard
```

## Deploy ($0 Testnet Flow)

1. Obtain free Sepolia ETH via PoW faucet (`sepolia-faucet.pk910.de`) or Google Cloud Web3 Faucet and bridge to Base Sepolia (`bridge.base.org`), then convert a small amount to `lREACT`:
   ```bash
   python scripts/guard_cli.py faucet --address <YOUR_WALLET> --value 0.05ether
   ```
2. Deploy Origin & Destination contracts on Base Sepolia:
   ```bash
   forge script script/DeployOriginAndCallback.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast
   ```
3. Set `PRICE_ORACLE` and `PROTECTED_VAULT` in `.env`, then deploy `ReactiveVaultGuard` on Reactive Lasna:
   ```bash
   forge script script/DeployReactive.s.sol --rpc-url $REACTIVE_LASNA_RPC --broadcast
   ```
4. Trigger a demo position + price crash (`$2,500 -> $1,800`) and record the Origin tx hash, Reactive tx hash on `https://lasna.reactscan.net/`, and Callback tx hash on `https://sepolia.basescan.org/` for DoraHacks submission.
