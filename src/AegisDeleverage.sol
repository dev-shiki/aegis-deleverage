// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractReactive } from "reactive-lib/base/AbstractReactive.sol";
import { ISystemContract } from "reactive-lib/interfaces/ISystemContract.sol";

/// @title AegisDeleverage
/// @notice Reactive Omni Smart Contract on Reactive Lasna (5318007) monitoring Base Sepolia oracle & guard events.
contract AegisDeleverage is AbstractReactive {
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
    uint256 public triggersDispatched;

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
    event ProtectionDispatched(
        address indexed user,
        address indexed asset,
        uint256 triggerPriceE8,
        uint256 originBlock
    );

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

        SYSTEM.subscribe(
            _originChainId,
            _priceOracle,
            PRICE_UPDATED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            _originChainId,
            _protectedVault,
            GUARD_CONFIGURED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    function react(LogRecord calldata log_) external override onlySystem {
        if (log_.chainId != originChainId) return;

        if (log_.contractAddress == protectedVault && log_.topic0 == GUARD_CONFIGURED_TOPIC_0) {
            _handleGuardConfigured(log_);
            return;
        }

        if (log_.contractAddress == priceOracle && log_.topic0 == PRICE_UPDATED_TOPIC_0) {
            _handlePriceUpdated(log_);
        }
    }

    function _handleGuardConfigured(LogRecord calldata log_) internal {
        address user = address(uint160(log_.topic1));
        address asset = address(uint160(log_.topic2));
        (uint256 stopLossPriceE8, uint256 minHealthFactorBps, bool enabled) =
            abi.decode(log_.data, (uint256, uint256, bool));

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

    function _handlePriceUpdated(LogRecord calldata log_) internal {
        address asset = address(uint160(log_.topic1));
        (, uint256 newPriceE8,) = abi.decode(log_.data, (uint256, uint256, uint256));

        address[] storage watchers = assetWatchers[asset];
        uint256 len = watchers.length;
        for (uint256 i = 0; i < len; ++i) {
            address user = watchers[i];
            WatchedGuard storage guard = watchedGuards[user];
            if (!guard.enabled || guard.asset != asset) continue;
            if (newPriceE8 > guard.stopLossPriceE8) continue;
            if (log_.blockNumber <= guard.lastTriggeredBlock) continue;

            guard.lastTriggeredBlock = log_.blockNumber;
            ++triggersDispatched;

            // Reactive Omni injects this reactive contract address into arg0 on the destination chain.
            bytes memory payload = abi.encodeWithSignature(
                "executeProtection(address,address,uint256,uint256)",
                address(0),
                user,
                newPriceE8,
                log_.blockNumber
            );
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: destinationChainId,
                    recipient: protectedVault,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: payload
                })
            );
            emit ProtectionDispatched(user, asset, newPriceE8, log_.blockNumber);
        }
    }

    function getAssetWatcherCount(address asset) external view returns (uint256) {
        return assetWatchers[asset].length;
    }

    function pauseSubscriptions() external onlyOwner {
        SYSTEM.unsubscribe(
            originChainId,
            priceOracle,
            PRICE_UPDATED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.unsubscribe(
            originChainId,
            protectedVault,
            GUARD_CONFIGURED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }
}
