// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "../src/PriceOracle.sol";
import "../src/ProtectedVault.sol";
import "../src/ReactiveVaultGuard.sol";
import "reactive-lib/interfaces/IReactive.sol";
import "reactive-lib/interfaces/ISystemContract.sol";

contract MockSystemContract {
    struct Sub {
        uint256 chainId;
        address target;
        uint256 topic0;
    }

    Sub[] public subscriptions;
    mapping(address => uint256) public debts;

    function subscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256,
        uint256,
        uint256
    ) external {
        subscriptions.push(Sub(chain_id, _contract, topic_0));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function debt(address _contract) external view returns (uint256) {
        return debts[_contract];
    }

    function depositTo(address) external payable {}

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    receive() external payable {}
}

contract ReactiveVaultGuardTest is Test {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    address internal constant ETH_ASSET = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    address internal constant SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;

    bytes32 internal constant CALLBACK_SIG =
        keccak256("Callback(uint256,address,uint64,bytes)");

    PriceOracle internal oracle;
    ProtectedVault internal vault;
    ReactiveVaultGuard internal reactiveGuard;

    address internal deployer = address(this);
    address internal callbackProxy = makeAddr("callbackProxy");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.deal(alice, 50 ether);

        oracle = new PriceOracle();
        oracle.setPrice(ETH_ASSET, 2500e8); // $2,500.00

        vault = new ProtectedVault(callbackProxy, address(oracle));

        // SYSTEM_ADDR has no code in default Foundry EVM, so ReactiveVaultGuard initializes in ReactVM mode (vm == true).
        reactiveGuard = new ReactiveVaultGuard(
            BASE_SEPOLIA_CHAIN_ID,
            BASE_SEPOLIA_CHAIN_ID,
            address(oracle),
            address(vault)
        );
    }

    function test_EndToEnd_OriginToReactiveToCallback() public {
        vm.startPrank(alice);
        vault.deposit{value: 10 ether}(ETH_ASSET);
        vault.borrow(15_000e8); // $15,000 debt against $25,000 collateral (HF = 166.66%)
        vault.configureGuard(ETH_ASSET, 2000e8, 13_000, 4_000, 60, true);
        vm.stopPrank();

        // 1. Feed GuardConfigured log into ReactVM
        IReactive.LogRecord memory configLog = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(vault),
            topic_0: reactiveGuard.GUARD_CONFIGURED_TOPIC_0(),
            topic_1: uint256(uint160(alice)),
            topic_2: uint256(uint160(ETH_ASSET)),
            topic_3: 0,
            data: abi.encode(uint256(2000e8), uint256(13_000), true),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        reactiveGuard.react(configLog);

        (address watchedAsset, uint256 stopLoss,, , bool enabled) = reactiveGuard.watchedGuards(alice);
        assertEq(watchedAsset, ETH_ASSET);
        assertEq(stopLoss, 2000e8);
        assertTrue(enabled);

        // 2. Price drops to $2,100 (above $2,000 stop-loss) -> no Callback emitted
        vm.recordLogs();
        IReactive.LogRecord memory safePriceLog = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(oracle),
            topic_0: reactiveGuard.PRICE_UPDATED_TOPIC_0(),
            topic_1: uint256(uint160(ETH_ASSET)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(uint256(2500e8), uint256(2100e8), block.timestamp),
            block_number: 101,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        reactiveGuard.react(safePriceLog);
        assertEq(_findCallbackPayloads(vm.getRecordedLogs()).length, 0);

        // 3. Price drops to $1,800 (below $2,000 stop-loss) -> Callback emitted
        vm.recordLogs();
        IReactive.LogRecord memory crashPriceLog = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(oracle),
            topic_0: reactiveGuard.PRICE_UPDATED_TOPIC_0(),
            topic_1: uint256(uint160(ETH_ASSET)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(uint256(2100e8), uint256(1800e8), block.timestamp),
            block_number: 102,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        reactiveGuard.react(crashPriceLog);

        bytes[] memory payloads = _findCallbackPayloads(vm.getRecordedLogs());
        assertEq(payloads.length, 1);

        // 4. Simulate Reactive Callback Proxy delivering the payload with rvmId injected as arg0
        bytes memory relayedPayload = _injectRvmId(payloads[0], deployer);
        vm.prank(callbackProxy);
        (bool ok,) = address(vault).call(relayedPayload);
        assertTrue(ok, "Callback execution failed");

        // Verify deleveraging: 40% of $15,000 = $6,000 repaid -> $9,000 debt left
        (, uint256 collateralAfter, uint256 debtAfter) = vault.positions(alice);
        assertEq(debtAfter, 9_000e8);
        // 6000e8 / 1800e8 = 3.333333333333333333 ETH used -> 6.666666666666666667 ETH left
        assertLt(collateralAfter, 10 ether);
        assertGt(vault.getHealthFactorBps(alice, 1800e8), 12_000);
    }

    function test_SubscriptionsRegisteredOnReactiveNetwork() public {
        MockSystemContract mockSys = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mockSys).code);

        ReactiveVaultGuard rnGuard = new ReactiveVaultGuard(
            BASE_SEPOLIA_CHAIN_ID,
            BASE_SEPOLIA_CHAIN_ID,
            address(oracle),
            address(vault)
        );

        assertEq(MockSystemContract(payable(SYSTEM_ADDR)).subscriptionCount(), 2);

        // Calling react() on top-level RN (vm == false) must revert
        IReactive.LogRecord memory dummy;
        vm.expectRevert("VM only");
        rnGuard.react(dummy);
    }

    function test_CallbackSecurityAndSafetyCaps() public {
        vm.startPrank(alice);
        vault.deposit{value: 10 ether}(ETH_ASSET);
        vault.borrow(15_000e8);
        vault.configureGuard(ETH_ASSET, 2000e8, 13_000, 1_000, 60, true);
        vm.stopPrank();

        // Unauthorized sender rejected
        vm.prank(alice);
        vm.expectRevert("Authorized sender only");
        vault.executeProtection(deployer, alice, 1800e8);

        // Wrong RVM ID rejected
        vm.prank(callbackProxy);
        vm.expectRevert("Authorized RVM ID only");
        vault.executeProtection(alice, alice, 1800e8);

        // Valid execution
        vm.prank(callbackProxy);
        vault.executeProtection(deployer, alice, 1800e8);

        // Cooldown enforced
        vm.prank(callbackProxy);
        vm.expectRevert(ProtectedVault.CooldownActive.selector);
        vault.executeProtection(deployer, alice, 1800e8);

        // Daily cap enforced after 5 executions
        for (uint256 i = 1; i < 5; ++i) {
            vm.warp(block.timestamp + 61);
            vm.prank(callbackProxy);
            vault.executeProtection(deployer, alice, 1800e8);
        }
        vm.warp(block.timestamp + 61);
        vm.prank(callbackProxy);
        vm.expectRevert(ProtectedVault.DailyCapReached.selector);
        vault.executeProtection(deployer, alice, 1800e8);
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
        vault.executeProtection(deployer, alice, 1800e8);
    }

    function test_MultiUserIsolationAndSameBlockDedupe() public {
        address bob = makeAddr("bob");
        vm.deal(bob, 20 ether);

        // Configure alice at $2,000 stop-loss and bob at $1,500 stop-loss
        reactiveGuard.react(_guardConfigLog(alice, ETH_ASSET, 2000e8, 13_000, true, 200));
        reactiveGuard.react(_guardConfigLog(bob, ETH_ASSET, 1500e8, 13_000, true, 201));
        assertEq(reactiveGuard.getAssetWatcherCount(ETH_ASSET), 2);

        // Crash to $1,800 in block 205 -> only alice qualifies
        vm.recordLogs();
        reactiveGuard.react(_priceUpdatedLog(ETH_ASSET, 2500e8, 1800e8, 205));
        bytes[] memory payloads = _findCallbackPayloads(vm.getRecordedLogs());
        assertEq(payloads.length, 1);
        (, address triggeredUser,) = abi.decode(_sliceSelector(payloads[0]), (address, address, uint256));
        assertEq(triggeredUser, alice);

        // Same block replay must not emit a duplicate callback for alice
        vm.recordLogs();
        reactiveGuard.react(_priceUpdatedLog(ETH_ASSET, 1800e8, 1750e8, 205));
        assertEq(_findCallbackPayloads(vm.getRecordedLogs()).length, 0);
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
        vault.executeProtection(deployer, alice, crashPriceE8);

        (, uint256 colAfter, uint256 debtAfter) = vault.positions(alice);
        assertLe(colAfter, depositWei);
        assertLt(debtAfter, debtUsdE8);
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
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(vault),
            topic_0: reactiveGuard.GUARD_CONFIGURED_TOPIC_0(),
            topic_1: uint256(uint160(user)),
            topic_2: uint256(uint160(asset)),
            topic_3: 0,
            data: abi.encode(stopLossE8, minHfBps, enabled),
            block_number: blockNum,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _priceUpdatedLog(
        address asset,
        uint256 oldPriceE8,
        uint256 newPriceE8,
        uint256 blockNum
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(oracle),
            topic_0: reactiveGuard.PRICE_UPDATED_TOPIC_0(),
            topic_1: uint256(uint160(asset)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(oldPriceE8, newPriceE8, block.timestamp),
            block_number: blockNum,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _sliceSelector(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i = 4; i < data.length; ++i) {
            out[i - 4] = data[i];
        }
    }

    function _findCallbackPayloads(Vm.Log[] memory logs) internal pure returns (bytes[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == CALLBACK_SIG) count++;
        }
        bytes[] memory result = new bytes[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == CALLBACK_SIG) {
                result[idx++] = abi.decode(logs[i].data, (bytes));
            }
        }
        return result;
    }

    function _injectRvmId(bytes memory payload, address rvmId) internal pure returns (bytes memory) {
        bytes memory out = new bytes(payload.length);
        for (uint256 i = 0; i < payload.length; ++i) {
            out[i] = payload[i];
        }
        // Overwrite bytes [4..36] (first ABI-encoded address arg) with rvmId
        bytes32 encoded = bytes32(uint256(uint160(rvmId)));
        for (uint256 i = 0; i < 32; ++i) {
            out[4 + i] = encoded[i];
        }
        return out;
    }
}
