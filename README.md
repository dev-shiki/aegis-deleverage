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
