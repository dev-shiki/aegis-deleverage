// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "reactive-lib/abstract-base/AbstractReactive.sol";

/// @title ReactiveVaultGuard
/// @notice Reactive Smart Contract deployed on Reactive Lasna (5318007) monitoring Base Sepolia events.
contract ReactiveVaultGuard is AbstractReactive {
    uint64 public constant CALLBACK_GAS_LIMIT = 500_000;

    uint256 public constant PRICE_UPDATED_TOPIC_0 =
        uint256(keccak256("PriceUpdated(address,uint256,uint256,uint256)"));
    uint256 public constant GUARD_CONFIGURED_TOPIC_0 =
        uint256(keccak256("GuardConfigured(address,address,uint256,uint256,bool)"));

    struct WatchedGuard {
        address asset;
        uint256 stopLossPriceE8;
        uint256 minHealthFactorBps;
        uint256 lastTriggeredBlock;
        bool enabled;
    }

    address public immutable owner;
    uint256 public immutable originChainId;
    uint256 public immutable destinationChainId;
    address public immutable priceOracle;
    address public immutable protectedVault;

    mapping(address => WatchedGuard) public watchedGuards;
    mapping(address => address[]) private assetWatchers;
    mapping(address => mapping(address => bool)) private isAssetWatcher;

    event GuardSynced(
        address indexed user,
        address indexed asset,
        uint256 stopLossPriceE8,
        uint256 minHealthFactorBps,
        bool enabled
    );
    event ProtectionDispatched(address indexed user, address indexed asset, uint256 triggerPriceE8);

    error Unauthorized();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(
        uint256 _originChainId,
        uint256 _destinationChainId,
        address _priceOracle,
        address _protectedVault
    ) payable {
        owner = msg.sender;
        originChainId = _originChainId;
        destinationChainId = _destinationChainId;
        priceOracle = _priceOracle;
        protectedVault = _protectedVault;

        // Subscriptions only execute on the top-level Reactive Network, never inside ReactVM.
        if (!vm) {
            service.subscribe(
                _originChainId,
                _priceOracle,
                PRICE_UPDATED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            service.subscribe(
                _originChainId,
                _protectedVault,
                GUARD_CONFIGURED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    function react(LogRecord calldata log) external vmOnly {
        if (log.chain_id != originChainId) return;

        if (log._contract == protectedVault && log.topic_0 == GUARD_CONFIGURED_TOPIC_0) {
            _handleGuardConfigured(log);
            return;
        }

        if (log._contract == priceOracle && log.topic_0 == PRICE_UPDATED_TOPIC_0) {
            _handlePriceUpdated(log);
        }
    }

    function _handleGuardConfigured(LogRecord calldata log) internal {
        address user = address(uint160(log.topic_1));
        address asset = address(uint160(log.topic_2));
        (uint256 stopLossPriceE8, uint256 minHealthFactorBps, bool enabled) =
            abi.decode(log.data, (uint256, uint256, bool));

        watchedGuards[user] = WatchedGuard({
            asset: asset,
            stopLossPriceE8: stopLossPriceE8,
            minHealthFactorBps: minHealthFactorBps,
            lastTriggeredBlock: watchedGuards[user].lastTriggeredBlock,
            enabled: enabled
        });

        if (!isAssetWatcher[asset][user]) {
            isAssetWatcher[asset][user] = true;
            assetWatchers[asset].push(user);
        }

        emit GuardSynced(user, asset, stopLossPriceE8, minHealthFactorBps, enabled);
    }

    function _handlePriceUpdated(LogRecord calldata log) internal {
        address asset = address(uint160(log.topic_1));
        (, uint256 newPriceE8,) = abi.decode(log.data, (uint256, uint256, uint256));

        address[] storage watchers = assetWatchers[asset];
        uint256 len = watchers.length;
        for (uint256 i = 0; i < len; ++i) {
            address user = watchers[i];
            WatchedGuard storage guard = watchedGuards[user];
            if (!guard.enabled) continue;
            if (newPriceE8 > guard.stopLossPriceE8) continue;
            if (log.block_number <= guard.lastTriggeredBlock) continue;

            guard.lastTriggeredBlock = log.block_number;

            // First argument (address(0)) is overwritten by Reactive Network with deployer RVM ID.
            bytes memory payload = abi.encodeWithSignature(
                "executeProtection(address,address,uint256)",
                address(0),
                user,
                newPriceE8
            );
            emit Callback(destinationChainId, protectedVault, CALLBACK_GAS_LIMIT, payload);
            emit ProtectionDispatched(user, asset, newPriceE8);
        }
    }

    function getAssetWatcherCount(address asset) external view returns (uint256) {
        return assetWatchers[asset].length;
    }

    function pauseSubscriptions() external rnOnly onlyOwner {
        service.unsubscribe(
            originChainId,
            priceOracle,
            PRICE_UPDATED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        service.unsubscribe(
            originChainId,
            protectedVault,
            GUARD_CONFIGURED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }
}
