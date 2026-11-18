// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Script.sol";
import "../src/AegisDeleverage.sol";

/// @title DeployReactive
/// @notice Deploys AegisDeleverage on Reactive Lasna Testnet (5318007) using reactive-lib-omni.
contract DeployReactive is Script {
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address priceOracle = vm.envAddress("PRICE_ORACLE");
        address protectedVault = vm.envAddress("PROTECTED_VAULT");
        uint256 originChainId = vm.envOr("ORIGIN_CHAIN_ID", BASE_SEPOLIA_CHAIN_ID);
        uint256 destChainId = vm.envOr("DESTINATION_CHAIN_ID", BASE_SEPOLIA_CHAIN_ID);
        uint256 fundingWei = vm.envOr("REACTIVE_FUNDING_WEI", uint256(0.5 ether));

        vm.startBroadcast(deployerKey);

        AegisDeleverage aegis = new AegisDeleverage{value: fundingWei}(
            originChainId,
            destChainId,
            priceOracle,
            protectedVault
        );

        vm.stopBroadcast();

        console.log("AegisDeleverage deployed at:", address(aegis));
        console.log("Origin/Dest Chain ID:", originChainId);
        console.log("PriceOracle:", priceOracle);
        console.log("ProtectedVault:", protectedVault);
    }
}
