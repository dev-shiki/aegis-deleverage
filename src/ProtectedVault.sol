// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "reactive-lib/abstract-base/AbstractCallback.sol";
import "./PriceOracle.sol";

/// @title ProtectedVault
/// @notice Destination-chain collateral vault on Base Sepolia protected by Reactive Network callbacks.
contract ProtectedVault is AbstractCallback {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_BORROW_HF_BPS = 12_000; // 120% collateralization
    uint256 public constant MAX_REPAY_BPS = 5_000; // Cap single deleverage at 50%
    uint16 public constant MAX_DAILY_PROTECTIONS = 5;
    uint64 public constant MIN_COOLDOWN_SECONDS = 30;

    struct Position {
        address asset;
        uint256 collateralWei;
        uint256 debtUsdE8;
    }

    struct GuardConfig {
        address asset;
        uint256 stopLossPriceE8;
        uint256 minHealthFactorBps;
        uint256 repayBps;
        uint64 cooldownSeconds;
        uint64 lastTriggeredAt;
        uint64 dayIndex;
        uint16 dailyCount;
        bool enabled;
    }

    address public owner;
    PriceOracle public immutable priceOracle;
    bool public paused;

    mapping(address => Position) public positions;
    mapping(address => GuardConfig) public guards;

    event Deposited(address indexed user, address indexed asset, uint256 amountWei);
    event Borrowed(address indexed user, uint256 amountUsdE8, uint256 totalDebtUsdE8);
    event Repaid(address indexed user, uint256 amountUsdE8, uint256 remainingDebtUsdE8);
    event Withdrawn(address indexed user, uint256 amountWei);
    event GuardConfigured(
        address indexed user,
        address indexed asset,
        uint256 stopLossPriceE8,
        uint256 minHealthFactorBps,
        bool enabled
    );
    event ProtectionExecuted(
        address indexed user,
        address indexed asset,
        uint256 triggerPriceE8,
        uint256 debtReducedUsdE8,
        uint256 collateralUsedWei,
        uint256 newHealthFactorBps
    );
    event PausedSet(bool paused);
    event RvmIdUpdated(address indexed oldRvmId, address indexed newRvmId);

    error Unauthorized();
    error ContractPaused();
    error ZeroAmount();
    error InvalidAsset();
    error InsufficientCollateral();
    error UnhealthyPosition();
    error InvalidGuardConfig();
    error GuardNotEnabled();
    error CooldownActive();
    error DailyCapReached();
    error TriggerConditionNotMet();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    constructor(address _callbackProxy, address _priceOracle) AbstractCallback(_callbackProxy) payable {
        owner = msg.sender;
        priceOracle = PriceOracle(_priceOracle);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    function setRvmId(address _rvmId) external onlyOwner {
        address old = rvm_id;
        rvm_id = _rvmId;
        emit RvmIdUpdated(old, _rvmId);
    }

    function deposit(address asset) external payable whenNotPaused {
        if (msg.value == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender];
        if (pos.collateralWei > 0 && pos.asset != asset) revert InvalidAsset();
        pos.asset = asset;
        pos.collateralWei += msg.value;
        emit Deposited(msg.sender, asset, msg.value);
    }

    function borrow(uint256 amountUsdE8) external whenNotPaused {
        if (amountUsdE8 == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender];
        if (pos.collateralWei == 0) revert InsufficientCollateral();

        uint256 priceE8 = priceOracle.pricesE8(pos.asset);
        if (priceE8 == 0) revert InvalidAsset();

        pos.debtUsdE8 += amountUsdE8;
        if (getHealthFactorBps(msg.sender, priceE8) < MIN_BORROW_HF_BPS) {
            revert UnhealthyPosition();
        }
        emit Borrowed(msg.sender, amountUsdE8, pos.debtUsdE8);
    }

    function repay(uint256 amountUsdE8) external whenNotPaused {
        if (amountUsdE8 == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender];
        uint256 reduction = amountUsdE8 > pos.debtUsdE8 ? pos.debtUsdE8 : amountUsdE8;
        pos.debtUsdE8 -= reduction;
        emit Repaid(msg.sender, reduction, pos.debtUsdE8);
    }

    function withdraw(uint256 amountWei) external whenNotPaused {
        if (amountWei == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender];
        if (pos.collateralWei < amountWei) revert InsufficientCollateral();

        pos.collateralWei -= amountWei;
        if (pos.debtUsdE8 > 0) {
            uint256 priceE8 = priceOracle.pricesE8(pos.asset);
            if (getHealthFactorBps(msg.sender, priceE8) < MIN_BORROW_HF_BPS) {
                revert UnhealthyPosition();
            }
        }

        (bool ok,) = payable(msg.sender).call{value: amountWei}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, amountWei);
    }

    function configureGuard(
        address asset,
        uint256 stopLossPriceE8,
        uint256 minHealthFactorBps,
        uint256 repayBps,
        uint64 cooldownSeconds,
        bool enabled
    ) external whenNotPaused {
        if (repayBps == 0 || repayBps > MAX_REPAY_BPS) revert InvalidGuardConfig();
        if (cooldownSeconds < MIN_COOLDOWN_SECONDS) revert InvalidGuardConfig();

        GuardConfig storage guard = guards[msg.sender];
        guard.asset = asset;
        guard.stopLossPriceE8 = stopLossPriceE8;
        guard.minHealthFactorBps = minHealthFactorBps;
        guard.repayBps = repayBps;
        guard.cooldownSeconds = cooldownSeconds;
        guard.enabled = enabled;

        emit GuardConfigured(msg.sender, asset, stopLossPriceE8, minHealthFactorBps, enabled);
    }

    /// @notice Invoked by the Base Sepolia Callback Proxy when ReactiveVaultGuard emits a Callback.
    /// @dev Reactive Network overwrites the first argument with the deployer's RVM ID.
    function executeProtection(
        address rvmId,
        address user,
        uint256 triggerPriceE8
    ) external authorizedSenderOnly rvmIdOnly(rvmId) whenNotPaused {
        GuardConfig storage guard = guards[user];
        if (!guard.enabled) revert GuardNotEnabled();

        if (
            guard.lastTriggeredAt != 0 &&
            block.timestamp < uint256(guard.lastTriggeredAt) + uint256(guard.cooldownSeconds)
        ) {
            revert CooldownActive();
        }

        uint64 currentDay = uint64(block.timestamp / 1 days);
        if (guard.dayIndex != currentDay) {
            guard.dayIndex = currentDay;
            guard.dailyCount = 0;
        }
        if (guard.dailyCount >= MAX_DAILY_PROTECTIONS) revert DailyCapReached();

        Position storage pos = positions[user];
        if (pos.debtUsdE8 == 0 || pos.collateralWei == 0 || pos.asset != guard.asset) {
            revert TriggerConditionNotMet();
        }

        uint256 hfBefore = getHealthFactorBps(user, triggerPriceE8);
        bool priceTriggered = triggerPriceE8 <= guard.stopLossPriceE8;
        bool hfTriggered = hfBefore < guard.minHealthFactorBps;
        if (!priceTriggered && !hfTriggered) revert TriggerConditionNotMet();

        uint256 debtReducedUsdE8 = (pos.debtUsdE8 * guard.repayBps) / BPS_DENOMINATOR;
        if (debtReducedUsdE8 == 0) debtReducedUsdE8 = pos.debtUsdE8;

        uint256 collateralNeededWei = (debtReducedUsdE8 * 1e18) / triggerPriceE8;
        if (collateralNeededWei > pos.collateralWei) {
            collateralNeededWei = pos.collateralWei;
            debtReducedUsdE8 = (collateralNeededWei * triggerPriceE8) / 1e18;
        }

        pos.collateralWei -= collateralNeededWei;
        pos.debtUsdE8 -= debtReducedUsdE8;

        guard.lastTriggeredAt = uint64(block.timestamp);
        guard.dailyCount += 1;

        uint256 hfAfter = getHealthFactorBps(user, triggerPriceE8);
        emit ProtectionExecuted(
            user,
            pos.asset,
            triggerPriceE8,
            debtReducedUsdE8,
            collateralNeededWei,
            hfAfter
        );
    }

    function getHealthFactorBps(address user, uint256 priceE8) public view returns (uint256) {
        Position memory pos = positions[user];
        if (pos.debtUsdE8 == 0) return type(uint256).max;
        uint256 collateralUsdE8 = (pos.collateralWei * priceE8) / 1e18;
        return (collateralUsdE8 * BPS_DENOMINATOR) / pos.debtUsdE8;
    }
}
