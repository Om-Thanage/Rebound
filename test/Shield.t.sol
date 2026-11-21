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
import {MockAavePool} from "../src/mocks/MockAavePool.sol";
import {LiquidationShield, IAavePool, IAaveOracle, IWETH} from "../src/LiquidationShield.sol";
import {ShieldReactive} from "../src/ShieldReactive.sol";

/// Stands in for the Reactive system contract at 0x8888...: records subscriptions and callback requests.
contract MockSystem {
    uint256 public subscriptions;
    ISystemContract.CallbackConfiguration_V_1_0[] internal callbacks;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscriptions++;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
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

    MockWETH weth;
    MockERC20 usdc;
    MockAaveOracle oracle;
    MockAavePool pool;
    MockProxy proxy;
    MockSystem sys;
    ShieldReactive rc;
    LiquidationShield shield;

    address alice = makeAddr("alice");

    function setUp() public {
        vm.etch(SYSTEM_ADDR, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM_ADDR));

        weth = new MockWETH();
        usdc = new MockERC20("Test USD Coin", "tUSDC", 6);
        oracle = new MockAaveOracle();
        pool = new MockAavePool(weth, usdc, oracle);
        proxy = new MockProxy();
        oracle.setAssetPrice(address(weth), 2000e8);

        // reactive contract needs the shield address and vice versa: predict the shield's address
        address predictedShield = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        rc = new ShieldReactive(ORIGIN, address(oracle), predictedShield, address(weth));
        shield = new LiquidationShield(
            IPayable(payable(address(proxy))),
            address(rc),
            IAavePool(address(pool)),
            IAaveOracle(address(oracle)),
            IWETH(address(weth)),
            30, // 0.30%
            0.0001 ether
        );
        assertEq(address(shield), predictedShield);

        // alice: 1 WETH collateral at $2000, borrows $1500 -> HF = 2000*0.825/1500 = 1.1
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        weth.deposit{value: 3 ether}();
        weth.approve(address(pool), type(uint256).max);
        weth.approve(address(shield), type(uint256).max);
        pool.supply(address(weth), 1 ether, alice, 0);
        pool.borrow(address(usdc), 1200e6, 2, 0, alice); // HF = 2000*0.825/1200 = 1.375
        vm.stopPrank();
    }

    // ---- helpers that replay what the Reactive Network would do

    function _log(address emitter, uint256 topic0, uint256 topic1, bytes memory data)
        internal
        view
        returns (IReactive.LogRecord memory l)
    {
        l.chainId = ORIGIN;
        l.contractAddress = emitter;
        l.topic0 = topic0;
        l.topic1 = topic1;
        l.data = data;
        l.blockNumber = block.number;
    }

    /// Forward every PositionSnapshot the shield just emitted into the reactive contract.
    function _relaySnapshots() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(shield) && uint256(logs[i].topics[0]) == rc.SNAPSHOT_TOPIC()) {
                IReactive.LogRecord memory l = _log(address(shield), rc.SNAPSHOT_TOPIC(), uint256(logs[i].topics[1]), logs[i].data);
                vm.prank(SYSTEM_ADDR); // build the log first: any call in between would use up the prank
                rc.react(l);
            }
        }
    }

    function _movePrice(uint256 price) internal {
        oracle.setAssetPrice(address(weth), price);
        IReactive.LogRecord memory l =
            _log(address(oracle), rc.PRICE_UPDATED_TOPIC(), uint256(uint160(address(weth))), abi.encode(price, block.timestamp));
        vm.prank(SYSTEM_ADDR);
        rc.react(l);
    }

    function _deliverLastCallback() internal {
        ISystemContract.CallbackConfiguration_V_1_0 memory c = sys.callbackAt(sys.callbackCount() - 1);
        assertEq(c.chainId, ORIGIN);
        assertEq(c.recipient, address(shield));
        proxy.deliver(c.recipient, c.payload, address(rc));
    }

    function _protectAlice(uint256 reserve) internal {
        vm.recordLogs();
        vm.prank(alice);
        shield.protect(1.15e18, 1.4e18, reserve);
        _relaySnapshots();
    }

    function _hf(address u) internal view returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(u);
    }

    // ---- tests

    function test_subscribesToPriceAndSnapshots() public view {
        assertEq(sys.subscriptions(), 2);
    }

    function test_fullLoop_crashTriggersRescueToTarget() public {
        _protectAlice(1 ether);
        (uint128 coll,,,, bool active,,) = rc.positions(alice);
        assertEq(coll, 1 ether);
        assertTrue(active);

        _movePrice(1900e8); // HF 1.306: above trigger, nothing happens
        assertEq(sys.callbackCount(), 0);

        _movePrice(1600e8); // HF 1.1: under the 1.15 trigger
        assertEq(sys.callbackCount(), 1);
        (,,,,, bool pending,) = rc.positions(alice);
        assertTrue(pending);

        uint256 ethBefore = address(shield).balance;
        vm.recordLogs();
        _deliverLastCallback();

        uint256 hf = _hf(alice);
        assertGe(hf, 1.4e18, "lifted to target");
        assertLt(hf, 1.401e18, "smallest top-up, not more");
        assertGt(address(shield).balance, ethBefore, "fee arrived as ETH for gas");
        assertEq(shield.rescueCount(), 1);

        // the shield's fresh snapshot clears pending and mirrors the new collateral
        _relaySnapshots();
        (uint128 collAfter,,,,, bool pendingAfter,) = rc.positions(alice);
        assertFalse(pendingAfter);
        assertGt(collAfter, 1 ether);

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

    function test_partialRescueWhenReserveIsShort() public {
        _protectAlice(0.05 ether);
        _movePrice(1600e8);
        uint256 before = _hf(alice);
        _deliverLastCallback();
        (uint128 reserve,,,) = shield.protections(alice);
        assertEq(reserve, 0, "used the whole reserve");
        assertGt(_hf(alice), before, "still improved");
    }

    function test_skipsWhenLivePositionIsHealthy() public {
        _protectAlice(1 ether);
        _movePrice(1600e8);
        oracle.setAssetPrice(address(weth), 2000e8); // price bounced before the callback landed
        _deliverLastCallback();
        assertEq(shield.rescueCount(), 0);
        (uint128 reserve,,,) = shield.protections(alice);
        assertEq(reserve, 1 ether, "nothing spent");
    }

    function test_rejectsCallerThatIsNotProxy() public {
        _protectAlice(1 ether);
        vm.expectRevert();
        shield.rescue(address(rc), alice);
    }

    function test_rejectsCallbackFromOtherReactiveContract() public {
        _protectAlice(1 ether);
        _movePrice(1600e8);
        ISystemContract.CallbackConfiguration_V_1_0 memory c = sys.callbackAt(0);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xBAD), address(rc)));
        proxy.deliver(c.recipient, c.payload, address(0xBAD));
    }

    function test_reactOnlyFromSystem() public {
        IReactive.LogRecord memory l =
            _log(address(oracle), rc.PRICE_UPDATED_TOPIC(), uint256(uint160(address(weth))), abi.encode(1, 1));
        vm.expectRevert();
        rc.react(l);
    }

    function test_cooldownBlocksBackToBackRescues() public {
        _protectAlice(1 ether);
        _movePrice(1600e8);
        _deliverLastCallback();
        oracle.setAssetPrice(address(weth), 1200e8);
        proxy.deliver(address(shield), abi.encodeWithSignature("rescue(address,address)", address(0), alice), address(rc));
        assertEq(shield.rescueCount(), 1);
        vm.warp(block.timestamp + 11);
        proxy.deliver(address(shield), abi.encodeWithSignature("rescue(address,address)", address(0), alice), address(rc));
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
        _protectAlice(2 ether);
        _movePrice(price);
        _deliverLastCallback();
        uint256 hf = _hf(alice);
        assertGe(hf, 1.4e18);
        assertLt(hf, 1.401e18);
    }
}

