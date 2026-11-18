// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PriceOracle.sol";
import "../src/ProtectedVault.sol";

/// @title LiveDemoFlow
/// @notice Executes end-to-end user position setup, guard registration, and price crash trigger on Base Sepolia (84532).
contract LiveDemoFlow is Script {
    address public constant ETH_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address oracleAddr = vm.envAddress("PRICE_ORACLE");
        address vaultAddr = vm.envAddress("PROTECTED_VAULT");

        PriceOracle oracle = PriceOracle(oracleAddr);
        ProtectedVault vault = ProtectedVault(payable(vaultAddr));

        vm.startBroadcast(deployerKey);

        // 1. Reset oracle ETH price to $2,500 (2500e8)
        oracle.setPrice(ETH_ASSET, 2500e8);

        // 2. Deposit 0.002 ETH collateral ($5.00 at $2,500/ETH)
        vault.deposit{value: 0.002 ether}(ETH_ASSET);

        // 3. Borrow $3.00 USD (3e8) -> Health Factor = 166.66% (>= 120% min)
        vault.borrow(3e8);

        // 4. Configure Reactive Guard: stop-loss at $2,000, min HF 130%, 50% repay, 30s cooldown
        vault.configureGuard(ETH_ASSET, 2000e8, 13_000, 5_000, 30, true);

        // 5. Trigger ETH flash crash to $1,800 (1800e8) -> emits PriceUpdated for Reactive Lasna
        oracle.setPrice(ETH_ASSET, 1800e8);

        vm.stopBroadcast();

        console.log("LiveDemoFlow completed on Base Sepolia.");
        console.log("PriceOracle:", oracleAddr);
        console.log("ProtectedVault:", vaultAddr);
    }
}
