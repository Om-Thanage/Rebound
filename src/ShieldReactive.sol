// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @title ShieldReactive
/// @notice Runs on Reactive Lasna. Mirrors every protected position from the shield's `PositionSnapshot` events,
/// re-prices all of them on each oracle `AssetPriceUpdated` event, and requests a `rescue` callback only for the
/// positions that fell under their trigger. No keeper, no polling: the loop starts from the price event itself.
contract ShieldReactive is AbstractReactive {
    struct Position {
        uint128 collateralWeth;
        uint128 debtBase; // USD, 8 decimals
        uint32 liqThresholdBps;
        uint64 triggerHF;
        bool active;
        bool pending; // a rescue was requested and its result hasn't come back yet
        bool known;
    }

    uint256 public constant PRICE_UPDATED_TOPIC = uint256(keccak256("AssetPriceUpdated(address,uint256,uint256)"));
    uint256 public constant SNAPSHOT_TOPIC =
        uint256(keccak256("PositionSnapshot(address,uint256,uint256,uint256,uint256,bool)"));
    uint64 public constant CALLBACK_GAS_LIMIT = 600_000;

    uint256 public immutable originChainId;
    address public immutable oracle;
    address public immutable shield;
    address public immutable asset; // the collateral asset whose price we track

    uint256 public lastPrice;
    address[] public users;
    mapping(address => Position) public positions;

    event RescueRequested(address indexed user, uint256 mirroredHF, uint256 price);

    constructor(uint256 originChainId_, address oracle_, address shield_, address asset_) payable {
        originChainId = originChainId_;
        oracle = oracle_;
        shield = shield_;
        asset = asset_;
        SYSTEM.subscribe(originChainId_, oracle_, PRICE_UPDATED_TOPIC, uint256(uint160(asset_)), REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(originChainId_, shield_, SNAPSHOT_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function react(LogRecord calldata log) external onlySystem {
        if (log.chainId != originChainId) return;

        if (log.contractAddress == shield && log.topic0 == SNAPSHOT_TOPIC) {
            _onSnapshot(address(uint160(log.topic1)), log.data);
        } else if (log.contractAddress == oracle && log.topic0 == PRICE_UPDATED_TOPIC) {
            (uint256 price,) = abi.decode(log.data, (uint256, uint256));
            _onPrice(price);
        }
    }

    function userCount() external view returns (uint256) {
        return users.length;
    }

    /// Health factor of a mirrored position at `price` (1e18 scale, same formula as Aave).
    function mirroredHF(address user, uint256 price) public view returns (uint256) {
        Position memory p = positions[user];
        if (p.debtBase == 0) return type(uint256).max;
        uint256 collBase = uint256(p.collateralWeth) * price / 1e18;
        return collBase * p.liqThresholdBps * 1e18 / (uint256(p.debtBase) * 10_000);
    }

    function _onSnapshot(address user, bytes calldata data) internal {
        (uint256 coll, uint256 debtBase, uint256 lt, uint256 trigger, bool active) =
            abi.decode(data, (uint256, uint256, uint256, uint256, bool));
        Position storage p = positions[user];
        if (!p.known) {
            p.known = true;
            users.push(user);
        }
        p.collateralWeth = uint128(coll);
        p.debtBase = uint128(debtBase);
        p.liqThresholdBps = uint32(lt);
        p.triggerHF = uint64(trigger);
        p.active = active;
        p.pending = false;
    }

    // shortcut: re-prices every user on each tick, fine for a few dozen positions; bucket users by
    // liquidation price before going beyond that.
    function _onPrice(uint256 price) internal {
        lastPrice = price;
        uint256 n = users.length;
        for (uint256 i; i < n; ++i) {
            address user = users[i];
            Position storage p = positions[user];
            if (!p.active || p.pending) continue;
            uint256 hf = mirroredHF(user, price);
            if (hf >= p.triggerHF) continue;

            p.pending = true;
            emit RescueRequested(user, hf, price);
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: originChainId,
                    recipient: shield,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    // the proxy replaces the first argument with this contract's address
                    payload: abi.encodeWithSignature("rescue(address,address)", address(0), user)
                })
            );
        }
    }
}
