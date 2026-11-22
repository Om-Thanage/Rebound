// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @title ShieldReactive
/// @notice Runs on Reactive Network. Mirrors every protected position from the shield's `PositionSnapshot` events
/// and reacts to four kinds of event:
///  - a Chainlink `AnswerUpdated` on the origin chain: re-price the positions near their trigger and request a
///    `rescue` for each one under it, or about to be (if the price keeps falling at the same speed);
///  - an `AnswerUpdated` from a lead feed on another chain: rescue ahead of the origin oracle when the lead price
///    already puts a position under its trigger;
///  - a Chainlink proxy's `AggregatorConfirmed`: follow the feed to its new aggregator;
///  - a CRON tick from the system contract: sweep for missed positions and ask the shield to re-publish stale ones.
/// No keeper, no polling of the destination chain.
contract ShieldReactive is AbstractReactive {
    struct Config {
        uint256 originChainId; // where the pool, oracle feeds and shield live
        address shield;
        address[] assets; // collateral assets, in the shield's order
        uint8[] decimals;
        address[] feeds; // Chainlink aggregator per asset (emits AnswerUpdated)
        address[] proxies; // Chainlink proxy per asset (emits AggregatorConfirmed); 0 = don't follow
        uint256[] bucketWidths; // trigger-price bucket width per asset, 8 decimals; 0 = scan on every tick
        uint256 cronTopic; // system contract CRON event topic (e.g. keccak256("Cron100(uint256)")); 0 = off
        uint256 leadChainId; // 0 = no lead feed
        address leadFeed;
        uint256 leadAsset; // index into assets
    }

    struct Position {
        uint128 debtBase; // USD, 8 decimals
        uint64 triggerHF;
        uint64 cooldownUntil; // the shield's rescue cooldown, unix seconds
        uint64 pendingAt; // when the outstanding rescue was requested
        uint64 lastSnapshotAt;
        uint32 activeIdx;
        uint32 slotIdx; // index in its bucket, or in the scan-always list
        uint32 retryIdx; // 1-based index in the retry list, 0 = not on it
        uint8 slot; // 0 = not placed, 1 = scan-always list, 2 + asset = bucketed by that asset's trigger price
        bool active;
        bool pending; // a rescue was requested and its result hasn't come back yet
        uint256 bucketKey;
    }

    uint256 public constant ANSWER_UPDATED_TOPIC = uint256(keccak256("AnswerUpdated(int256,uint256,uint256)"));
    uint256 public constant AGGREGATOR_CONFIRMED_TOPIC = uint256(keccak256("AggregatorConfirmed(address,address)"));
    uint256 public constant SNAPSHOT_TOPIC =
        uint256(keccak256("PositionSnapshot(address,uint256[],uint256[],uint256,uint256,uint256,bool)"));
    uint64 public constant RESCUE_GAS_LIMIT = 1_000_000;
    uint64 public constant REFRESH_GAS_LIMIT = 2_000_000;
    uint256 public constant PENDING_TIMEOUT = 60 seconds; // a lost callback stops blocking after this
    uint256 public constant MAX_PROJECT_BPS = 500; // projections and lead prices at most 5% under the last price
    uint256 public constant SCAN_WINDOW_BPS = 1000; // also check positions whose trigger price is up to 10% above
    uint256 public constant MAX_BUCKETS_PER_TICK = 64;
    uint256 public constant TICK_GAS_BUDGET = 650_000; // Reactive caps a reactive transaction at 900,000 gas
    uint256 internal constant GAS_PER_STEP = 30_000; // headroom for one more check and request
    uint256 public constant SWEEP_BATCH = 50;
    uint256 public constant MAX_REFRESH = 10;
    uint256 public constant RESYNC_AFTER = 1 days;
    uint256 internal constant NO_ASSET = type(uint256).max;

    uint256 public immutable originChainId;
    uint256 public immutable reactiveChainId;
    address public immutable shield;
    uint256 public immutable cronTopic;
    uint256 public immutable leadChainId;
    address public immutable leadFeed;
    uint256 public immutable leadAsset;

    address[] public assets;
    uint8[] public assetDecimals;
    address[] public feeds;
    uint256[] public bucketWidths;
    uint256[] public lastPrice;
    mapping(address => uint256) public feedAsset; // aggregator => asset index + 1
    mapping(address => uint256) public proxyAsset; // proxy => asset index + 1
    uint256 public lastLeadPrice;
    uint256 public lastOriginAt; // latest origin-chain timestamp seen; cooldowns and timeouts are in origin time

    mapping(address => Position) public positions;
    mapping(address => uint256[]) internal collateral;
    mapping(address => uint256[]) internal liqThresholds;
    address[] public activeUsers;
    address[] public scanAlways; // positions that can't be bucketed by one price (several collateral assets)
    mapping(uint256 => mapping(uint256 => address[])) internal buckets; // asset => key => users
    address[] public retryList; // under their trigger but inside the shield's cooldown
    uint256 public sweepCursor;
    mapping(uint256 => uint256) public resumeKey; // asset => bucket key + 1 where an interrupted scan stopped
    mapping(uint256 => uint256) public resumeLo;

    // Work counters, read by the dashboard to show what the reactive side does.
    uint256 public priceTicks;
    uint256 public leadTicks;
    uint256 public cronTicks;
    uint256 public positionsChecked;
    uint256 public rescuesRequested;
    uint256 public earlyRequests;
    uint256 public refreshesRequested;
    uint256 public aggregatorSwitches;

    event RescueRequested(address indexed user, uint256 mirroredHF, uint256 price, uint256 hintPrice);
    event RefreshRequested(uint256 count);
    event AggregatorFollowed(uint256 indexed asset, address previous, address latest);

    error BadConfig();

    constructor(Config memory cfg) payable {
        uint256 n = cfg.assets.length;
        if (
            n == 0 || cfg.decimals.length != n || cfg.feeds.length != n || cfg.proxies.length != n
                || cfg.bucketWidths.length != n || (cfg.leadChainId != 0 && cfg.leadAsset >= n)
        ) revert BadConfig();
        originChainId = cfg.originChainId;
        reactiveChainId = block.chainid;
        shield = cfg.shield;
        cronTopic = cfg.cronTopic;
        leadChainId = cfg.leadChainId;
        leadFeed = cfg.leadFeed;
        leadAsset = cfg.leadAsset;
        assets = cfg.assets;
        assetDecimals = cfg.decimals;
        feeds = cfg.feeds;
        bucketWidths = cfg.bucketWidths;
        lastPrice = new uint256[](n);

        for (uint256 i; i < n; ++i) {
            feedAsset[cfg.feeds[i]] = i + 1;
            _subscribe(cfg.originChainId, cfg.feeds[i], ANSWER_UPDATED_TOPIC);
            if (cfg.proxies[i] != address(0)) {
                proxyAsset[cfg.proxies[i]] = i + 1;
                _subscribe(cfg.originChainId, cfg.proxies[i], AGGREGATOR_CONFIRMED_TOPIC);
            }
        }
        _subscribe(cfg.originChainId, cfg.shield, SNAPSHOT_TOPIC);
        if (cfg.leadChainId != 0) _subscribe(cfg.leadChainId, cfg.leadFeed, ANSWER_UPDATED_TOPIC);
        if (cfg.cronTopic != 0) _subscribe(block.chainid, address(SYSTEM), cfg.cronTopic);
    }

    function react(LogRecord calldata log) external onlySystem {
        if (leadChainId != 0 && log.chainId == leadChainId && log.contractAddress == leadFeed) {
            if (log.topic0 == ANSWER_UPDATED_TOPIC) _onLeadPrice(_answer(log), abi.decode(log.data, (uint256)));
        } else if (log.chainId == originChainId) {
            if (log.contractAddress == shield && log.topic0 == SNAPSHOT_TOPIC) {
                _onSnapshot(address(uint160(log.topic1)), log.data);
            } else if (log.topic0 == ANSWER_UPDATED_TOPIC && feedAsset[log.contractAddress] != 0) {
                _onPrice(feedAsset[log.contractAddress] - 1, _answer(log), abi.decode(log.data, (uint256)));
            } else if (log.topic0 == AGGREGATOR_CONFIRMED_TOPIC && proxyAsset[log.contractAddress] != 0) {
                _onAggregatorConfirmed(proxyAsset[log.contractAddress] - 1, address(uint160(log.topic2)));
            }
        } else if (
            cronTopic != 0 && log.chainId == reactiveChainId && log.contractAddress == address(SYSTEM)
                && log.topic0 == cronTopic
        ) {
            _onCron();
        }
    }

    // ---------------------------------------------------------------- views

    function retryCount() external view returns (uint256) {
        return retryList.length;
    }

    function userCount() external view returns (uint256) {
        return activeUsers.length;
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function collateralOf(address user, uint256 asset) external view returns (uint256) {
        uint256[] storage c = collateral[user];
        return asset < c.length ? c[asset] : 0;
    }

    function bucketSize(uint256 asset, uint256 key) external view returns (uint256) {
        return buckets[asset][key].length;
    }

    /// Health factor of a mirrored position at the last seen prices (1e18 scale, same formula as Aave).
    function mirroredHF(address user) public view returns (uint256) {
        return _hfAt(user, NO_ASSET, 0);
    }

    /// Price of `asset` at which a single-asset position reaches its trigger (8 decimals; 0 if not single-asset).
    function triggerPrice(address user) public view returns (uint256 price, uint256 asset) {
        Position storage p = positions[user];
        uint256[] storage c = collateral[user];
        asset = NO_ASSET;
        for (uint256 i; i < c.length; ++i) {
            if (c[i] == 0) continue;
            if (asset != NO_ASSET) return (0, NO_ASSET); // more than one collateral asset
            asset = i;
        }
        if (asset == NO_ASSET) return (0, NO_ASSET);
        uint256 lt = liqThresholds[user][asset];
        if (lt == 0) return (0, NO_ASSET);
        // HF = amount * price / 10^dec * lt / (debt * 1e4)  =>  price = trigger * debt * 1e4 * 10^dec / (amount * lt * 1e18)
        price = uint256(p.triggerHF) * p.debtBase * 10_000 * (10 ** assetDecimals[asset]) / (c[asset] * lt * 1e18);
    }

    // ---------------------------------------------------------------- event handlers

    function _onSnapshot(address user, bytes calldata data) internal {
        (uint256[] memory amounts, uint256[] memory lts, uint256 debtBase, uint256 trigger, uint256 cooldownUntil, bool active)
        = abi.decode(data, (uint256[], uint256[], uint256, uint256, uint256, bool));
        Position storage p = positions[user];
        _unplace(p);
        p.pending = false;
        if (!active) {
            if (p.active) _removeActive(p);
            p.active = false;
            _clearRetry(p);
            return;
        }
        collateral[user] = amounts;
        liqThresholds[user] = lts;
        p.debtBase = uint128(debtBase);
        p.triggerHF = uint64(trigger);
        p.cooldownUntil = uint64(cooldownUntil);
        p.lastSnapshotAt = uint64(block.timestamp);
        if (!p.active) {
            p.active = true;
            p.activeIdx = uint32(activeUsers.length);
            activeUsers.push(user);
        }
        _place(user, p);
        // still under its trigger after this snapshot (a skipped or partial rescue): keep it on the retry list
        if (_hfAt(user, NO_ASSET, 0) < p.triggerHF) _markRetry(user, p);
        else _clearRetry(p);
    }

    function _onPrice(uint256 asset, uint256 price, uint256 at) internal {
        if (price == 0) return;
        if (at > lastOriginAt) lastOriginAt = at;
        priceTicks++;
        uint256 last = lastPrice[asset];
        lastPrice[asset] = price;
        // If the price is falling, assume the next step repeats this one (capped), and rescue whoever that step
        // would put under their trigger. Liquidators act in the block of the next update; this acts on this one.
        uint256 projected = price;
        if (last > price) {
            uint256 step = last - price;
            uint256 floorPrice = price * (10_000 - MAX_PROJECT_BPS) / 10_000;
            projected = step < price && price - step > floorPrice ? price - step : floorPrice;
        }
        uint256 upper = price * (10_000 + SCAN_WINDOW_BPS) / 10_000;
        if (last > upper) upper = last; // a big drop: everyone whose trigger price it crossed
        uint256 floor = _gasFloor();
        _checkRetries(at, floor);
        _scan(asset, projected, upper, projected, at, floor);
        _scanList(scanAlways, asset, projected, at, floor);
    }

    function _onLeadPrice(uint256 leadPrice, uint256 at) internal {
        if (leadPrice == 0) return;
        if (lastOriginAt > at) at = lastOriginAt; // the lead chain's clock may lag the origin chain's
        leadTicks++;
        lastLeadPrice = leadPrice;
        uint256 price = lastPrice[leadAsset];
        if (price == 0 || leadPrice >= price) return;
        uint256 floorPrice = price * (10_000 - MAX_PROJECT_BPS) / 10_000;
        uint256 hint = leadPrice > floorPrice ? leadPrice : floorPrice;
        uint256 floor = _gasFloor();
        _checkRetries(at, floor);
        _scan(leadAsset, hint, price, hint, at, floor);
        _scanList(scanAlways, leadAsset, hint, at, floor);
    }

    function _onAggregatorConfirmed(uint256 asset, address latest) internal {
        address previous = feeds[asset];
        if (latest == previous || latest == address(0)) return;
        delete feedAsset[previous];
        feeds[asset] = latest;
        feedAsset[latest] = asset + 1;
        // On Reactive Omni, react() runs on Reactive Network itself, so it can manage its own subscriptions.
        SYSTEM.unsubscribe(originChainId, previous, ANSWER_UPDATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        _subscribe(originChainId, latest, ANSWER_UPDATED_TOPIC);
        aggregatorSwitches++;
        emit AggregatorFollowed(asset, previous, latest);
    }

    /// Periodic sweep: re-check a batch of positions at the last prices (catches anything a tick skipped, such as a
    /// position that left its cooldown while the price stood still), and ask the shield to re-publish positions
    /// whose mirror is a day old, because interest keeps adding to their debt.
    function _onCron() internal {
        cronTicks++;
        uint256 tickFloor = _gasFloor(); // one budget for the whole CRON tick
        uint256 scanFloor = tickFloor + 300_000; // leave part of it for the sweep below
        for (uint256 a; a < assets.length; ++a) {
            uint256 price = lastPrice[a];
            if (resumeKey[a] != 0 && price != 0) _scan(a, price, price, price, block.timestamp, scanFloor);
        }
        uint256 n = activeUsers.length;
        if (n == 0) return;
        uint256 batch = n < SWEEP_BATCH ? n : SWEEP_BATCH;
        address[] memory stale = new address[](MAX_REFRESH);
        uint256 staleCount;
        uint256 cursor = sweepCursor % n;
        uint256 floor = tickFloor + 60_000; // keep room for the refresh callback
        uint256 i;
        for (; i < batch && gasleft() > floor; ++i) {
            address user = activeUsers[(cursor + i) % n];
            _check(user, NO_ASSET, 0, block.timestamp);
            Position storage p = positions[user];
            if (staleCount < MAX_REFRESH && block.timestamp >= p.lastSnapshotAt + RESYNC_AFTER) {
                stale[staleCount++] = user;
                p.lastSnapshotAt = uint64(block.timestamp); // don't ask again before the snapshot arrives
            }
        }
        sweepCursor = (cursor + i) % n;
        if (staleCount == 0) return;
        assembly ("memory-safe") {
            mstore(stale, staleCount)
        }
        refreshesRequested++;
        emit RefreshRequested(staleCount);
        _callback(REFRESH_GAS_LIMIT, abi.encodeWithSignature("refresh(address,address[])", address(0), stale));
    }

    // ---------------------------------------------------------------- scanning

    /// Checks the bucketed positions of `asset` whose trigger price lies in [lo, hi], highest (most at risk) first.
    /// Stops when the tick's gas budget is spent and remembers where, so the next tick for this asset (or the next
    /// CRON tick) carries on from there: a crash that crosses more triggers than one transaction can serve still
    /// reaches every position.
    function _scan(uint256 asset, uint256 lo, uint256 hi, uint256 projected, uint256 at, uint256 floor) internal {
        uint256 width = bucketWidths[asset];
        if (width == 0) return; // this asset's positions all sit in the scan-always list
        uint256 keyHi = hi / width;
        uint256 keyLo = lo / width;
        uint256 resume = resumeKey[asset];
        if (resume != 0) {
            if (resume - 1 > keyHi) keyHi = resume - 1;
            if (resumeLo[asset] < keyLo) keyLo = resumeLo[asset];
        }
        if (keyHi - keyLo >= MAX_BUCKETS_PER_TICK) keyLo = keyHi - MAX_BUCKETS_PER_TICK + 1;
        for (uint256 k = keyHi + 1; k > keyLo; --k) {
            address[] storage b = buckets[asset][k - 1];
            for (uint256 i; i < b.length; ++i) {
                if (gasleft() <= floor) {
                    resumeKey[asset] = k; // 1-based: carry on from this bucket
                    resumeLo[asset] = keyLo;
                    return;
                }
                _check(b[i], asset, projected, at);
            }
        }
        resumeKey[asset] = 0;
    }

    function _scanList(address[] storage list, uint256 asset, uint256 projected, uint256 at, uint256 floor) internal {
        uint256 n = list.length;
        for (uint256 i; i < n && gasleft() > floor; ++i) {
            _check(list[i], asset, projected, at);
        }
    }

    /// Gas level under which a tick stops scanning: TICK_GAS_BUDGET from now, plus headroom for one last step.
    function _gasFloor() internal view returns (uint256) {
        uint256 g = gasleft();
        return g > TICK_GAS_BUDGET ? g - TICK_GAS_BUDGET + GAS_PER_STEP : GAS_PER_STEP;
    }

    /// Requests a rescue if the position is under its trigger now, or would be at `projected` for `asset`.
    /// A position with a rescue in flight is skipped cheaply: its snapshot (or the timeout) settles it. A position
    /// under its trigger but inside the shield's cooldown goes on the retry list, which every tick checks first, so
    /// a small further move can't leave it behind.
    function _check(address user, uint256 asset, uint256 projected, uint256 at) internal {
        positionsChecked++;
        Position storage p = positions[user];
        if (!p.active) return _clearRetry(p);
        if (p.pending && at < uint256(p.pendingAt) + PENDING_TIMEOUT) return;
        bool cooling = at < p.cooldownUntil;

        uint256 hf = _hfAt(user, NO_ASSET, 0);
        if (hf < p.triggerHF) {
            if (cooling) return _markRetry(user, p);
            _clearRetry(p);
            return _request(user, p, hf, 0, at, asset);
        }
        _clearRetry(p);
        if (cooling || asset == NO_ASSET || projected == 0 || projected >= lastPrice[asset]) return;
        uint256 hfNext = _hfAt(user, asset, projected);
        if (hfNext < p.triggerHF) {
            earlyRequests++;
            _request(user, p, hfNext, projected, at, asset);
        }
    }

    function _checkRetries(uint256 at, uint256 floor) internal {
        // iterate backwards: _check may swap-and-pop the current entry
        for (uint256 i = retryList.length; i > 0 && gasleft() > floor; --i) {
            uint256 idx = i - 1;
            if (idx >= retryList.length) continue;
            _check(retryList[idx], NO_ASSET, 0, at);
        }
    }

    function _markRetry(address user, Position storage p) internal {
        if (p.retryIdx != 0) return;
        retryList.push(user);
        p.retryIdx = uint32(retryList.length);
    }

    function _clearRetry(Position storage p) internal {
        uint256 idx = p.retryIdx;
        if (idx == 0) return;
        address last = retryList[retryList.length - 1];
        retryList[idx - 1] = last;
        positions[last].retryIdx = uint32(idx);
        retryList.pop();
        p.retryIdx = 0;
    }

    function _request(address user, Position storage p, uint256 hf, uint256 hint, uint256 at, uint256 asset) internal {
        p.pending = true;
        p.pendingAt = uint64(at);
        rescuesRequested++;
        emit RescueRequested(user, hf, asset == NO_ASSET ? lastPrice[0] : lastPrice[asset], hint);
        // the proxy replaces the first argument with this contract's address
        _callback(RESCUE_GAS_LIMIT, abi.encodeWithSignature("rescue(address,address,uint256)", address(0), user, hint));
    }

    function _callback(uint64 gasLimit, bytes memory payload) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: originChainId,
                recipient: shield,
                gasLimit: gasLimit,
                payload: payload
            })
        );
    }

    /// Mirrored health factor, optionally with one asset re-priced at `price`. Returns max if a price is unknown,
    /// so a position is never rescued on a price the contract hasn't seen yet.
    function _hfAt(address user, uint256 asset, uint256 price) internal view returns (uint256) {
        Position storage p = positions[user];
        if (p.debtBase == 0) return type(uint256).max;
        uint256[] storage c = collateral[user];
        uint256[] storage lts = liqThresholds[user];
        uint256 collLt;
        uint256 n = c.length < assets.length ? c.length : assets.length;
        for (uint256 i; i < n; ++i) {
            if (c[i] == 0) continue;
            uint256 px = i == asset ? price : lastPrice[i];
            if (px == 0) return type(uint256).max;
            collLt += c[i] * px / (10 ** assetDecimals[i]) * lts[i];
        }
        return collLt * 1e18 / (uint256(p.debtBase) * 10_000);
    }

    // ---------------------------------------------------------------- buckets

    function _place(address user, Position storage p) internal {
        (uint256 price, uint256 asset) = triggerPrice(user);
        if (asset == NO_ASSET || bucketWidths[asset] == 0 || price == 0) {
            p.slot = 1;
            p.slotIdx = uint32(scanAlways.length);
            scanAlways.push(user);
            return;
        }
        uint256 key = price / bucketWidths[asset];
        address[] storage b = buckets[asset][key];
        p.slot = uint8(2 + asset);
        p.bucketKey = key;
        p.slotIdx = uint32(b.length);
        b.push(user);
    }

    function _unplace(Position storage p) internal {
        if (p.slot == 0) return;
        address[] storage list = p.slot == 1 ? scanAlways : buckets[p.slot - 2][p.bucketKey];
        uint256 idx = p.slotIdx;
        address last = list[list.length - 1];
        list[idx] = last;
        positions[last].slotIdx = uint32(idx);
        list.pop();
        p.slot = 0;
    }

    function _removeActive(Position storage p) internal {
        uint256 idx = p.activeIdx;
        address last = activeUsers[activeUsers.length - 1];
        activeUsers[idx] = last;
        positions[last].activeIdx = uint32(idx);
        activeUsers.pop();
    }

    // ---------------------------------------------------------------- helpers

    function _answer(LogRecord calldata log) internal pure returns (uint256) {
        int256 answer = int256(log.topic1); // AnswerUpdated(int256 indexed current, ...): the price is topic 1
        return answer > 0 ? uint256(answer) : 0;
    }

    function _subscribe(uint256 chainId, address emitter, uint256 topic0) internal {
        SYSTEM.subscribe(chainId, emitter, topic0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }
}
