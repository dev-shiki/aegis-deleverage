// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PriceOracle.sol";
import "../src/ProtectedVault.sol";

/// @title DeployOriginAndCallback
/// @notice Deploys PriceOracle and ProtectedVault on Base Sepolia (84532).
contract DeployOriginAndCallback is Script {
    address public constant BASE_SEPOLIA_CALLBACK_PROXY = 0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6;
    address public constant ETH_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address callbackProxy = vm.envOr("CALLBACK_PROXY", BASE_SEPOLIA_CALLBACK_PROXY);
        uint256 initialEthPriceE8 = vm.envOr("INITIAL_ETH_PRICE_E8", uint256(2500e8));

        vm.startBroadcast(deployerKey);

        PriceOracle oracle = new PriceOracle();
        oracle.setPrice(ETH_ASSET, initialEthPriceE8);

        uint256 vaultFundingWei = vm.envOr("VAULT_CALLBACK_FUNDING_WEI", uint256(0.001 ether));
        ProtectedVault vault = new ProtectedVault{value: vaultFundingWei}(callbackProxy, address(oracle));

        vm.stopBroadcast();

        console.log("PriceOracle deployed at:", address(oracle));
        console.log("ProtectedVault deployed at:", address(vault));
        console.log("CallbackProxy:", callbackProxy);
    }
}
