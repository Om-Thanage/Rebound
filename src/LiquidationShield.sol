// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";

/// The subset of Aave V3's IPool the shield needs.
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
    function getUserAccountData(address user)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256);
    /// Aave V3 returns a one-word struct (ReserveConfigurationMap); the liquidation threshold sits in bits 16-31.
    function getConfiguration(address asset) external view returns (uint256);
}

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface IERC20Lite {
    function balanceOf(address user) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWETH is IERC20Lite {
    function withdraw(uint256 amount) external;
}

/// @title LiquidationShield
/// @notice A shared, self-funding liquidation shield for Aave-style positions (destination contract on Base).
/// Borrowers park a WETH reserve (and, for repay mode, a debt-asset reserve) here. When the reactive contract on
/// Reactive Network sees a price move that puts a position under its trigger (or about to be), it calls `rescue`,
/// which re-checks the live position and either repays debt, adds WETH collateral, or both, by exactly enough to
/// lift the health factor back to the borrower's goal. Fees are taken in WETH, unwrapped to ETH, and that ETH is
/// what the callback proxy charges for callback gas, so the service pays for its own operation.
contract LiquidationShield is AbstractCallback {
    enum Mode {
        Collateral, // add WETH collateral from the reserve
        Repay, // repay debt from the debt-asset reserve (needs H/LT times less capital than a top-up); once that
        // reserve is empty, top up with WETH instead, so protection never lapses while WETH is left
        Combined // repay first, then top up with WETH for whatever is left
    }

    struct Protection {
        uint128 reserve; // WETH wei held for this borrower: collateral top-ups and fees
        uint128 repayReserve; // debt-asset units held for repay mode
        uint64 triggerHF; // 1e18 scale; rescue when HF falls below this
        uint64 targetHF; // 1e18 scale; a rescue lifts HF back to this
        uint64 stepHF; // 0 = one rescue to target; otherwise each rescue lifts HF to min(target, trigger + step)
        uint64 lastRescueAt; // unix seconds (Base makes 200 ms blocks, so never count blocks)
        uint64 feePaidUntil; // watch fee is settled up to this time
        Mode mode;
        bool mirrored; // the reactive contract currently mirrors this position as active
    }

    struct Config {
        IAavePool pool;
        IAaveOracle oracle;
        IWETH weth; // reserve and fee asset; must be collateralAssets[0]
        IERC20Lite debtAsset; // what repay mode repays (USDC)
        address[] collateralAssets; // reported per asset in snapshots, in this order
        address[] aTokens; // balance source per collateral asset (Aave's aTokens)
        uint256 feeBps; // fee on the value a rescue moves
        uint256 minFeeWei; // floor that covers one callback's gas
        uint256 watchFeeWeiPerDay; // charged from the reserve while protection is on, pays for watching
    }

    uint256 public constant COOLDOWN = 10 seconds;
    uint256 public constant MAX_FEE_BPS = 100; // hard cap: 1%
    uint256 public constant MAX_HINT_BPS = 500; // a price hint may sit at most 5% under the oracle price
    uint256 public constant MAX_REFRESH = 10; // users per CRON refresh callback

    IAavePool public immutable pool;
    IAaveOracle public immutable oracle;
    IWETH public immutable weth;
    IERC20Lite public immutable debtAsset;
    uint8 public immutable debtDecimals;
    uint256 public immutable feeBps;
    uint256 public immutable minFeeWei;
    uint256 public immutable watchFeeWeiPerDay;

    address[] public collateralAssets;
    address[] public aTokens;
    mapping(address => Protection) public protections;

    // Operations ledger: lets anyone check that fees cover the callback gas the proxy charges.
    uint256 public feesEarnedWei; // rescue fees + watch fees
    uint256 public watchFeesWei;
    uint256 public externalFundingWei;
    uint256 public rescueCount;
    uint256 public skippedCallbacks; // callbacks that found nothing to do: their gas was paid from other income
    uint256 public feelessRescues; // rescues whose reserve could not cover a fee
    uint256 public refreshCount; // positions re-published by the reactive contract's CRON sweep

    event PositionSnapshot(
        address indexed user,
        uint256[] collateralAmounts,
        uint256[] liqThresholdsBps,
        uint256 debtBase,
        uint256 triggerHF,
        uint256 cooldownUntil,
        bool active
    );
    event Rescued(
        address indexed user, uint256 suppliedWeth, uint256 feeWei, uint256 hfBefore, uint256 hfAfter, uint256 timestamp
    );
    event RescueDetail(address indexed user, uint256 repaidDebt, uint256 hintPrice, uint256 effectivePrice, uint256 goalHF);
    event RescueSkipped(address indexed user, uint256 hf, string reason);
    event WatchFeeCharged(address indexed user, uint256 amountWei);
    event RepayReserveEmpty(address indexed user); // repay mode fell back to a WETH top-up

    error BadHealthFactors();
    error BadConfig();
    error FeeTooHigh();
    error NotYourPosition();
    error UnderTrigger(uint256 hf);
    error TokenCallFailed(address token);
    error Overflow();

    constructor(IPayable callbackProxy_, address reactiveContract_, Config memory cfg)
        payable
        AbstractCallback(callbackProxy_, reactiveContract_)
    {
        if (cfg.feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (
            cfg.collateralAssets.length == 0 || cfg.collateralAssets.length != cfg.aTokens.length
                || cfg.collateralAssets[0] != address(cfg.weth)
        ) revert BadConfig();
        pool = cfg.pool;
        oracle = cfg.oracle;
        weth = cfg.weth;
        debtAsset = cfg.debtAsset;
        debtDecimals = cfg.debtAsset.decimals();
        feeBps = cfg.feeBps;
        minFeeWei = cfg.minFeeWei;
        watchFeeWeiPerDay = cfg.watchFeeWeiPerDay;
        collateralAssets = cfg.collateralAssets;
        aTokens = cfg.aTokens;
        externalFundingWei = msg.value;
    }

    // ---------------------------------------------------------------- borrower actions

    /// @notice Start (or update) protection and add `amount` WETH to your reserve. Keeps your mode and step.
    function protect(uint64 triggerHF, uint64 targetHF, uint256 amount) external {
        Protection storage p = protections[msg.sender];
        _setHealthFactors(p, triggerHF, targetHF, p.stepHF);
        _settleWatchFee(msg.sender, p);
        if (amount > 0) {
            _pull(weth, msg.sender, amount);
            p.reserve = _u128(p.reserve + amount);
        }
        _snapshot(msg.sender);
    }

    /// @notice Everything in one call, so the reactive contract gets one snapshot (and spends one reactive
    /// transaction) instead of one per change: health factors, step, mode, and WETH and debt-asset deposits.
    function setup(uint64 triggerHF, uint64 targetHF, uint64 stepHF, Mode mode, uint256 wethAmount, uint256 debtAmount)
        external
    {
        Protection storage p = protections[msg.sender];
        _setHealthFactors(p, triggerHF, targetHF, stepHF);
        _settleWatchFee(msg.sender, p);
        p.mode = mode;
        if (wethAmount > 0) {
            _pull(weth, msg.sender, wethAmount);
            p.reserve = _u128(p.reserve + wethAmount);
        }
        if (debtAmount > 0) {
            _pull(debtAsset, msg.sender, debtAmount);
            p.repayReserve = _u128(p.repayReserve + debtAmount);
        }
        _snapshot(msg.sender);
    }

    /// @notice Set trigger, target, staged step (0 = off) and mode in one call.
    function configure(uint64 triggerHF, uint64 targetHF, uint64 stepHF, Mode mode) external {
        Protection storage p = protections[msg.sender];
        _setHealthFactors(p, triggerHF, targetHF, stepHF);
        _settleWatchFee(msg.sender, p);
        p.mode = mode;
        _snapshot(msg.sender);
    }

    /// @notice Add debt-asset (USDC) to the reserve that repay mode uses.
    function depositRepayReserve(uint256 amount) external {
        Protection storage p = protections[msg.sender];
        _settleWatchFee(msg.sender, p);
        _pull(debtAsset, msg.sender, amount);
        p.repayReserve = _u128(p.repayReserve + amount);
        _snapshot(msg.sender);
    }

    /// @notice Take WETH reserve back. Not allowed while your loan is under its trigger (a rescue is on its way).
    function withdrawReserve(uint256 amount) external {
        Protection storage p = protections[msg.sender];
        _requireNotUnderTrigger(msg.sender, p);
        _settleWatchFee(msg.sender, p);
        p.reserve = _u128(p.reserve - amount);
        _send(weth, msg.sender, amount);
        _snapshot(msg.sender);
    }

    /// @notice Take repay reserve back. Same rule as `withdrawReserve`.
    function withdrawRepayReserve(uint256 amount) external {
        Protection storage p = protections[msg.sender];
        _requireNotUnderTrigger(msg.sender, p);
        _settleWatchFee(msg.sender, p);
        p.repayReserve = _u128(p.repayReserve - amount);
        _send(debtAsset, msg.sender, amount);
        _snapshot(msg.sender);
    }

    /// @notice Stop protection and take both reserves back, at any time.
    function unprotect() external {
        Protection storage p = protections[msg.sender];
        _settleWatchFee(msg.sender, p);
        uint256 r = p.reserve;
        uint256 rr = p.repayReserve;
        p.reserve = 0;
        p.repayReserve = 0;
        p.triggerHF = 0;
        p.targetHF = 0;
        p.stepHF = 0;
        if (r > 0) _send(weth, msg.sender, r);
        if (rr > 0) _send(debtAsset, msg.sender, rr);
        _snapshot(msg.sender);
    }

    /// @notice Re-publish your position to the reactive contract (call after borrowing more or adding collateral).
    /// Only the borrower may call it, so nobody else can spend the reactive contract's gas on your position.
    function sync(address user) external {
        if (msg.sender != user) revert NotYourPosition();
        _settleWatchFee(user, protections[user]);
        _snapshot(user);
    }

    // ---------------------------------------------------------------- reactive callbacks

    /// @notice Called by the Reactive callback proxy. The first argument is overwritten by the proxy with the
    /// address of the reactive contract that requested the callback. `hintPrice` (0 = none) is the WETH price the
    /// reactive contract expects next: a projection from a fast-falling price, or a lead feed on another chain.
    /// It is only ever used to act earlier or add more, and is clamped to at most 5% under the live oracle price.
    function rescue(address reactiveSender, address user, uint256 hintPrice)
        external
        onlyServiceProvider
        onlyCallbackSender(reactiveSender)
    {
        Protection storage p = protections[user];
        _settleWatchFee(user, p);
        Ctx memory c = _context(user, p, hintPrice);

        // The reactive contract works from a mirrored copy; re-check the live position before spending anything.
        if (!_hasReserveFor(p)) return _skip(user, c.hf, "no reserve");
        if (c.hfEff >= p.triggerHF) return _skip(user, c.hf, "healthy");
        if (p.lastRescueAt != 0 && block.timestamp < p.lastRescueAt + COOLDOWN) return _skip(user, c.hf, "cooldown");

        uint256 repaid = _plan(user, p, c);
        p.lastRescueAt = _u64(block.timestamp);
        rescueCount++;
        if (c.fee == 0) feelessRescues++;

        if (repaid > 0) {
            _approve(debtAsset, repaid);
            uint256 actual = pool.repay(address(debtAsset), repaid, 2, user);
            p.repayReserve = _u128(p.repayReserve - actual);
            if (actual < repaid) _approve(debtAsset, 0);
        }
        if (c.supply > 0) {
            _approve(weth, c.supply);
            pool.supply(address(weth), c.supply, user, 0);
        }
        if (c.fee > 0) {
            weth.withdraw(c.fee); // ETH lands in this contract and pays the callback proxy
            feesEarnedWei += c.fee;
        }

        (,,,,, uint256 hfAfter) = pool.getUserAccountData(user);
        emit Rescued(user, c.supply, c.fee, c.hf, hfAfter, block.timestamp);
        emit RescueDetail(user, repaid, hintPrice, c.pEff, c.goal);
        _snapshot(user);
    }

    /// @notice Called by the reactive contract's CRON sweep: re-publish positions whose mirror may have drifted
    /// (interest accrues on debt between snapshots) and settle their watch fees.
    function refresh(address reactiveSender, address[] calldata users)
        external
        onlyServiceProvider
        onlyCallbackSender(reactiveSender)
    {
        uint256 n = users.length < MAX_REFRESH ? users.length : MAX_REFRESH;
        for (uint256 i; i < n; ++i) {
            Protection storage p = protections[users[i]];
            if (p.triggerHF == 0 && !p.mirrored) continue;
            _settleWatchFee(users[i], p);
            _snapshot(users[i]);
            refreshCount++;
        }
    }

    // ---------------------------------------------------------------- operations funding

    /// @notice ETH from WETH unwraps is fee income; anything else is outside funding (e.g. the initial gas seed).
    receive() external payable override {
        if (msg.sender != address(weth)) externalFundingWei += msg.value;
    }

    /// @notice Pay any outstanding debt to the callback proxy (needed if a callback ran before fees came in).
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Fees vs. outside funding vs. gas paid to the callback proxy, all in wei.
    function opsLedger()
        external
        view
        returns (uint256 fees, uint256 externalFunding, uint256 gasPaid, uint256 balance, uint256 debt)
    {
        fees = feesEarnedWei;
        externalFunding = externalFundingWei;
        balance = address(this).balance;
        // ETH forced in without receive() (selfdestruct) can push the balance above what came in; never revert
        gasPaid = fees + externalFunding > balance ? fees + externalFunding - balance : 0;
        debt = _SERVICE_PROVIDER.debt(address(this));
    }

    /// @notice Where the fee income comes from, and how many callbacks earned nothing.
    function feeBreakdown()
        external
        view
        returns (uint256 rescueFees, uint256 watchFees, uint256 rescues, uint256 skipped, uint256 feeless, uint256 refreshed)
    {
        return (feesEarnedWei - watchFeesWei, watchFeesWei, rescueCount, skippedCallbacks, feelessRescues, refreshCount);
    }

    function collateralAssetCount() external view returns (uint256) {
        return collateralAssets.length;
    }

    // ---------------------------------------------------------------- rescue maths

    struct Ctx {
        uint256 hf; // live health factor
        uint256 hfEff; // health factor at the effective price
        uint256 debtBase;
        uint256 collLtEff; // sum of collateral value x liquidation threshold (base units x bps) at the effective price
        uint256 price; // live WETH oracle price
        uint256 pEff; // price the rescue is sized for: live, or the clamped hint if lower
        uint256 wethLt;
        uint256 goal;
        uint256 supply; // WETH to add as collateral
        uint256 fee;
    }

    function _context(address user, Protection storage p, uint256 hint) internal view returns (Ctx memory c) {
        uint256 collBase;
        uint256 ltAvg;
        (collBase, c.debtBase,, ltAvg,, c.hf) = pool.getUserAccountData(user);
        c.price = oracle.getAssetPrice(address(weth));
        c.pEff = c.price;
        uint256 floorPrice = c.price * (10_000 - MAX_HINT_BPS) / 10_000;
        if (hint > 0 && hint < c.price) c.pEff = hint > floorPrice ? hint : floorPrice;
        c.wethLt = _liqThreshold(address(weth));

        // Re-price only the WETH part of the collateral at the effective price; other assets stay as they are.
        uint256 collLt = collBase * ltAvg;
        uint256 wethLtValue = IERC20Lite(aTokens[0]).balanceOf(user) * c.price / 1e18 * c.wethLt;
        if (wethLtValue > collLt) wethLtValue = collLt; // rounding guard
        c.collLtEff = collLt - wethLtValue + wethLtValue * c.pEff / c.price;
        c.hfEff = c.debtBase == 0 ? type(uint256).max : c.collLtEff * 1e18 / (c.debtBase * 10_000);

        c.goal = p.targetHF;
        if (p.stepHF > 0 && uint256(p.triggerHF) + p.stepHF < c.goal) c.goal = uint256(p.triggerHF) + p.stepHF;
    }

    /// Works out how much to repay (returned, in debt-asset units) and how much WETH to supply and charge (in `c`).
    function _plan(address user, Protection storage p, Ctx memory c) internal returns (uint256 repaid) {
        uint256 debtBase = c.debtBase;
        uint256 repaidBase;
        // repay mode with an empty repay reserve tops up with WETH rather than leaving the loan unprotected
        bool topUp = p.mode != Mode.Repay || p.repayReserve == 0;
        if (p.mode == Mode.Repay && p.repayReserve == 0) emit RepayReserveEmpty(user);
        if (p.mode != Mode.Collateral && p.repayReserve > 0) {
            // HF = collLt / (D - x) / 1e4 >= goal  =>  x >= D - collLt * 1e18 / (goal * 1e4)
            uint256 keep = c.collLtEff * 1e18 / (c.goal * 10_000);
            uint256 xBase = debtBase > keep ? debtBase - keep + 1 : 0;
            uint256 debtPrice = oracle.getAssetPrice(address(debtAsset));
            if (debtPrice == 0) debtPrice = 1e8; // a stablecoin the mock oracle doesn't price
            repaid = _ceilDiv(xBase * (10 ** debtDecimals), debtPrice);
            if (repaid > p.repayReserve) repaid = p.repayReserve;
            repaidBase = repaid * debtPrice / (10 ** debtDecimals);
            debtBase = debtBase > repaidBase ? debtBase - repaidBase : 0;
        }
        if (topUp && debtBase > 0) {
            // Smallest top-up that reaches the goal: collLt + x * LT >= goal * D * 1e4 / 1e18.
            // Round up, plus one, so the pool's own rounding can't leave HF a hair under the goal.
            uint256 needLt = _ceilDiv(c.goal * debtBase * 10_000, 1e18) + 1;
            if (needLt > c.collLtEff) {
                uint256 xBase = _ceilDiv(needLt - c.collLtEff, c.wethLt);
                c.supply = _ceilDiv(xBase * 1e18, c.pEff);
            }
        }

        uint256 repaidWei = repaidBase * 1e18 / c.price;
        c.fee = _fee(repaidWei + c.supply);
        uint256 reserve = p.reserve;
        if (c.supply + c.fee > reserve) {
            // Not enough reserve: a partial rescue still helps. Size the top-up and its fee together, so the fee is
            // on what actually moves: supply + (repaidWei + supply) * bps / 1e4 = reserve.
            uint256 need = c.supply;
            if (need > 0) {
                uint256 a = reserve * 10_000;
                uint256 b = repaidWei * feeBps;
                uint256 s = a > b ? (a - b) / (10_000 + feeBps) : 0;
                c.fee = _fee(repaidWei + (s < need ? s : need));
            }
            if (reserve > c.fee) {
                c.supply = reserve - c.fee < need ? reserve - c.fee : need;
            } else if (c.supply > 0) {
                c.supply = reserve;
                c.fee = 0;
            } else {
                c.fee = reserve; // repay-only rescue with a near-empty gas deposit
            }
        }
        p.reserve = _u128(reserve - c.supply - c.fee);
    }

    // ---------------------------------------------------------------- internals

    function _setHealthFactors(Protection storage p, uint64 triggerHF, uint64 targetHF, uint64 stepHF) internal {
        if (triggerHF <= 1e18 || targetHF <= triggerHF) revert BadHealthFactors();
        p.triggerHF = triggerHF;
        p.targetHF = targetHF;
        p.stepHF = stepHF;
    }

    function _requireNotUnderTrigger(address user, Protection storage p) internal view {
        if (p.triggerHF == 0) return;
        (,,,,, uint256 hf) = pool.getUserAccountData(user);
        if (hf < p.triggerHF) revert UnderTrigger(hf);
    }

    function _hasReserveFor(Protection storage p) internal view returns (bool) {
        if (p.mode == Mode.Collateral) return p.reserve > 0;
        if (p.mode == Mode.Repay) return p.repayReserve > 0 || p.reserve > 0; // falls back to top-ups
        return p.reserve > 0 || p.repayReserve > 0;
    }

    function _isActive(Protection storage p) internal view returns (bool) {
        return p.triggerHF > 0 && _hasReserveFor(p);
    }

    /// Charges the watch fee owed since the last settlement, from the WETH reserve, and unwraps it for gas.
    function _settleWatchFee(address user, Protection storage p) internal {
        uint256 since = p.feePaidUntil;
        p.feePaidUntil = _u64(block.timestamp);
        if (since == 0 || watchFeeWeiPerDay == 0 || !_isActive(p)) return;
        uint256 owed = watchFeeWeiPerDay * (block.timestamp - since) / 1 days;
        if (owed > p.reserve) owed = p.reserve;
        if (owed == 0) return;
        p.reserve = _u128(p.reserve - owed);
        weth.withdraw(owed);
        feesEarnedWei += owed;
        watchFeesWei += owed;
        emit WatchFeeCharged(user, owed);
    }

    /// Publishes the position to the reactive contract. Positions that were never active are not published, so
    /// nobody can grow the reactive contract's list (and its per-tick gas) with empty addresses.
    function _snapshot(address user) internal {
        Protection storage p = protections[user];
        bool active = _isActive(p);
        if (!active && !p.mirrored) return;
        p.mirrored = active;

        (uint256[] memory amounts, uint256[] memory lts, uint256 debtBase) = _collateral(user);
        uint256 cooldownUntil = p.lastRescueAt == 0 ? 0 : p.lastRescueAt + COOLDOWN;
        emit PositionSnapshot(user, amounts, lts, debtBase, p.triggerHF, cooldownUntil, active);
    }

    /// Per-asset collateral and thresholds for a snapshot, plus the debt (base currency).
    function _collateral(address user) internal view returns (uint256[] memory amounts, uint256[] memory lts, uint256 debtBase) {
        uint256 n = collateralAssets.length;
        amounts = new uint256[](n);
        lts = new uint256[](n);
        uint256 naiveLt; // collateral value x threshold as the mirror would compute it from balances alone
        for (uint256 i; i < n; ++i) {
            address asset = collateralAssets[i];
            uint256 cfg = pool.getConfiguration(asset);
            amounts[i] = IERC20Lite(aTokens[i]).balanceOf(user);
            lts[i] = (cfg >> 16) & 0xFFFF;
            if (amounts[i] > 0) naiveLt += amounts[i] * oracle.getAssetPrice(asset) / 10 ** ((cfg >> 48) & 0xFF) * lts[i];
        }
        uint256 collBase;
        uint256 ltAvg;
        (collBase, debtBase,, ltAvg,,) = pool.getUserAccountData(user);
        // Aave leaves out balances the borrower has not enabled as collateral and applies eMode thresholds; the
        // balances above can't see either. Scale the thresholds so the mirror's health factor matches the pool's.
        // shortcut: exact at today's prices only, and spread over all assets; per-asset flags need a real-Aave reader.
        uint256 poolLt = collBase * ltAvg;
        if (naiveLt > 0 && (poolLt > naiveLt + naiveLt / 1000 || poolLt + naiveLt / 1000 < naiveLt)) {
            for (uint256 i; i < n; ++i) {
                lts[i] = lts[i] * poolLt / naiveLt;
            }
        }
    }

    function _skip(address user, uint256 hf, string memory reason) internal {
        skippedCallbacks++;
        emit RescueSkipped(user, hf, reason);
        _snapshot(user); // clears the reactive contract's pending flag
    }

    function _liqThreshold(address asset) internal view returns (uint256) {
        return (pool.getConfiguration(asset) >> 16) & 0xFFFF;
    }

    /// Token calls that also work with tokens returning nothing (USDT-style), and revert on `false`.
    function _call(IERC20Lite token, bytes memory data) internal {
        (bool ok, bytes memory ret) = address(token).call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenCallFailed(address(token));
    }

    function _pull(IERC20Lite token, address from, uint256 amount) internal {
        _call(token, abi.encodeCall(IERC20Lite.transferFrom, (from, address(this), amount)));
    }

    function _send(IERC20Lite token, address to, uint256 amount) internal {
        _call(token, abi.encodeCall(IERC20Lite.transfer, (to, amount)));
    }

    function _approve(IERC20Lite token, uint256 amount) internal {
        _call(token, abi.encodeCall(IERC20Lite.approve, (address(pool), amount)));
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert Overflow();
        return uint128(x);
    }

    function _u64(uint256 x) internal pure returns (uint64) {
        if (x > type(uint64).max) revert Overflow();
        return uint64(x);
    }

    function _fee(uint256 movedWei) internal view returns (uint256 f) {
        f = movedWei * feeBps / 10_000;
        if (f < minFeeWei) f = minFeeWei;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
