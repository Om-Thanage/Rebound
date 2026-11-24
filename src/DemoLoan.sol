// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {MockERC20, MockWETH} from "./mocks/MockTokens.sol";
import {MockAaveOracle} from "./mocks/MockAaveOracle.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {LiquidationShield} from "./LiquidationShield.sol";

/// @title DemoLoan
/// @notice A protected loan anyone can put through a real rescue from the dashboard. `run()` resets the loan
/// (WETH back to $2,000, whatever the last rescue added or repaid undone, HF 1.2) and then drops WETH in two steps,
/// $1,950 (HF 1.17, still above the 1.15 trigger) and $1,800 (HF 1.08), all in one transaction. The reactive
/// contract sees the first step falling fast and asks for the rescue before the trigger is crossed. The rescue that
/// follows is the real Reactive loop: price event -> ShieldReactive -> callback -> LiquidationShield.rescue.
contract DemoLoan {
    uint256 public constant BASE_COLLATERAL = 0.004 ether; // HF 1.2 at $2,000 with 5.5 USDC of debt
    uint256 public constant DEBT = 5_500_000; // 5.5 USDC
    uint256 public constant REPAY_RESERVE = 10_000_000; // 10 test USDC for repay mode
    uint256 public constant PRICE_RESET = 2000e8;
    uint256 public constant PRICE_STEP = 1950e8;
    uint256 public constant PRICE_CRASH = 1800e8;
    uint64 public constant TRIGGER_HF = 1.15e18;
    uint64 public constant TARGET_HF = 1.4e18;
    uint256 public constant COOLDOWN = 60 seconds;

    MockWETH public immutable weth;
    MockERC20 public immutable usdc;
    MockAaveOracle public immutable oracle;
    MockAavePool public immutable pool;
    LiquidationShield public immutable shield;

    uint256 public lastRun;
    uint256 public runs;
    LiquidationShield.Mode public mode;

    event RunStarted(address indexed caller, uint256 run, uint256 timestamp, LiquidationShield.Mode mode);

    error TooSoon(uint256 nextRunAt);

    /// @param reserve WETH (from msg.value) parked in the shield; the rest of msg.value becomes collateral.
    constructor(
        MockWETH weth_,
        MockERC20 usdc_,
        MockAaveOracle oracle_,
        MockAavePool pool_,
        LiquidationShield shield_,
        uint256 reserve
    ) payable {
        require(msg.value == BASE_COLLATERAL + reserve, "send collateral + reserve");
        weth = weth_;
        usdc = usdc_;
        oracle = oracle_;
        pool = pool_;
        shield = shield_;

        weth_.deposit{value: msg.value}();
        weth_.approve(address(pool_), type(uint256).max);
        weth_.approve(address(shield_), type(uint256).max);
        usdc_.approve(address(pool_), type(uint256).max);
        usdc_.approve(address(shield_), type(uint256).max);
        oracle_.setAssetPrice(address(weth_), PRICE_RESET);
        pool_.supply(address(weth_), BASE_COLLATERAL, address(this), 0);
        pool_.borrow(address(usdc_), DEBT, 2, 0, address(this));
        usdc_.mint(address(this), REPAY_RESERVE); // the test USDC faucet is open
        shield_.setup(TRIGGER_HF, TARGET_HF, 0, LiquidationShield.Mode.Collateral, reserve, REPAY_RESERVE);
    }

    /// @notice Reset the loan, then crash the price in two steps, with collateral top-ups. Anyone, once a minute.
    function run() external {
        _run(LiquidationShield.Mode.Collateral);
    }

    /// @notice Same, with the rescue in the given mode (0 top-up, 1 repay debt, 2 repay then top-up).
    function runWithMode(LiquidationShield.Mode mode_) external {
        _run(mode_);
    }

    /// @notice Anyone may add ETH to the demo's WETH reserve (rescue fees and watch fees slowly use it up).
    function topUp() external payable {
        weth.deposit{value: msg.value}();
        shield.protect(TRIGGER_HF, TARGET_HF, msg.value);
    }

    /// @notice Seconds until `run()` may be called again (0 = now).
    function waitTime() external view returns (uint256) {
        uint256 next = lastRun + COOLDOWN;
        return lastRun == 0 || block.timestamp >= next ? 0 : next - block.timestamp;
    }

    function _run(LiquidationShield.Mode mode_) internal {
        if (lastRun != 0 && block.timestamp < lastRun + COOLDOWN) revert TooSoon(lastRun + COOLDOWN);
        lastRun = block.timestamp;
        runs++;

        oracle.setAssetPrice(address(weth), PRICE_RESET);
        // undo the last rescue: collateral it added goes back to the WETH reserve, debt it repaid is borrowed again
        uint256 coll = pool.collateral(address(this));
        uint256 extra = coll > BASE_COLLATERAL ? coll - BASE_COLLATERAL : 0;
        if (extra > 0) pool.withdraw(address(weth), extra, address(this));
        uint256 owed = pool.debt(address(this));
        uint256 reborrowed = owed < DEBT ? DEBT - owed : 0;
        if (reborrowed > 0) pool.borrow(address(usdc), reborrowed, 2, 0, address(this));
        mode = mode_;
        // one shield call, so one snapshot and one reactive transaction: returns what the last rescue used to the
        // reserves, sets the mode, and re-publishes the position (which also clears a pending flag left by a lost
        // callback)
        shield.setup(TRIGGER_HF, TARGET_HF, 0, mode_, extra, reborrowed);

        oracle.setAssetPrice(address(weth), PRICE_STEP);
        oracle.setAssetPrice(address(weth), PRICE_CRASH);
        emit RunStarted(msg.sender, runs, block.timestamp, mode_);
    }
}
