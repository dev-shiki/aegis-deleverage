// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Script.sol";
import "../src/PriceOracle.sol";
import "../src/ProtectedVault.sol";

/// @title LiveDemoFlow
/// @notice Binds callbackSender, opens a leveraged vault position, and configures stop-loss guard on Base Sepolia (84532).
/// @dev Crash price trigger runs in a separate transaction/block afterwards so ReactVM syncs GuardConfigured first.
contract LiveDemoFlow is Script {
    address public constant ETH_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address oracleAddr = vm.envAddress("PRICE_ORACLE");
        address vaultAddr = vm.envAddress("PROTECTED_VAULT");
        address reactiveAddr = vm.envAddress("AEGIS_REACTIVE");

        PriceOracle oracle = PriceOracle(oracleAddr);
        ProtectedVault vault = ProtectedVault(payable(vaultAddr));

        vm.startBroadcast(deployerKey);

        // 1. Bind authorized Reactive Omni caller on ProtectedVault
        vault.setCallbackSender(reactiveAddr);

        // 2. Ensure oracle baseline is $2,500 (2500e8)
        oracle.setPrice(ETH_ASSET, 2500e8);

        // 3. Deposit 0.002 ETH collateral ($5.00 at $2,500/ETH) and borrow $3.00 USD (HF = 166.66%)
        vault.deposit{value: 0.002 ether}(ETH_ASSET);
        vault.borrow(3e8);

        // 4. Configure Reactive Guard: stop-loss at $2,000, min HF 130%, 25% repay/step, 5s cooldown
        vault.configureGuard(ETH_ASSET, 2000e8, 13_000, 2_500, 5, true);

        vm.stopBroadcast();

        console.log("Vault setup & GuardConfigured completed on Base Sepolia.");
        console.log("CallbackSender bound to AegisDeleverage:", reactiveAddr);
    }
}
