// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";

/// The subset of Aave V3's IPool the shield needs.
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function getUserAccountData(address user)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256);
}

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface IWETH {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function withdraw(uint256 amount) external;
}

/// @title LiquidationShield
/// @notice A shared, self-funding liquidation shield for Aave-style positions (destination contract on Base Sepolia).
/// Borrowers park a WETH reserve here. When the reactive contract on Reactive Lasna sees a price move that pushes a
/// position under its trigger, it calls `rescue`, which supplies exactly enough of the reserve as collateral to lift
/// the health factor back to the borrower's target. A small fee is taken only on a rescue, unwrapped to ETH, and that
/// ETH is what the callback proxy charges for callback gas, so the service pays for its own operation.
contract LiquidationShield is AbstractCallback {
    struct Protection {
        uint128 reserve; // WETH wei held for this borrower
        uint64 triggerHF; // 1e18 scale; rescue when HF falls below this
        uint64 targetHF; // 1e18 scale; rescue lifts HF back to this
        uint64 lastRescueAt; // unix seconds (Base Sepolia has 200ms blocks, so never count blocks)
    }

    uint256 public constant COOLDOWN = 10 seconds;
    uint256 public constant MAX_FEE_BPS = 100; // hard cap: 1%

    IAavePool public immutable pool;
    IAaveOracle public immutable oracle;
    IWETH public immutable weth;
    uint256 public immutable feeBps; // fee on the rescued amount
    uint256 public immutable minFeeWei; // floor that covers one callback's gas

    mapping(address => Protection) public protections;

    // Operations ledger: lets anyone check that fees cover the callback gas the proxy charges.
    uint256 public feesEarnedWei;
    uint256 public externalFundingWei;
    uint256 public rescueCount;

    event PositionSnapshot(
        address indexed user,
        uint256 collateralWeth,
        uint256 debtBase,
        uint256 liqThresholdBps,
        uint256 triggerHF,
        bool active
    );
    event Rescued(
        address indexed user, uint256 suppliedWeth, uint256 feeWei, uint256 hfBefore, uint256 hfAfter, uint256 timestamp
    );
    event RescueSkipped(address indexed user, uint256 hf, string reason);

    error BadHealthFactors();
    error FeeTooHigh();

    constructor(
        IPayable callbackProxy_,
        address reactiveContract_,
        IAavePool pool_,
        IAaveOracle oracle_,
        IWETH weth_,
        uint256 feeBps_,
        uint256 minFeeWei_
    ) payable AbstractCallback(callbackProxy_, reactiveContract_) {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        pool = pool_;
        oracle = oracle_;
        weth = weth_;
        feeBps = feeBps_;
        minFeeWei = minFeeWei_;
        externalFundingWei = msg.value;
    }

    // ---------------------------------------------------------------- borrower actions

    /// @notice Start (or update) protection and add `amount` WETH to your reserve.
    function protect(uint64 triggerHF, uint64 targetHF, uint256 amount) external {
        if (triggerHF <= 1e18 || targetHF <= triggerHF) revert BadHealthFactors();
        Protection storage p = protections[msg.sender];
        p.triggerHF = triggerHF;
        p.targetHF = targetHF;
        if (amount > 0) {
            weth.transferFrom(msg.sender, address(this), amount);
            p.reserve += uint128(amount);
        }
        _snapshot(msg.sender);
    }

    /// @notice Take reserve back. Withdrawing everything turns protection off.
    function withdrawReserve(uint256 amount) external {
        Protection storage p = protections[msg.sender];
        p.reserve -= uint128(amount);
        weth.transfer(msg.sender, amount);
        _snapshot(msg.sender);
    }

    /// @notice Re-publish a position to the reactive contract (call after borrowing more or adding collateral).
    function sync(address user) external {
        _snapshot(user);
    }

    // ---------------------------------------------------------------- reactive callback

    /// @notice Called by the Reactive callback proxy. The first argument is overwritten by the proxy with the
    /// address of the reactive contract that requested the callback.
    function rescue(address reactiveSender, address user)
        external
        onlyServiceProvider
        onlyCallbackSender(reactiveSender)
    {
        Protection storage p = protections[user];
        (uint256 collBase, uint256 debtBase,, uint256 ltBps,, uint256 hf) = pool.getUserAccountData(user);

        // The reactive contract works from a mirrored copy; re-check the live position before spending anything.
        if (p.reserve == 0) return _skip(user, hf, "no reserve");
        if (hf >= p.triggerHF) return _skip(user, hf, "healthy");
        if (p.lastRescueAt != 0 && block.timestamp < p.lastRescueAt + COOLDOWN) return _skip(user, hf, "cooldown");

        // Smallest top-up that restores the target: HF = C * LT / D  =>  C_needed = target * D / LT.
        // Round up, plus one base unit, so the pool's own rounding can't leave HF a hair under target.
        uint256 neededBase = _ceilDiv(uint256(p.targetHF) * debtBase * 10_000, ltBps * 1e18) + 1;
        uint256 price = oracle.getAssetPrice(address(weth));
        uint256 amount = _ceilDiv((neededBase - collBase) * 1e18, price);

        uint256 fee = amount * feeBps / 10_000;
        if (fee < minFeeWei) fee = minFeeWei;
        if (amount + fee > p.reserve) {
            // Not enough reserve for a full rescue: keep the fee, put everything else in (a partial rescue still helps).
            fee = p.reserve > fee ? fee : 0;
            amount = p.reserve - fee;
        }
        p.reserve -= uint128(amount + fee);
        p.lastRescueAt = uint64(block.timestamp);

        weth.approve(address(pool), amount);
        pool.supply(address(weth), amount, user, 0);
        if (fee > 0) {
            weth.withdraw(fee); // ETH lands in this contract and pays the callback proxy
            feesEarnedWei += fee;
        }
        rescueCount++;

        (,,,,, uint256 hfAfter) = pool.getUserAccountData(user);
        emit Rescued(user, amount, fee, hf, hfAfter, block.timestamp);
        _snapshot(user);
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
        gasPaid = fees + externalFunding - balance;
        debt = _SERVICE_PROVIDER.debt(address(this));
    }

    // ---------------------------------------------------------------- internals

    function _snapshot(address user) internal {
        Protection storage p = protections[user];
        (uint256 collBase, uint256 debtBase,, uint256 ltBps,,) = pool.getUserAccountData(user);
        uint256 price = oracle.getAssetPrice(address(weth));
        uint256 collWeth = price == 0 ? 0 : collBase * 1e18 / price;
        emit PositionSnapshot(user, collWeth, debtBase, ltBps, p.triggerHF, p.reserve > 0 && p.triggerHF > 0);
    }

    function _skip(address user, uint256 hf, string memory reason) internal {
        emit RescueSkipped(user, hf, reason);
        _snapshot(user); // clears the reactive contract's pending flag
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
