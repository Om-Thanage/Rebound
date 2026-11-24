// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {IPayer} from "reactive-lib/interfaces/IPayer.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
import {MockERC20, MockWETH} from "../src/mocks/MockTokens.sol";
import {MockAaveOracle} from "../src/mocks/MockAaveOracle.sol";
import {MockAggregator, MockAggregatorProxy} from "../src/mocks/MockAggregator.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";
import {LiquidationShield, IAavePool, IAaveOracle, IWETH, IERC20Lite} from "../src/LiquidationShield.sol";
import {ShieldReactive} from "../src/ShieldReactive.sol";
import {DemoLoan} from "../src/DemoLoan.sol";

/// Stands in for the Reactive system contract at 0x8888...: records subscriptions and callback requests.
contract MockSystem {
    struct Sub {
        uint256 chainId;
        address emitter;
        uint256 topic0;
    }

    Sub[] public subs;
    uint256 public unsubscriptions;
    ISystemContract.CallbackConfiguration_V_1_0[] internal callbacks;

    function subscribe(uint256 chainId, address emitter, uint256 topic0, uint256, uint256, uint256) external {
        subs.push(Sub(chainId, emitter, topic0));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        unsubscriptions++;
    }

    function subscriptions() external view returns (uint256) {
        return subs.length;
    }

    bool public light; // only count and emit, like the real system contract, for gas measurements
    uint256 public lightCount;

    event CallbackRequest(uint256 indexed chainId, address indexed sender, address indexed recipient, bytes config);

    function setLight(bool on) external {
        light = on;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        if (light) {
            lightCount++;
            emit CallbackRequest(c.chainId, msg.sender, c.recipient, abi.encode(c));
            return;
        }
        callbacks.push(c);
    }

    function callbackCount() external view returns (uint256) {
        return callbacks.length;
    }

    function callbackAt(uint256 i) external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return callbacks[i];
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function debts(address) external pure returns (uint256) {
        return 0;
    }

    /// What Reactive holds for a contract to pay its execution (fixed here; read by the dashboard and status.sh).
    function reserves(address) external pure returns (uint256) {
        return 5 ether;
    }

    receive() external payable {}
}

/// Stands in for the callback proxy on Base: delivers callbacks (injecting the reactive sender) and charges gas.
contract MockProxy {
    function deliver(address target, bytes memory payload, address reactiveSender) external {
        // overwrite the first argument (bytes 4..36) with the reactive contract's address, like the real proxy
        assembly {
            mstore(add(payload, 36), reactiveSender)
        }
        (bool ok, bytes memory err) = target.call(payload);
        if (!ok) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
    }

    function charge(address target, uint256 amount) external {
        IPayer(payable(target)).pay(amount);
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract ShieldTest is Test {
    address constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 constant ORIGIN = 84532;
    uint256 constant LEAD = 11155111;
    uint256 constant CRON_TOPIC = uint256(keccak256("Cron100(uint256)"));

    MockWETH weth;
    MockERC20 usdc;
    MockERC20 wbtc;
    MockAaveOracle oracle;
    MockAggregator aggWeth;
    MockAggregator aggWbtc;
    MockAggregator aggLead;
    MockAggregatorProxy proxyWeth;
    MockAggregatorProxy proxyWbtc;
    MockAavePool pool;
    MockProxy proxy;
    MockSystem sys;
    ShieldReactive rc;
    LiquidationShield shield;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.etch(SYSTEM_ADDR, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM_ADDR));
        vm.warp(1_800_000_000);

        weth = new MockWETH();
        usdc = new MockERC20("Test USD Coin", "tUSDC", 6);
        wbtc = new MockERC20("Test Wrapped BTC", "tWBTC", 8);
        oracle = new MockAaveOracle();
        aggWeth = new MockAggregator(address(oracle)); // the oracle's open setAssetPrice may post to it
        aggWbtc = new MockAggregator(address(oracle));
        aggLead = new MockAggregator(address(0)); // owner only
        proxyWeth = new MockAggregatorProxy(aggWeth);
        proxyWbtc = new MockAggregatorProxy(aggWbtc);
        oracle.setAssetSource(address(weth), proxyWeth);
        oracle.setAssetSource(address(wbtc), proxyWbtc);
        pool = new MockAavePool(weth, usdc, oracle);
        pool.listCollateral(address(wbtc), 7300, 7800, 10_500, 8);
        proxy = new MockProxy();
        oracle.setAssetPrice(address(weth), 2000e8);
        oracle.setAssetPrice(address(wbtc), 60_000e8);

        // the reactive contract needs the shield address and vice versa: predict the shield's address
        address predictedShield = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        rc = new ShieldReactive(_rcConfig(predictedShield));
        shield = new LiquidationShield(IPayable(payable(address(proxy))), address(rc), _shieldConfig(0));
        assertEq(address(shield), predictedShield);

        _openLoan(alice, 1 ether, 1200e6); // HF = 2000 * 0.825 / 1200 = 1.375
    }

    function _rcConfig(address shield_) internal view returns (ShieldReactive.Config memory c) {
        c.originChainId = ORIGIN;
        c.shield = shield_;
        c.assets = _pair(address(weth), address(wbtc));
        c.decimals = new uint8[](2);
        c.decimals[0] = 18;
        c.decimals[1] = 8;
        c.feeds = _pair(address(aggWeth), address(aggWbtc));
        c.proxies = _pair(address(proxyWeth), address(proxyWbtc));
        c.bucketWidths = new uint256[](2);
        c.bucketWidths[0] = 10e8; // $10 buckets for WETH
        c.bucketWidths[1] = 250e8;
        c.cronTopic = CRON_TOPIC;
        c.leadChainId = LEAD;
        c.leadFeed = address(aggLead);
        c.leadAsset = 0;
    }

    function _shieldConfig(uint256 watchFee) internal view returns (LiquidationShield.Config memory c) {
        c.pool = IAavePool(address(pool));
        c.oracle = IAaveOracle(address(oracle));
        c.weth = IWETH(address(weth));
        c.debtAsset = IERC20Lite(address(usdc));
        c.collateralAssets = _pair(address(weth), address(wbtc));
        c.aTokens = _pair(pool.aTokenOf(address(weth)), pool.aTokenOf(address(wbtc)));
        c.feeBps = 30; // 0.30%
        c.minFeeWei = 0.0001 ether;
        c.watchFeeWeiPerDay = watchFee;
    }

    function _pair(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _openLoan(address who, uint256 coll, uint256 debt) internal {
        vm.deal(who, 10 ether);
        vm.startPrank(who);
        weth.deposit{value: 5 ether}();
        weth.approve(address(pool), type(uint256).max);
        weth.approve(address(shield), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        usdc.approve(address(shield), type(uint256).max);
        pool.supply(address(weth), coll, who, 0);
        pool.borrow(address(usdc), debt, 2, 0, who);
        vm.stopPrank();
    }

    // ---- helpers that replay what the Reactive Network would do

    function _toRecord(Vm.Log memory lg, uint256 chainId) internal view returns (IReactive.LogRecord memory l) {
        l.chainId = chainId;
        l.contractAddress = lg.emitter;
        l.topic0 = uint256(lg.topics[0]);
        if (lg.topics.length > 1) l.topic1 = uint256(lg.topics[1]);
        if (lg.topics.length > 2) l.topic2 = uint256(lg.topics[2]);
        if (lg.topics.length > 3) l.topic3 = uint256(lg.topics[3]);
        l.data = lg.data;
        l.blockNumber = block.number;
    }

    /// Forward every recorded log the reactive contract is subscribed to, in order, as the network would.
    function _relayAll() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || !_subscribed(logs[i].emitter, uint256(logs[i].topics[0]))) continue;
            uint256 chainId = logs[i].emitter == address(aggLead) ? LEAD : ORIGIN;
            IReactive.LogRecord memory l = _toRecord(logs[i], chainId);
            vm.prank(SYSTEM_ADDR); // build the log first: any call in between would use up the prank
            rc.react(l);
        }
    }

    function _subscribed(address emitter, uint256 topic0) internal view returns (bool) {
        for (uint256 i; i < sys.subscriptions(); ++i) {
            (, address e, uint256 t) = sys.subs(i);
            if (e == emitter && t == topic0) return true;
        }
        return false;
    }

    function _movePrice(address asset, uint256 price) internal {
        vm.recordLogs();
        oracle.setAssetPrice(asset, price);
        _relayAll();
    }

    function _movePrice(uint256 price) internal {
        _movePrice(address(weth), price);
    }

    function _leadPrice(uint256 price) internal {
        vm.recordLogs();
        aggLead.updateAnswer(int256(price));
        _relayAll();
    }

    function _cron() internal {
        IReactive.LogRecord memory l;
        l.chainId = block.chainid;
        l.contractAddress = rc.CRON_SOURCE(); // where Lasna really emits CronN, not the system contract
        l.topic0 = CRON_TOPIC;
        vm.prank(SYSTEM_ADDR);
        rc.react(l);
    }

    function _deliver(uint256 i) internal {
        ISystemContract.CallbackConfiguration_V_1_0 memory c = sys.callbackAt(i);
        assertEq(c.chainId, ORIGIN);
        assertEq(c.recipient, address(shield));
        vm.recordLogs();
        proxy.deliver(c.recipient, c.payload, address(rc));
        _relayAll();
    }

    function _deliverLastCallback() internal {
        _deliver(sys.callbackCount() - 1);
    }

    function _protect(address who, uint256 reserve) internal {
        vm.recordLogs();
        vm.prank(who);
        shield.protect(1.15e18, 1.4e18, reserve);
        _relayAll();
    }

    function _protectAlice(uint256 reserve) internal {
        _protect(alice, reserve);
    }

    function _configure(address who, uint64 step, LiquidationShield.Mode mode) internal {
        vm.recordLogs();
        vm.prank(who);
        shield.configure(1.15e18, 1.4e18, step, mode);
        _relayAll();
    }

    function _depositRepay(address who, uint256 amount) internal {
        vm.recordLogs();
        vm.prank(who);
        shield.depositRepayReserve(amount);
        _relayAll();
    }

    function _hf(address u) internal view returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(u);
    }

    function _reserve(address u) internal view returns (uint128 r) {
        (r,,,,,,,,) = shield.protections(u);
    }

    function _repayReserve(address u) internal view returns (uint128 r) {
        (, r,,,,,,,) = shield.protections(u);
    }

    function _pending(address u) internal view returns (bool pending) {
        (,,,,,,,,,, pending,) = rc.positions(u);
    }

    function _decodeHint(uint256 i) internal view returns (uint256 hint) {
        bytes memory payload = sys.callbackAt(i).payload;
        assembly {
            hint := mload(add(payload, 100)) // 4-byte selector + 32 (sender) + 32 (user) + 32 (hint)
        }
    }

    // ---- wiring

    function test_subscribesToFeedsProxiesSnapshotsLeadAndCron() public view {
        assertEq(sys.subscriptions(), 7);
        (uint256 chainId, address emitter, uint256 topic) = sys.subs(6);
        assertEq(chainId, block.chainid, "CRON comes from Reactive Network itself");
        assertEq(emitter, 0x0000000000000000000000000000000000fffFfF, "CronN comes from the legacy system address");
        assertEq(topic, CRON_TOPIC);
        (chainId, emitter,) = sys.subs(5);
        assertEq(chainId, LEAD);
        assertEq(emitter, address(aggLead));
    }

    function test_reactOnlyFromSystem() public {
        IReactive.LogRecord memory l;
        l.chainId = ORIGIN;
        l.contractAddress = address(aggWeth);
        l.topic0 = rc.ANSWER_UPDATED_TOPIC();
        vm.expectRevert();
        rc.react(l);
    }

    function test_readsChainlinkAnswerFromTopic() public {
        _movePrice(1987e8);
        assertEq(rc.lastPrice(0), 1987e8);
        assertEq(rc.priceTicks(), 1);
    }

    // ---- the core loop

    function test_fullLoop_crashTriggersRescueToTarget() public {
        _movePrice(2000e8);
        _protectAlice(1 ether);
        assertEq(rc.collateralOf(alice, 0), 1 ether);
        assertEq(rc.userCount(), 1);

        _movePrice(1900e8); // HF 1.306, and 1.24 if it falls another $100: nothing happens
        assertEq(sys.callbackCount(), 0);

        _movePrice(1600e8); // HF 1.1: under the 1.15 trigger
        assertEq(sys.callbackCount(), 1);
        assertTrue(_pending(alice));
        assertEq(_decodeHint(0), 0, "already under: no hint needed");

        uint256 ethBefore = address(shield).balance;
        _deliverLastCallback();

        uint256 hf = _hf(alice);
        assertGe(hf, 1.4e18, "lifted to target");
        assertLt(hf, 1.401e18, "smallest top-up, not more");
        assertGt(address(shield).balance, ethBefore, "fee arrived as ETH for gas");
        assertEq(shield.rescueCount(), 1);

        // the shield's fresh snapshot clears pending and mirrors the new collateral
        assertFalse(_pending(alice));
        assertGt(rc.collateralOf(alice, 0), 1 ether);

        // the same price again does not fire another rescue
        _movePrice(1600e8);
        assertEq(sys.callbackCount(), 1);
    }

    function test_pendingBlocksDuplicateCallbacks() public {
        _protectAlice(1 ether);
        _movePrice(1600e8);
        _movePrice(1550e8);
        assertEq(sys.callbackCount(), 1);
    }

    function test_pendingExpiresWhenCallbackIsLost() public {
        _protectAlice(1 ether);
        _movePrice(1600e8);
        assertEq(sys.callbackCount(), 1);
        vm.warp(block.timestamp + 30);
        _movePrice(1590e8);
        assertEq(sys.callbackCount(), 1, "still waiting for the first callback");
        vm.warp(block.timestamp + 31);
        _movePrice(1580e8);
        assertEq(sys.callbackCount(), 2, "lost callback no longer blocks the loan");
    }

    function test_cooldownTravelsInSnapshot() public {
        _protectAlice(2 ether);
        _movePrice(1600e8);
        _deliverLastCallback();
        _movePrice(1000e8); // deep crash inside the shield's 10 s cooldown: don't waste a callback on a skip
        assertEq(sys.callbackCount(), 1);
        vm.warp(block.timestamp + 11);
        _movePrice(990e8);
        assertEq(sys.callbackCount(), 2);
        _deliverLastCallback();
        assertGe(_hf(alice), 1.4e18);
        assertEq(shield.skippedCallbacks(), 0);
    }

    function test_feesPayForCallbackGas() public {
        _protectAlice(1 ether);
        _movePrice(1600e8);
        _deliverLastCallback();

        (uint256 fees, uint256 ext,,,) = shield.opsLedger();
        assertGt(fees, 0);
        assertEq(ext, 0, "no outside money was needed");

        proxy.charge(address(shield), fees); // the proxy collects callback gas out of fee income
        (,, uint256 gasPaid, uint256 bal,) = shield.opsLedger();
        assertEq(gasPaid, fees);
        assertEq(bal, 0);
    }

    /// ETH forced in without receive() must not make the ledger revert (the dashboard reads it).
    function test_opsLedgerSurvivesForcedEth() public {
        vm.deal(address(shield), address(shield).balance + 1 ether); // what a selfdestruct would do
        (,, uint256 gasPaid, uint256 bal,) = shield.opsLedger();
        assertEq(gasPaid, 0);
        assertEq(bal, address(shield).balance);
    }

    function test_partialRescueWhenReserveIsShort() public {
        _protectAlice(0.05 ether);
        _movePrice(1600e8);
        uint256 before = _hf(alice);
        _deliverLastCallback();
        assertEq(_reserve(alice), 0, "used the whole reserve");
        assertGt(_hf(alice), before, "still improved");
    }

    /// A short reserve: the 0.3% fee is on the WETH that actually goes in, not on the full top-up the loan needed.
    function test_partialRescueChargesFeeOnWhatItSupplies() public {
        _protectAlice(0.05 ether); // the loan needs about 0.27 WETH at $1,600
        uint256 collBefore = pool.collateral(alice);
        _movePrice(1600e8);
        _deliverLastCallback();
        uint256 supplied = pool.collateral(alice) - collBefore;
        (uint256 fee,,,,,) = shield.feeBreakdown();
        assertEq(supplied + fee, 0.05 ether, "the whole reserve is used");
        assertApproxEqAbs(fee, supplied * 30 / 10_000, 1, "0.3% of what moved");
    }

    /// The example from the review: needs about 1 WETH, has 0.01. The fee is the 0.0001 ETH floor, not 0.003.
    function test_tinyReserveOnlyPaysTheFeeFloor() public {
        _movePrice(2000e8);
        _openLoan(bob, 1 ether, 1300e6);
        _protect(bob, 0.01 ether);
        _movePrice(1200e8);
        _deliverLastCallback();
        (uint256 fee,,,,,) = shield.feeBreakdown();
        assertEq(fee, 0.0001 ether);
        assertEq(_reserve(bob), 0);
    }

    function test_feelessRescueIsCounted() public {
        _protectAlice(0.00005 ether); // below the 0.0001 ETH fee floor
        _movePrice(1600e8);
        _deliverLastCallback();
        assertEq(shield.feelessRescues(), 1);
        assertEq(shield.rescueCount(), 1);
    }

    function test_skipsWhenLivePositionIsHealthy() public {
        _protectAlice(1 ether);
        _movePrice(1600e8);
        oracle.setAssetPrice(address(weth), 2000e8); // price bounced before the callback landed
        _deliverLastCallback();
        assertEq(shield.rescueCount(), 0);
        assertEq(shield.skippedCallbacks(), 1);
        assertEq(_reserve(alice), 1 ether, "nothing spent");
    }

    function test_rejectsCallerThatIsNotProxy() public {
        _protectAlice(1 ether);
        vm.expectRevert();
        shield.rescue(address(rc), alice, 0);
    }

    function test_rejectsCallbackFromOtherReactiveContract() public {
        _protectAlice(1 ether);
        _movePrice(1600e8);
        ISystemContract.CallbackConfiguration_V_1_0 memory c = sys.callbackAt(0);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xBAD), address(rc)));
        proxy.deliver(c.recipient, c.payload, address(0xBAD));
    }

    function test_cooldownBlocksBackToBackRescues() public {
        _protectAlice(1 ether);
        _movePrice(1600e8);
        _deliverLastCallback();
        oracle.setAssetPrice(address(weth), 1200e8);
        bytes memory payload = abi.encodeWithSignature("rescue(address,address,uint256)", address(0), alice, 0);
        proxy.deliver(address(shield), payload, address(rc));
        assertEq(shield.rescueCount(), 1);
        vm.warp(block.timestamp + 11);
        proxy.deliver(address(shield), payload, address(rc));
        assertEq(shield.rescueCount(), 2);
    }

    function test_rejectsBadHealthFactors() public {
        vm.prank(alice);
        vm.expectRevert(LiquidationShield.BadHealthFactors.selector);
        shield.protect(1.4e18, 1.2e18, 0);
    }

    /// Any crash the reserve can cover ends with HF at (or just above) the target.
    function testFuzz_rescueReachesTarget(uint256 price) public {
        price = bound(price, 1000e8, 1670e8); // trigger 1.15 is crossed below ~$1672
        _movePrice(2000e8);
        _protectAlice(2 ether);
        _movePrice(price);
        _deliverLastCallback();
        uint256 hf = _hf(alice);
        assertGe(hf, 1.4e18);
        assertLt(hf, 1.401e18);
    }

    // ---- early trigger (falling-price projection) and price hints

    function test_earlyTriggerRescuesBeforeTheTriggerIsCrossed() public {
        _movePrice(2000e8);
        _protectAlice(1 ether);
        _movePrice(1750e8); // HF 1.203: above 1.15, but another $250 fall (capped at 5%: $1,662.5) gives 1.143
        assertGe(_hf(alice), 1.15e18, "not under the trigger yet");
        assertEq(sys.callbackCount(), 1, "asked for a rescue on the way down");
        assertEq(rc.earlyRequests(), 1);
        assertEq(_decodeHint(0), 1662.5e8);

        _deliverLastCallback();
        assertEq(shield.rescueCount(), 1);
        // sized for the projected price, so it holds the target even if the next update is that low
        oracle.setAssetPrice(address(weth), 1662.5e8);
        assertGe(_hf(alice), 1.4e18);
    }

    function _openWbtcLoan(address who, uint256 wbtcAmount, uint256 debt) internal {
        vm.deal(who, 10 ether);
        wbtc.mint(who, wbtcAmount);
        vm.startPrank(who);
        weth.deposit{value: 5 ether}();
        weth.approve(address(shield), type(uint256).max);
        wbtc.approve(address(pool), type(uint256).max);
        pool.supply(address(wbtc), wbtcAmount, who, 0);
        pool.borrow(address(usdc), debt, 2, 0, who);
        vm.stopPrank();
    }

    /// The shield reads a hint as a WETH price, so a falling WBTC price must not send one (it would be skipped as
    /// healthy and waste the callback). Crossing the trigger still asks, without a hint.
    function test_wbtcFallAsksOnlyOnceTheTriggerIsCrossed() public {
        _openWbtcLoan(bob, 0.05e8, 1900e6); // $3,000 of WBTC at LT 0.78: HF 1.232; trigger at about $56,026
        _protect(bob, 0.5 ether);
        uint256 calls = sys.callbackCount();
        _movePrice(address(wbtc), 57_500e8); // HF 1.180; one more $2,500 step would be 1.129
        assertEq(sys.callbackCount(), calls, "no early request for WBTC");
        assertEq(rc.earlyRequests(), 0);
        _movePrice(address(wbtc), 55_000e8); // HF 1.129: under the trigger
        assertEq(sys.callbackCount(), calls + 1);
        assertEq(_decodeHint(calls), 0);
        _deliverLastCallback();
        assertEq(shield.rescueCount(), 1);
    }

    /// Aave leaves out collateral the borrower switched off. The snapshot follows the pool's own account data, so
    /// the mirror does not think such a loan is safer than it is.
    function test_snapshotFollowsThePoolWhenCollateralIsSwitchedOff() public {
        _movePrice(2000e8);
        _movePrice(address(wbtc), 60_000e8);
        _openLoan(bob, 1 ether, 1200e6);
        wbtc.mint(bob, 0.01e8);
        vm.startPrank(bob);
        wbtc.approve(address(pool), type(uint256).max);
        pool.supply(address(wbtc), 0.01e8, bob, 0); // $600 more on paper
        vm.stopPrank();
        // as if bob disabled WBTC as collateral: the pool counts only the WETH (HF 1.375)
        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(MockAavePool.getUserAccountData.selector, bob),
            abi.encode(uint256(2000e8), uint256(1200e8), uint256(0), uint256(8250), uint256(8000), uint256(1.375e18))
        );
        _protect(bob, 0.5 ether);
        assertApproxEqRel(rc.mirroredHF(bob), 1.375e18, 0.002e18, "mirror matches the pool, not the balances");
    }

    function test_slowFallDoesNotTriggerEarly() public {
        _movePrice(2000e8);
        _protectAlice(1 ether);
        _movePrice(1990e8);
        _movePrice(1980e8);
        assertEq(sys.callbackCount(), 0);
    }

    function test_hintIsClampedToFivePercent() public {
        _protectAlice(1 ether);
        // a hint far under the oracle can't make a healthy loan look under its trigger: 2000 x 0.95 still gives 1.306
        bytes memory payload = abi.encodeWithSignature("rescue(address,address,uint256)", address(0), alice, 500e8);
        proxy.deliver(address(shield), payload, address(rc));
        assertEq(shield.rescueCount(), 0);
        assertEq(shield.skippedCallbacks(), 1);
    }

    function test_leadFeedOnAnotherChainRescuesAhead() public {
        _openLoan(bob, 1 ether, 1400e6); // HF 1.179 at $2,000
        _movePrice(2000e8);
        _protect(bob, 1 ether);

        _leadPrice(1890e8); // the same feed on another chain moved first: 1890 clamps to 1900 (5%)
        assertEq(rc.leadTicks(), 1);
        assertEq(sys.callbackCount(), 1);
        assertEq(_decodeHint(0), 1900e8);

        _deliverLastCallback(); // Base oracle still says $2,000
        assertEq(shield.rescueCount(), 1);
        oracle.setAssetPrice(address(weth), 1900e8);
        assertGe(_hf(bob), 1.4e18, "ready for the Base update when it lands");
    }

    /// The lead chain's clock can lag Base's; a lead event stamped before the shield's cooldown ended still counts
    /// as "now" in Base time.
    function test_leadFeedUsesOriginClockWhenLeadClockLags() public {
        _movePrice(2000e8); // Base time is now
        // bob's mirror: 1 WETH, $1,400 debt (HF 1.18 at $2,000), and a cooldown that ended 5 s ago in Base time
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        uint256[] memory lts = new uint256[](2);
        lts[0] = 8250;
        lts[1] = 7800;
        IReactive.LogRecord memory snap;
        snap.chainId = ORIGIN;
        snap.contractAddress = address(shield);
        snap.topic0 = rc.SNAPSHOT_TOPIC();
        snap.topic1 = uint256(uint160(bob));
        snap.data = abi.encode(amounts, lts, uint256(1400e8), uint256(1.15e18), block.timestamp - 5, true);
        vm.prank(SYSTEM_ADDR);
        rc.react(snap);

        // the lead chain's clock is five minutes behind: in its own time, the cooldown hasn't ended yet
        IReactive.LogRecord memory l;
        l.chainId = LEAD;
        l.contractAddress = address(aggLead);
        l.topic0 = rc.ANSWER_UPDATED_TOPIC();
        l.topic1 = 1900e8;
        l.data = abi.encode(block.timestamp - 300);
        vm.prank(SYSTEM_ADDR);
        rc.react(l);
        assertEq(sys.callbackCount(), 1, "judged in Base time, the cooldown is over");
    }

    function test_leadFeedAboveBasePriceDoesNothing() public {
        _movePrice(2000e8);
        _protectAlice(1 ether);
        _leadPrice(2100e8);
        assertEq(sys.callbackCount(), 0);
    }

    // ---- reserves, modes and staging

    function test_repayModeRepaysDebtInsteadOfAddingCollateral() public {
        _movePrice(2000e8);
        _protectAlice(0.01 ether); // small WETH reserve: pays the fee
        _depositRepay(alice, 1000e6);
        _configure(alice, 0, LiquidationShield.Mode.Repay);

        _movePrice(1600e8);
        _deliverLastCallback();
        assertEq(pool.collateral(alice), 1 ether, "no collateral added");
        assertLt(pool.debt(alice), 1200e6, "debt repaid");
        assertGe(_hf(alice), 1.4e18);
        assertLt(_hf(alice), 1.401e18);
        assertLt(_reserve(alice), 0.01 ether, "fee came from the WETH reserve");
    }

    /// Repaying needs H / LT times less capital than topping up: 1.4 / 0.825 = 1.697.
    function test_repayNeedsLessCapitalThanTopUp() public {
        _openLoan(bob, 1 ether, 1200e6);
        _movePrice(2000e8);
        _protectAlice(1 ether);
        _protect(bob, 0.01 ether);
        _depositRepay(bob, 1000e6);
        _configure(bob, 0, LiquidationShield.Mode.Repay);

        _movePrice(1600e8);
        assertEq(sys.callbackCount(), 2);
        _deliver(0);
        _deliver(1);
        uint256 topUpUsd = (pool.collateral(alice) - 1 ether) * 1600 / 1e18; // whole dollars
        uint256 repaidUsd = (1200e6 - pool.debt(bob)) / 1e6;
        assertApproxEqRel(topUpUsd * 1e18 / repaidUsd, 1.697e18, 0.01e18);
    }

    function test_combinedModeRepaysThenTopsUp() public {
        _movePrice(2000e8);
        _protectAlice(1 ether);
        _depositRepay(alice, 50e6); // not enough to repay alone
        _configure(alice, 0, LiquidationShield.Mode.Combined);
        _movePrice(1600e8);
        _deliverLastCallback();
        assertEq(_repayReserve(alice), 0, "repay reserve used first");
        assertEq(pool.debt(alice), 1150e6);
        assertGt(pool.collateral(alice), 1 ether, "then topped up");
        assertGe(_hf(alice), 1.4e18);
    }

    function test_stagedRescueLiftsInSteps() public {
        _movePrice(2000e8);
        _protectAlice(1 ether);
        _configure(alice, 0.1e18, LiquidationShield.Mode.Collateral);
        _movePrice(1600e8);
        _deliverLastCallback();
        uint256 hf = _hf(alice);
        assertGe(hf, 1.25e18, "first stage: trigger + 0.10");
        assertLt(hf, 1.251e18);

        vm.warp(block.timestamp + 11);
        _movePrice(1400e8); // falls again: second stage
        _deliverLastCallback();
        assertGe(_hf(alice), 1.25e18);
        assertEq(shield.rescueCount(), 2);
    }

    function test_withdrawBlockedWhileUnderTrigger() public {
        _protectAlice(1 ether);
        oracle.setAssetPrice(address(weth), 1600e8);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LiquidationShield.UnderTrigger.selector, 1.1e18));
        shield.withdrawReserve(0.5 ether);
    }

    function test_unprotectReturnsEverythingAndStopsWatching() public {
        _protectAlice(1 ether);
        _depositRepay(alice, 100e6);
        uint256 wethBefore = weth.balanceOf(alice);
        vm.recordLogs();
        vm.prank(alice);
        shield.unprotect();
        _relayAll();
        assertEq(weth.balanceOf(alice), wethBefore + 1 ether);
        assertEq(_repayReserve(alice), 0);
        assertEq(rc.userCount(), 0);
        _movePrice(1000e8);
        assertEq(sys.callbackCount(), 0);
    }

    function test_withdrawingAllRemovesFromReactiveList() public {
        _protectAlice(1 ether);
        assertEq(rc.userCount(), 1);
        vm.recordLogs();
        vm.prank(alice);
        shield.withdrawReserve(1 ether);
        _relayAll();
        assertEq(rc.userCount(), 0);
    }

    // ---- griefing the reactive contract

    function test_strangerCannotSyncSomeoneElse() public {
        _protectAlice(1 ether);
        vm.prank(bob);
        vm.expectRevert(LiquidationShield.NotYourPosition.selector);
        shield.sync(alice);
    }

    function test_emptyProtectionsAreNotPublished() public {
        for (uint256 i; i < 20; ++i) {
            address sybil = address(uint160(0x5000 + i));
            vm.recordLogs();
            vm.prank(sybil);
            shield.protect(1.15e18, 1.4e18, 0); // no reserve
            vm.prank(sybil);
            shield.sync(sybil);
            assertEq(vm.getRecordedLogs().length, 0, "no snapshot, so no reactive gas spent");
        }
        assertEq(rc.userCount(), 0);
    }

    // ---- scaling: buckets by trigger price

    function test_bucketsPlaceSingleAssetLoansByTriggerPrice() public {
        _protectAlice(1 ether);
        (uint256 tp, uint256 asset) = rc.triggerPrice(alice);
        assertEq(asset, 0);
        assertApproxEqAbs(tp, 1672.73e8, 0.01e8); // 1.15 x 1200 / 0.825
        assertEq(rc.bucketSize(0, tp / 10e8), 1);
    }

    function test_priceTickOnlyChecksLoansNearTheirTrigger() public {
        _movePrice(2000e8);
        // 120 loans with trigger prices spread from about $975 to $1,970
        for (uint256 i; i < 120; ++i) {
            address u = address(uint160(0x9000 + i));
            uint256 debt = (700 + i * 6) * 1e6;
            _openLoan(u, 1 ether, debt);
            _protect(u, 0.5 ether);
        }
        assertEq(rc.userCount(), 120);
        uint256 checkedBefore = rc.positionsChecked();
        _movePrice(1960e8); // window $1,920 to $2,156: only loans whose trigger price is in it
        uint256 checked = rc.positionsChecked() - checkedBefore;
        assertGt(checked, 0);
        assertLt(checked, 20, "a tick touches a few buckets, not every loan");
    }

    /// Many loans with the same trigger share one bucket. A tick that runs out of budget in it must carry on from
    /// where it stopped, not re-walk the front of the bucket.
    function test_interruptedScanResumesInsideACrowdedBucket() public {
        _movePrice(2000e8);
        for (uint256 i; i < 150; ++i) {
            address u = address(uint160(0xB000 + i));
            _openLoan(u, 1 ether, 1300e6); // all trigger at about $1,812: one bucket
            _protect(u, 0.5 ether);
        }
        sys.setLight(true);
        _movePrice(1700e8);
        uint256 first = sys.lightCount();
        assertGt(first, 0);
        assertLt(first, 150, "one tick can't serve them all");
        assertEq(rc.resumeIdx(0), first);

        uint256 checkedBefore = rc.positionsChecked();
        _movePrice(1699e8);
        assertGt(sys.lightCount(), first);
        assertLe(rc.positionsChecked() - checkedBefore, 151 - first, "did not re-check the front of the bucket");
    }

    /// Rescues that land between two ticks take their loans out of the bucket, and the bucket's last loans move
    /// into their slots. When the interrupted scan finishes, every loan in the bucket must have been asked about.
    function test_resumedScanStillReachesLoansMovedByLandedRescues() public {
        _movePrice(2000e8);
        address[] memory users = new address[](150);
        for (uint256 i; i < 150; ++i) {
            users[i] = address(uint160(0xC000 + i));
            _openLoan(users[i], 1 ether, 1300e6); // all trigger at about $1,812: one bucket
            _protect(users[i], 0.5 ether);
        }
        _movePrice(1700e8);
        uint256 first = sys.callbackCount();
        assertGt(rc.resumeKey(0), 0, "the first tick stopped inside the bucket");
        for (uint256 i; i < 5 && i < first; ++i) {
            _deliver(i); // the snapshot moves the bucket's last loan into this one's slot
        }
        sys.setLight(true); // cheap requests from here on, so a tick serves more loans
        for (uint256 t; t < 40 && rc.resumeKey(0) != 0; ++t) {
            _movePrice((1699 - t) * 1e8);
        }
        assertEq(rc.resumeKey(0), 0, "the interrupted scan finished");
        for (uint256 i; i < 150; ++i) {
            (,,,,, uint64 lastRescueAt,,,) = shield.protections(users[i]);
            assertTrue(_pending(users[i]) || lastRescueAt > 0, "every loan asked about");
        }
    }

    /// The worst tick: a crash that puts every loan under its trigger at once. Each check is capped per tick, so
    /// react() stays under Reactive's 900,000 gas limit for a reactive transaction; the rest go on later ticks.
    function test_worstCaseTickStaysUnderReactiveGasLimit() public {
        _movePrice(2000e8);
        for (uint256 i; i < 150; ++i) {
            address u = address(uint160(0xA000 + i));
            _openLoan(u, 1 ether, (1000 + i * 3) * 1e6);
            _protect(u, 0.5 ether);
        }
        vm.recordLogs();
        oracle.setAssetPrice(address(weth), 1000e8);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        IReactive.LogRecord memory l = _toRecord(logs[logs.length - 1], ORIGIN);
        sys.setLight(true);
        vm.prank(SYSTEM_ADDR);
        uint256 g = gasleft();
        rc.react(l);
        uint256 used = g - gasleft();
        emit log_named_uint("react() gas, worst tick", used);
        emit log_named_uint("rescues requested", sys.lightCount());
        assertLt(used, 900_000);
        uint256 first = sys.lightCount();
        assertGt(first, 0);

        // the next tick skips the loans already waiting for a rescue and requests the next ones
        vm.recordLogs();
        oracle.setAssetPrice(address(weth), 999e8);
        logs = vm.getRecordedLogs();
        l = _toRecord(logs[logs.length - 1], ORIGIN);
        vm.prank(SYSTEM_ADDR);
        g = gasleft();
        rc.react(l);
        assertLt(g - gasleft(), 900_000);
        assertGt(sys.lightCount(), first, "more rescues on the next tick");
        for (uint256 i; i < 10 && sys.lightCount() < 150; ++i) {
            vm.recordLogs();
            oracle.setAssetPrice(address(weth), (998 - i) * 1e8);
            logs = vm.getRecordedLogs();
            l = _toRecord(logs[logs.length - 1], ORIGIN);
            vm.prank(SYSTEM_ADDR);
            rc.react(l);
        }
        assertEq(sys.lightCount(), 150, "every crossed loan got its rescue within a few ticks");

        // and the CRON sweep stays inside the limit too
        vm.warp(block.timestamp + 61);
        IReactive.LogRecord memory c;
        c.chainId = block.chainid;
        c.contractAddress = rc.CRON_SOURCE();
        c.topic0 = CRON_TOPIC;
        vm.prank(SYSTEM_ADDR);
        g = gasleft();
        rc.react(c);
        assertLt(g - gasleft(), 900_000);
    }

    /// What a price event costs when it rescues nobody: every event pays this, so it sets the lREACT runway.
    function test_idleTickGas() public {
        _movePrice(2000e8);
        _protectAlice(1 ether);
        _openLoan(bob, 1 ether, 1000e6);
        _protect(bob, 1 ether);
        vm.recordLogs();
        oracle.setAssetPrice(address(weth), 1990e8);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        IReactive.LogRecord memory l = _toRecord(logs[logs.length - 1], ORIGIN);
        vm.cool(address(rc)); // on chain each reactive transaction starts with cold storage
        vm.prank(SYSTEM_ADDR);
        uint256 g = gasleft();
        rc.react(l);
        uint256 used = g - gasleft();
        emit log_named_uint("idle tick gas (cold)", used);
        assertEq(sys.callbackCount(), 0);
        assertLt(used, 50_000, "empty buckets must not cost a cold read each (was 78k before the bitmap)");
    }

    // ---- several collateral assets

    function test_multiAssetLoanIsMirroredAndRescued() public {
        vm.deal(carol, 10 ether);
        wbtc.mint(carol, 1e8);
        _movePrice(2000e8);
        _movePrice(address(wbtc), 60_000e8);
        vm.startPrank(carol);
        weth.deposit{value: 5 ether}();
        weth.approve(address(pool), type(uint256).max);
        weth.approve(address(shield), type(uint256).max);
        wbtc.approve(address(pool), type(uint256).max);
        pool.supply(address(weth), 1 ether, carol, 0); // $2,000 at LT 0.825
        pool.supply(address(wbtc), 0.05e8, carol, 0); // $3,000 at LT 0.78
        pool.borrow(address(usdc), 3000e6, 2, 0, carol); // HF = (1650 + 2340) / 3000 = 1.33
        vm.stopPrank();
        _protect(carol, 2 ether);

        assertEq(rc.collateralOf(carol, 1), 0.05e8);
        (, uint256 asset) = rc.triggerPrice(carol);
        assertEq(asset, type(uint256).max, "two assets: scanned on every tick");
        assertApproxEqRel(rc.mirroredHF(carol), _hf(carol), 0.0001e18);

        _movePrice(address(wbtc), 45_000e8); // WBTC -25%: HF 1.135
        assertEq(sys.callbackCount(), 1);
        _deliverLastCallback();
        assertGe(_hf(carol), 1.4e18, "topped up with WETH to target");
        assertLt(_hf(carol), 1.401e18);
    }

    // ---- following the Chainlink aggregator

    function test_followsAggregatorReplacement() public {
        MockAggregator next = new MockAggregator(address(oracle));
        vm.recordLogs();
        proxyWeth.confirmAggregator(next);
        _relayAll();
        assertEq(rc.feeds(0), address(next));
        assertEq(rc.aggregatorSwitches(), 1);
        assertEq(sys.unsubscriptions(), 1);

        // prices now come from the new aggregator, and the old one is ignored
        _movePrice(1900e8);
        assertEq(rc.lastPrice(0), 1900e8);
        IReactive.LogRecord memory l;
        l.chainId = ORIGIN;
        l.contractAddress = address(aggWeth);
        l.topic0 = rc.ANSWER_UPDATED_TOPIC();
        l.topic1 = 1e8;
        l.data = abi.encode(block.timestamp);
        vm.prank(SYSTEM_ADDR);
        rc.react(l);
        assertEq(rc.lastPrice(0), 1900e8);
    }

    // ---- CRON: sweep and refresh

    function test_cronSweepCatchesALoanLeftUnderItsTrigger() public {
        _protectAlice(1 ether);
        _movePrice(1600e8);
        _deliverLastCallback();
        _movePrice(1100e8); // inside the cooldown: no request
        assertEq(sys.callbackCount(), 1);
        vm.warp(block.timestamp + 11); // cooldown over, but the price stands still
        _cron();
        assertEq(rc.cronTicks(), 1);
        assertEq(sys.callbackCount(), 2, "the sweep found it");
        _deliverLastCallback();
        assertGe(_hf(alice), 1.4e18);
    }

    function test_cronOnlyFromTheRealCronSource() public {
        IReactive.LogRecord memory l;
        l.chainId = block.chainid;
        l.contractAddress = SYSTEM_ADDR; // the Omni system contract does not emit CronN
        l.topic0 = CRON_TOPIC;
        vm.prank(SYSTEM_ADDR);
        rc.react(l);
        assertEq(rc.cronTicks(), 0);
        _cron();
        assertEq(rc.cronTicks(), 1);
    }

    function test_cronRefreshesStaleMirrorAfterInterest() public {
        pool.setBorrowRate(2000); // 20% a year
        _protectAlice(1 ether);
        (uint128 mirroredDebt,,,,,,,,,,,) = rc.positions(alice);
        vm.warp(block.timestamp + 30 days);
        _cron();
        assertEq(rc.refreshesRequested(), 1);
        ISystemContract.CallbackConfiguration_V_1_0 memory c = sys.callbackAt(0);
        assertEq(c.gasLimit, rc.REFRESH_GAS_LIMIT());
        _deliver(0);
        (uint128 refreshed,,,,,,,,,,,) = rc.positions(alice);
        assertGt(refreshed, mirroredDebt, "interest is now in the mirror");
        assertEq(shield.refreshCount(), 1);
    }

    // ---- watch fee

    function test_watchFeeChargedWhileProtected() public {
        LiquidationShield s2 = new LiquidationShield(IPayable(payable(address(proxy))), address(rc), _shieldConfig(0.001 ether));
        vm.startPrank(alice);
        weth.approve(address(s2), type(uint256).max);
        s2.protect(1.15e18, 1.4e18, 1 ether);
        vm.warp(block.timestamp + 2 days);
        s2.sync(alice);
        vm.stopPrank();
        (uint128 reserve,,,,,,,,) = s2.protections(alice);
        assertEq(reserve, 1 ether - 0.002 ether);
        (uint256 rescueFees, uint256 watchFees,,,,) = s2.feeBreakdown();
        assertEq(watchFees, 0.002 ether);
        assertEq(rescueFees, 0);
        assertEq(address(s2).balance, 0.002 ether, "unwrapped to ETH for gas");
    }

    // ---- review fixes

    /// Admin functions on the mocks are the deployer's alone: an open aggregator swap or source change could point
    /// the oracle at a contract that reverts and stop every price read for everyone.
    function test_mockAdminIsDeployerOnly() public {
        MockAggregator evil = new MockAggregator(address(0));
        vm.startPrank(bob);
        vm.expectRevert(MockAggregatorProxy.NotOwner.selector);
        proxyWeth.confirmAggregator(evil);
        vm.expectRevert(MockAaveOracle.NotOwner.selector);
        oracle.setAssetSource(address(weth), MockAggregatorProxy(address(evil)));
        vm.expectRevert(MockAavePool.NotOwner.selector);
        pool.setBorrowRate(10_000);
        vm.expectRevert(MockAavePool.NotOwner.selector);
        pool.listCollateral(address(usdc), 1, 1, 10_000, 6);
        vm.expectRevert(MockAggregator.NotAllowed.selector);
        aggWeth.updateAnswer(1);
        vm.expectRevert(MockAggregator.NotAllowed.selector);
        aggLead.updateAnswer(1);
        // prices too: every price event costs the reactive contract lREACT, so only the deployer and DemoLoan
        vm.expectRevert(MockAaveOracle.NotOwner.selector);
        oracle.setAssetPrice(address(weth), 1999e8);
        vm.expectRevert(MockAaveOracle.NotOwner.selector);
        oracle.setDemo(bob);
        vm.stopPrank();
        assertEq(oracle.getAssetPrice(address(weth)), 2000e8);
    }

    function test_setupPublishesOneSnapshot() public {
        vm.recordLogs();
        vm.prank(alice);
        shield.setup(1.15e18, 1.4e18, 0, LiquidationShield.Mode.Combined, 1 ether, 100e6);
        assertEq(_countSnapshots(vm.getRecordedLogs()), 1);
        assertEq(_reserve(alice), 1 ether);
        assertEq(_repayReserve(alice), 100e6);
    }

    function test_demoRunPublishesOneSnapshot() public {
        DemoLoan demo = _deployDemo();
        for (uint256 r; r < 3; ++r) {
            vm.recordLogs();
            demo.runWithMode(r == 1 ? LiquidationShield.Mode.Repay : LiquidationShield.Mode.Collateral);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(_countSnapshots(logs), 1, "one reactive transaction for the reset, not one per change");
            for (uint256 i; i < logs.length; ++i) _relayOne(logs[i]);
            _deliverLastCallback();
            vm.warp(block.timestamp + 61);
        }
    }

    /// Repay mode with an empty repay reserve tops up with WETH instead of silently dropping protection.
    function test_repayModeFallsBackToTopUpWhenRepayReserveIsEmpty() public {
        _movePrice(2000e8);
        _protectAlice(1 ether);
        _configure(alice, 0, LiquidationShield.Mode.Repay); // no repay reserve at all
        assertEq(rc.userCount(), 1, "still watched");
        _movePrice(1600e8);
        vm.expectEmit(true, false, false, false, address(shield));
        emit LiquidationShield.RepayReserveEmpty(alice);
        _deliverLastCallback();
        assertGt(pool.collateral(alice), 1 ether, "topped up with WETH");
        assertGe(_hf(alice), 1.4e18);
    }

    function _countSnapshots(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(shield) && uint256(logs[i].topics[0]) == rc.SNAPSHOT_TOPIC()) n++;
        }
    }

    function _relayOne(Vm.Log memory lg) internal {
        if (lg.topics.length == 0 || !_subscribed(lg.emitter, uint256(lg.topics[0]))) return;
        IReactive.LogRecord memory l = _toRecord(lg, lg.emitter == address(aggLead) ? LEAD : ORIGIN);
        vm.prank(SYSTEM_ADDR);
        rc.react(l);
    }

    // ---- DemoLoan: the dashboard's one-click rescue

    function _deployDemo() internal returns (DemoLoan demo) {
        oracle.setDemo(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        vm.recordLogs();
        demo = new DemoLoan{value: 0.007 ether}(weth, usdc, oracle, pool, shield, 0.003 ether);
        assertEq(oracle.demo(), address(demo));
        _relayAll();
    }

    function test_demoRunRequestsRescueOnTheFirstStep() public {
        DemoLoan demo = _deployDemo();
        assertEq(_hf(address(demo)), 1.2e18);

        for (uint256 r = 1; r <= 3; ++r) {
            uint256 before = sys.callbackCount();
            uint256 earlyBefore = rc.earlyRequests();
            vm.recordLogs();
            demo.run();
            _relayAll();
            assertEq(sys.callbackCount(), before + 1, "one rescue requested per run");
            assertEq(rc.earlyRequests(), earlyBefore + 1, "requested at the $1,950 step, before the trigger");
            _deliverLastCallback();
            assertGe(_hf(address(demo)), 1.4e18, "rescued to target");
            vm.warp(block.timestamp + 61);
        }
        // each run returns the previous top-up to the reserve, so over three runs only the fees are spent
        uint256 lastTopUp = pool.collateral(address(demo)) - demo.BASE_COLLATERAL();
        assertEq(_reserve(address(demo)) + lastTopUp, 0.003 ether - 3 * 0.0001 ether);
        assertEq(demo.runs(), 3);
    }

    function test_demoRunInRepayMode() public {
        DemoLoan demo = _deployDemo();
        for (uint256 r = 1; r <= 2; ++r) {
            vm.recordLogs();
            demo.runWithMode(LiquidationShield.Mode.Repay);
            _relayAll();
            _deliverLastCallback();
            assertGe(_hf(address(demo)), 1.4e18);
            assertEq(pool.collateral(address(demo)), demo.BASE_COLLATERAL(), "no collateral added");
            vm.warp(block.timestamp + 61);
        }
        // back to top-ups: the repaid debt is borrowed again and returned to the repay reserve
        vm.recordLogs();
        demo.run();
        _relayAll();
        assertEq(pool.debt(address(demo)), demo.DEBT());
        _deliverLastCallback();
        assertGt(pool.collateral(address(demo)), demo.BASE_COLLATERAL());
    }

    function test_demoRunHasCooldown() public {
        DemoLoan demo = _deployDemo();
        demo.run();
        vm.expectRevert(abi.encodeWithSelector(DemoLoan.TooSoon.selector, block.timestamp + 60));
        demo.run();
    }

    function test_demoTopUpAddsToReserve() public {
        DemoLoan demo = _deployDemo();
        demo.topUp{value: 0.01 ether}();
        assertEq(_reserve(address(demo)), 0.013 ether);
    }
}
