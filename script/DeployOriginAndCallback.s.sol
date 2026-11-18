// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Script.sol";
import "../src/PriceOracle.sol";
import "../src/ProtectedVault.sol";

/// @title DeployOriginAndCallback
/// @notice Deploys PriceOracle and ProtectedVault on Base Sepolia (84532) or Unichain Sepolia (1301) using the Reactive Omni Callback Proxy.
contract DeployOriginAndCallback is Script {
    address public constant BASE_SEPOLIA_OMNI_CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    address public constant UNICHAIN_SEPOLIA_OMNI_CALLBACK_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;
    address public constant ETH_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address defaultProxy = block.chainid == 1301
            ? UNICHAIN_SEPOLIA_OMNI_CALLBACK_PROXY
            : BASE_SEPOLIA_OMNI_CALLBACK_PROXY;
        address callbackProxy = vm.envOr("CALLBACK_PROXY", defaultProxy);
        uint256 initialEthPriceE8 = vm.envOr("INITIAL_ETH_PRICE_E8", uint256(2500e8));

        vm.startBroadcast(deployerKey);

        PriceOracle oracle = new PriceOracle();
        oracle.setPrice(ETH_ASSET, initialEthPriceE8);

        uint256 vaultFundingWei = vm.envOr("VAULT_CALLBACK_FUNDING_WEI", uint256(0.001 ether));
        ProtectedVault vault = new ProtectedVault{value: vaultFundingWei}(callbackProxy, address(oracle));

        vm.stopBroadcast();

        console.log("PriceOracle deployed at:", address(oracle));
        console.log("ProtectedVault deployed at:", address(vault));
        console.log("Omni CallbackProxy:", callbackProxy);
    }
}
