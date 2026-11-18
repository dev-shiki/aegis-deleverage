// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/PriceOracle.sol";
import "../src/ProtectedVault.sol";
import "../src/AegisDeleverage.sol";
import { AbstractPayer } from "reactive-lib/base/AbstractPayer.sol";
import { AbstractCallback } from "reactive-lib/base/AbstractCallback.sol";
import { IReactive } from "reactive-lib/interfaces/IReactive.sol";
import { ISystemContract } from "reactive-lib/interfaces/ISystemContract.sol";

contract MockOmniSystemContract {
    struct Sub {
        uint256 chainId;
        address target;
        uint256 topic0;
    }

    struct CallbackReq {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Sub[] public subscriptions;
    CallbackReq[] public callbackRequests;
    mapping(address => uint256) public debts;

    function subscribe(
        uint256 chainId_,
        address contractAddress_,
        uint256 topic0_,
        uint256,
        uint256,
        uint256
    ) external {
        subscriptions.push(Sub(chainId_, contractAddress_, topic0_));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbackRequests.push(
            CallbackReq(config_.chainId, config_.recipient, config_.gasLimit, config_.payload)
        );
    }

    function requestCallback(ISystemContract.CallbackVersion, bytes memory) external {}

    function debt(address contractAddress_) external view returns (uint256) {
        return debts[contractAddress_];
    }

    function depositTo(address) external payable {}

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function callbackCount() external view returns (uint256) {
        return callbackRequests.length;
    }

    function getCallbackRequest(uint256 idx) external view returns (CallbackReq memory) {
        return callbackRequests[idx];
    }

    receive() external payable {}
}

contract AegisDeleverageTest is Test {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    address internal constant ETH_ASSET = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    address internal constant OMNI_SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;

    PriceOracle internal oracle;
    ProtectedVault internal vault;
    AegisDeleverage internal aegis;
    MockOmniSystemContract internal mockSystem;

    address internal callbackProxy = makeAddr("omniCallbackProxy");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.deal(alice, 50 ether);
        vm.deal(bob, 50 ether);

        MockOmniSystemContract sysImpl = new MockOmniSystemContract();
        vm.etch(OMNI_SYSTEM_ADDR, address(sysImpl).code);
        mockSystem = MockOmniSystemContract(payable(OMNI_SYSTEM_ADDR));

        oracle = new PriceOracle();
        oracle.setPrice(ETH_ASSET, 2500e8); // $2,500.00

        vault = new ProtectedVault{value: 1 ether}(callbackProxy, address(oracle));
        aegis = new AegisDeleverage{value: 1 ether}(
            BASE_SEPOLIA_CHAIN_ID,
            BASE_SEPOLIA_CHAIN_ID,
            address(oracle),
            address(vault)
        );
        vault.setCallbackSender(address(aegis));
    }

    function test_SubscriptionsAndReserveAccounting() public view {
        assertEq(mockSystem.subscriptionCount(), 2);
        assertEq(vault.callbackSender(), address(aegis));
        assertEq(vault.callbackGasReserveWei(), 1 ether);
        assertEq(vault.totalUserCollateralWei(), 0);
    }

    function test_EndToEnd_OriginToOmniSystemToCallback() public {
        vm.startPrank(alice);
        vault.deposit{value: 10 ether}(ETH_ASSET);
        vault.borrow(15_000e8); // $15,000 debt against $25,000 collateral (HF = 166.66%)
        vault.configureGuard(ETH_ASSET, 2000e8, 13_000, 4_000, 60, true);
        vm.stopPrank();

        assertEq(vault.totalUserCollateralWei(), 10 ether);
        assertEq(vault.callbackGasReserveWei(), 1 ether);

        // 1. Feed GuardConfigured log from Omni System Contract
        IReactive.LogRecord memory cfgLog = _guardConfigLog(alice, ETH_ASSET, 2000e8, 13_000, true, 100);
        vm.prank(OMNI_SYSTEM_ADDR);
        aegis.react(cfgLog);

        (address watchedAsset, uint256 stopLoss,,, bool enabled) = aegis.watchedGuards(alice);
        assertEq(watchedAsset, ETH_ASSET);
        assertEq(stopLoss, 2000e8);
        assertTrue(enabled);

        // 2. Safe price ($2,100 > $2,000 stop-loss) must not request callback
        IReactive.LogRecord memory safeLog = _priceUpdatedLog(ETH_ASSET, 2500e8, 2100e8, 101);
        vm.prank(OMNI_SYSTEM_ADDR);
        aegis.react(safeLog);
        assertEq(mockSystem.callbackCount(), 0);

        // 3. Crash price ($1,800 <= $2,000 stop-loss) requests Omni callback
        IReactive.LogRecord memory crashLog = _priceUpdatedLog(ETH_ASSET, 2100e8, 1800e8, 102);
        vm.prank(OMNI_SYSTEM_ADDR);
        aegis.react(crashLog);
        assertEq(mockSystem.callbackCount(), 1);
        assertEq(aegis.triggersDispatched(), 1);

        // 4. Simulate Omni Callback Proxy injecting AegisDeleverage address into arg0
        bytes memory relayedPayload = _injectSender(mockSystem.getCallbackRequest(0).payload, address(aegis));
        vm.prank(callbackProxy);
        (bool ok,) = address(vault).call(relayedPayload);
        assertTrue(ok, "Omni callback execution failed");

        (, uint256 collateralAfter, uint256 debtAfter) = vault.positions(alice);
        assertEq(debtAfter, 9_000e8);
        assertEq(vault.totalUserCollateralWei(), collateralAfter);
        assertGe(vault.callbackGasReserveWei(), 1 ether);
        assertGt(vault.getHealthFactorBps(alice, 1800e8), 12_000);
    }

    function test_MultiUserSimultaneousBatchDispatchAndDedupe() public {
        vm.startPrank(alice);
        vault.deposit{value: 4 ether}(ETH_ASSET);
        vault.borrow(5_000e8);
        vault.configureGuard(ETH_ASSET, 2000e8, 13_000, 2_500, 5, true);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.deposit{value: 4 ether}(ETH_ASSET);
        vault.borrow(5_000e8);
        vault.configureGuard(ETH_ASSET, 1900e8, 13_000, 2_500, 5, true);
        vm.stopPrank();

        IReactive.LogRecord memory aliceCfg = _guardConfigLog(alice, ETH_ASSET, 2000e8, 13_000, true, 200);
        IReactive.LogRecord memory bobCfg = _guardConfigLog(bob, ETH_ASSET, 1900e8, 13_000, true, 201);
        vm.prank(OMNI_SYSTEM_ADDR);
        aegis.react(aliceCfg);
        vm.prank(OMNI_SYSTEM_ADDR);
        aegis.react(bobCfg);
        assertEq(aegis.getAssetWatcherCount(ETH_ASSET), 2);

        // Crash to $1,800 in block 205 qualifies BOTH alice ($2,000) and bob ($1,900) in one Oracle tick
        IReactive.LogRecord memory batchCrash = _priceUpdatedLog(ETH_ASSET, 2500e8, 1800e8, 205);
        vm.prank(OMNI_SYSTEM_ADDR);
        aegis.react(batchCrash);
        assertEq(mockSystem.callbackCount(), 2);

        // Same block replay must not dispatch duplicates
        IReactive.LogRecord memory replayCrash = _priceUpdatedLog(ETH_ASSET, 1800e8, 1750e8, 205);
        vm.prank(OMNI_SYSTEM_ADDR);
        aegis.react(replayCrash);
        assertEq(mockSystem.callbackCount(), 2);
    }

    function test_CascadingMultiStepDeleverage() public {
        vm.startPrank(alice);
        vault.deposit{value: 5 ether}(ETH_ASSET);
        vault.borrow(7_500e8);
        vault.configureGuard(ETH_ASSET, 2000e8, 13_000, 2_500, 5, true);
        vm.stopPrank();

        IReactive.LogRecord memory cfg = _guardConfigLog(alice, ETH_ASSET, 2000e8, 13_000, true, 300);
        vm.prank(OMNI_SYSTEM_ADDR);
        aegis.react(cfg);

        uint256[3] memory prices = [uint256(1950e8), uint256(1750e8), uint256(1550e8)];
        for (uint256 i = 0; i < 3; ++i) {
            vm.warp(block.timestamp + 6);
            IReactive.LogRecord memory pLog = _priceUpdatedLog(ETH_ASSET, 2000e8, prices[i], 301 + i);
            vm.prank(OMNI_SYSTEM_ADDR);
            aegis.react(pLog);

            bytes memory payload = _injectSender(mockSystem.getCallbackRequest(i).payload, address(aegis));
            vm.prank(callbackProxy);
            (bool ok,) = address(vault).call(payload);
            assertTrue(ok);
        }

        (, , uint256 finalDebt) = vault.positions(alice);
        // 7500 * 0.75^3 = 3164.0625e8
        assertLt(finalDebt, 3_200e8);
        assertGt(finalDebt, 3_100e8);
    }

    function test_CrossChainOriginBaseToUnichainTarget() public {
        AegisDeleverage crossChainAegis = new AegisDeleverage{value: 1 ether}(
            BASE_SEPOLIA_CHAIN_ID,
            UNICHAIN_SEPOLIA_CHAIN_ID,
            address(oracle),
            address(vault)
        );
        IReactive.LogRecord memory cfg = _guardConfigLog(alice, ETH_ASSET, 2000e8, 13_000, true, 400);
        IReactive.LogRecord memory pLog = _priceUpdatedLog(ETH_ASSET, 2500e8, 1800e8, 401);

        vm.prank(OMNI_SYSTEM_ADDR);
        crossChainAegis.react(cfg);
        vm.prank(OMNI_SYSTEM_ADDR);
        crossChainAegis.react(pLog);

        uint256 idx = mockSystem.callbackCount() - 1;
        assertEq(mockSystem.getCallbackRequest(idx).chainId, UNICHAIN_SEPOLIA_CHAIN_ID);
    }

    function test_OnlySystemCanInvokeReact() public {
        IReactive.LogRecord memory dummy = _priceUpdatedLog(ETH_ASSET, 2500e8, 1800e8, 50);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, alice, OMNI_SYSTEM_ADDR)
        );
        aegis.react(dummy);
    }

    function test_CallbackSecurityAndSafetyCaps() public {
        vm.startPrank(alice);
        vault.deposit{value: 10 ether}(ETH_ASSET);
        vault.borrow(15_000e8);
        vault.configureGuard(ETH_ASSET, 2000e8, 13_000, 1_000, 60, true);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, alice, callbackProxy)
        );
        vault.executeProtection(address(aegis), alice, 1800e8, 102);

        vm.prank(callbackProxy);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, alice, address(aegis))
        );
        vault.executeProtection(alice, alice, 1800e8, 102);

        vm.prank(callbackProxy);
        vault.executeProtection(address(aegis), alice, 1800e8, 102);

        vm.prank(callbackProxy);
        vm.expectRevert(ProtectedVault.CooldownActive.selector);
        vault.executeProtection(address(aegis), alice, 1800e8, 103);

        for (uint256 i = 1; i < 5; ++i) {
            vm.warp(block.timestamp + 61);
            vm.prank(callbackProxy);
            vault.executeProtection(address(aegis), alice, 1800e8, 103 + i);
        }
        vm.warp(block.timestamp + 61);
        vm.prank(callbackProxy);
        vm.expectRevert(ProtectedVault.DailyCapReached.selector);
        vault.executeProtection(address(aegis), alice, 1800e8, 109);
    }

    function test_PausedCircuitBreaker() public {
        vm.startPrank(alice);
        vault.deposit{value: 10 ether}(ETH_ASSET);
        vault.borrow(10_000e8);
        vault.configureGuard(ETH_ASSET, 2000e8, 13_000, 2_000, 60, true);
        vm.stopPrank();

        vault.setPaused(true);
        vm.prank(callbackProxy);
        vm.expectRevert(ProtectedVault.ContractPaused.selector);
        vault.executeProtection(address(aegis), alice, 1800e8, 102);
    }

    function testFuzz_DeleverageConservesDebtAndCollateral(
        uint96 depositWeiRaw,
        uint64 debtUsdRaw,
        uint16 repayBpsRaw,
        uint64 crashPriceRaw
    ) public {
        uint256 depositWei = bound(uint256(depositWeiRaw), 1 ether, 100 ether);
        uint256 maxBorrow = (depositWei * 2500e8 / 1e18) * 10_000 / 12_000;
        uint256 debtUsdE8 = bound(uint256(debtUsdRaw), 100e8, maxBorrow > 100e8 ? maxBorrow : 100e8);
        uint256 repayBps = bound(uint256(repayBpsRaw), 100, 5_000);
        uint256 crashPriceE8 = bound(uint256(crashPriceRaw), 500e8, 1900e8);

        vm.deal(alice, depositWei);
        vm.startPrank(alice);
        vault.deposit{value: depositWei}(ETH_ASSET);
        vault.borrow(debtUsdE8);
        vault.configureGuard(ETH_ASSET, 2000e8, 13_000, repayBps, 30, true);
        vm.stopPrank();

        vm.prank(callbackProxy);
        vault.executeProtection(address(aegis), alice, crashPriceE8, 300);

        (, uint256 colAfter, uint256 debtAfter) = vault.positions(alice);
        assertLe(colAfter, depositWei);
        assertLt(debtAfter, debtUsdE8);
        assertEq(vault.totalUserCollateralWei(), colAfter);
    }

    function _guardConfigLog(
        address user,
        address asset,
        uint256 stopLossE8,
        uint256 minHfBps,
        bool enabled,
        uint256 blockNum
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(vault),
            topic0: aegis.GUARD_CONFIGURED_TOPIC_0(),
            topic1: uint256(uint160(user)),
            topic2: uint256(uint160(asset)),
            topic3: 0,
            data: abi.encode(stopLossE8, minHfBps, enabled),
            blockNumber: blockNum,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _priceUpdatedLog(
        address asset,
        uint256 oldPriceE8,
        uint256 newPriceE8,
        uint256 blockNum
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(oracle),
            topic0: aegis.PRICE_UPDATED_TOPIC_0(),
            topic1: uint256(uint160(asset)),
            topic2: 0,
            topic3: 0,
            data: abi.encode(oldPriceE8, newPriceE8, block.timestamp),
            blockNumber: blockNum,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _injectSender(bytes memory payload, address sender) internal pure returns (bytes memory) {
        bytes memory out = new bytes(payload.length);
        for (uint256 i = 0; i < payload.length; ++i) {
            out[i] = payload[i];
        }
        bytes32 encoded = bytes32(uint256(uint160(sender)));
        for (uint256 i = 0; i < 32; ++i) {
            out[4 + i] = encoded[i];
        }
        return out;
    }
}
