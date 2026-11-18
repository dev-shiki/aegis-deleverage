#!/usr/bin/env python3
"""CLI helper for ReactiveVaultGuard on Base Sepolia (84532) and Reactive Lasna (5318007)."""

import argparse
import json
import os
import subprocess
import sys
import urllib.request

BASE_SEPOLIA_RPC = os.getenv("BASE_SEPOLIA_RPC", "https://sepolia.base.org")
REACTIVE_LASNA_RPC = os.getenv("REACTIVE_LASNA_RPC", "https://lasna-rpc.rnk.dev/")
BASE_SEPOLIA_FAUCET = "0x2afaFD298b23b62760711756088F75B7409f5967"
BASE_SEPOLIA_CALLBACK_PROXY = "0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6"
ETH_ASSET = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"


def rpc_call(url: str, method: str, params: list) -> str:
    payload = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "ReactiveVaultGuard-CLI/1.0"},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode())
        if "error" in data:
            raise RuntimeError(data["error"])
        return data["result"]


def run_cast(args: list[str]) -> str:
    cast_bin = os.getenv("CAST_BIN", "cast")
    res = subprocess.run([cast_bin] + args, capture_output=True, text=True, check=True)
    return res.stdout.strip()


def cmd_status(args: argparse.Namespace) -> None:
    for name, url in [("Base Sepolia", BASE_SEPOLIA_RPC), ("Reactive Lasna", REACTIVE_LASNA_RPC)]:
        cid = int(rpc_call(url, "eth_chainId", []), 16)
        blk = int(rpc_call(url, "eth_blockNumber", []), 16)
        line = f"{name}: chainId={cid}, block={blk}"
        if args.address:
            bal_wei = int(rpc_call(url, "eth_getBalance", [args.address, "latest"]), 16)
            line += f", balance={bal_wei / 1e18:.6f}"
        print(line)


def cmd_faucet(args: argparse.Namespace) -> None:
    pk = os.environ["PRIVATE_KEY"]
    print(f"Requesting lREACT via Base Sepolia faucet ({BASE_SEPOLIA_FAUCET}) for {args.address}...")
    out = run_cast([
        "send", BASE_SEPOLIA_FAUCET,
        "request(address)", args.address,
        "--value", args.value,
        "--rpc-url", BASE_SEPOLIA_RPC,
        "--private-key", pk,
    ])
    print(out)


def cmd_trigger_crash(args: argparse.Namespace) -> None:
    pk = os.environ["PRIVATE_KEY"]
    oracle = os.environ["PRICE_ORACLE"]
    print(f"Updating PriceOracle {oracle} ETH price to {args.price_e8} (1e8 scale)...")
    out = run_cast([
        "send", oracle,
        "setPrice(address,uint256)", ETH_ASSET, str(args.price_e8),
        "--rpc-url", BASE_SEPOLIA_RPC,
        "--private-key", pk,
    ])
    print(out)


def main() -> None:
    parser = argparse.ArgumentParser(description="ReactiveVaultGuard CLI")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_status = sub.add_parser("status", help="Check RPC health and optional wallet balances")
    p_status.add_argument("--address", help="Wallet address to check balances")
    p_status.set_defaults(func=cmd_status)

    p_faucet = sub.add_parser("faucet", help="Convert Base Sepolia ETH to lREACT (1 ETH -> 100 lREACT)")
    p_faucet.add_argument("--address", required=True, help="Recipient wallet on Reactive Lasna")
    p_faucet.add_argument("--value", default="0.05ether", help="Base Sepolia ETH amount (max 5ether)")
    p_faucet.set_defaults(func=cmd_faucet)

    p_crash = sub.add_parser("trigger-crash", help="Emit PriceUpdated on Base Sepolia to trigger Reactive callback")
    p_crash.add_argument("--price-e8", type=int, default=180000000000, help="New price in 1e8 USD (default $1800)")
    p_crash.set_defaults(func=cmd_trigger_crash)

    args = parser.parse_args()
    try:
        args.func(args)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
