// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractCallback } from "reactive-lib/base/AbstractCallback.sol";
import { IPayable } from "reactive-lib/interfaces/IPayable.sol";
import "./PriceOracle.sol";

/// @title ProtectedVault
/// @notice Destination-chain collateral vault protected by Reactive Omni cross-chain callbacks.
contract ProtectedVault is AbstractCallback {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_BORROW_HF_BPS = 12_000; // 120% collateralization
    uint256 public constant MAX_REPAY_BPS = 5_000; // Cap single deleverage at 50%
    uint16 public constant MAX_DAILY_PROTECTIONS = 5;

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
    address public callbackSender;
    uint256 public totalUserCollateralWei;
    bool public paused;
    uint256 private _lock = 1;

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
        uint256 newHealthFactorBps,
        uint256 originBlock
    );
    event PausedSet(bool paused);
    event CallbackSenderUpdated(address indexed oldSender, address indexed newSender);
    event CallbackReserveFunded(address indexed sender, uint256 amountWei);

    error Unauthorized();
    error ContractPaused();
    error Reentrancy();
    error ZeroAmount();
    error InvalidAsset();
    error InsufficientCollateral();
    error UnhealthyPosition();
    error InvalidGuardConfig();
    error GuardNotEnabled();
    error CooldownActive();
    error DailyCapReached();
    error TriggerConditionNotMet();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address _callbackProxy, address _priceOracle)
        AbstractCallback(IPayable(payable(_callbackProxy)), address(0))
        payable
    {
        owner = msg.sender;
        priceOracle = PriceOracle(_priceOracle);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    function setCallbackSender(address _callbackSender) external onlyOwner {
        if (_callbackSender == address(0)) revert Unauthorized();
        address old = callbackSender;
        callbackSender = _callbackSender;
        emit CallbackSenderUpdated(old, _callbackSender);
    }

    function fundCallbackReserve() external payable {
        if (msg.value == 0) revert ZeroAmount();
        emit CallbackReserveFunded(msg.sender, msg.value);
    }

    function callbackGasReserveWei() external view returns (uint256) {
        if (address(this).balance <= totalUserCollateralWei) return 0;
        return address(this).balance - totalUserCollateralWei;
    }

    function deposit(address asset) external payable whenNotPaused {
        if (msg.value == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender];
        if (pos.collateralWei > 0 && pos.asset != asset) revert InvalidAsset();
        pos.asset = asset;
        pos.collateralWei += msg.value;
        totalUserCollateralWei += msg.value;
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

    function withdraw(uint256 amountWei) external whenNotPaused nonReentrant {
        if (amountWei == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender];
        if (pos.collateralWei < amountWei) revert InsufficientCollateral();

        pos.collateralWei -= amountWei;
        totalUserCollateralWei -= amountWei;
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

        GuardConfig storage guard = guards[msg.sender];
        guard.asset = asset;
        guard.stopLossPriceE8 = stopLossPriceE8;
        guard.minHealthFactorBps = minHealthFactorBps;
        guard.repayBps = repayBps;
        guard.cooldownSeconds = cooldownSeconds;
        guard.enabled = enabled;

        emit GuardConfigured(msg.sender, asset, stopLossPriceE8, minHealthFactorBps, enabled);
    }

    /// @notice Invoked by the Reactive Omni Callback Proxy when AegisDeleverage requests a callback.
    /// @dev Reactive Omni injects the calling reactive contract address into `callbackSender_`.
    function executeProtection(
        address callbackSender_,
        address user,
        uint256 triggerPriceE8,
        uint256 originBlock
    ) external onlyServiceProvider whenNotPaused nonReentrant {
        if (callbackSender == address(0) || callbackSender_ != callbackSender) {
            revert CallbackNotAuthorized(callbackSender_, callbackSender);
        }

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

        if (
            triggerPriceE8 > guard.stopLossPriceE8 &&
            getHealthFactorBps(user, triggerPriceE8) >= guard.minHealthFactorBps
        ) {
            revert TriggerConditionNotMet();
        }

        uint256 debtReducedUsdE8 = (pos.debtUsdE8 * guard.repayBps) / BPS_DENOMINATOR;
        if (debtReducedUsdE8 == 0) debtReducedUsdE8 = pos.debtUsdE8;

        uint256 collateralNeededWei = (debtReducedUsdE8 * 1e18) / triggerPriceE8;
        if (collateralNeededWei > pos.collateralWei) {
            collateralNeededWei = pos.collateralWei;
            debtReducedUsdE8 = (collateralNeededWei * triggerPriceE8) / 1e18;
        }

        pos.collateralWei -= collateralNeededWei;
        totalUserCollateralWei -= collateralNeededWei;
        pos.debtUsdE8 -= debtReducedUsdE8;

        guard.lastTriggeredAt = uint64(block.timestamp);
        guard.dailyCount += 1;

        emit ProtectionExecuted(
            user,
            pos.asset,
            triggerPriceE8,
            debtReducedUsdE8,
            collateralNeededWei,
            getHealthFactorBps(user, triggerPriceE8),
            originBlock
        );
    }

    function getHealthFactorBps(address user, uint256 priceE8) public view returns (uint256) {
        Position memory pos = positions[user];
        if (pos.debtUsdE8 == 0) return type(uint256).max;
        uint256 collateralUsdE8 = (pos.collateralWei * priceE8) / 1e18;
        return (collateralUsdE8 * BPS_DENOMINATOR) / pos.debtUsdE8;
    }
}
