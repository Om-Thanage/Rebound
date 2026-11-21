// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {MockERC20, MockWETH} from "./mocks/MockTokens.sol";
import {MockAaveOracle} from "./mocks/MockAaveOracle.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {LiquidationShield} from "./LiquidationShield.sol";

/// @title DemoLoan
/// @notice A protected loan anyone can put through a real rescue from the dashboard. `run()` resets the loan
/// (WETH back to $2,000, the collateral the last rescue added returned to the shield reserve, HF 1.2) and then
/// drops WETH to $1,800 (HF 1.08, under the 1.15 trigger), all in one transaction. The rescue that follows is
/// the real Reactive loop: oracle event -> ShieldReactive on Lasna -> callback -> LiquidationShield.rescue.
contract DemoLoan {
    uint256 public constant BASE_COLLATERAL = 0.004 ether; // HF 1.2 at $2,000 with 5.5 USDC of debt
    uint256 public constant DEBT = 5_500_000; // 5.5 USDC
    uint256 public constant PRICE_RESET = 2000e8;
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

    event RunStarted(address indexed caller, uint256 run, uint256 timestamp);

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
        oracle_.setAssetPrice(address(weth_), PRICE_RESET);
        pool_.supply(address(weth_), BASE_COLLATERAL, address(this), 0);
        pool_.borrow(address(usdc_), DEBT, 2, 0, address(this));
        shield_.protect(TRIGGER_HF, TARGET_HF, reserve);
    }

    /// @notice Reset the loan, then crash the price. Anyone may call it once a minute.
    function run() external {
        if (lastRun != 0 && block.timestamp < lastRun + COOLDOWN) revert TooSoon(lastRun + COOLDOWN);
        lastRun = block.timestamp;
        runs++;

        oracle.setAssetPrice(address(weth), PRICE_RESET);
        uint256 coll = pool.collateral(address(this));
        if (coll > BASE_COLLATERAL) {
            uint256 extra = coll - BASE_COLLATERAL;
            pool.withdraw(address(weth), extra, address(this));
            shield.protect(TRIGGER_HF, TARGET_HF, extra); // back into the reserve; also re-syncs the mirror
        } else {
            shield.sync(address(this)); // clears a pending flag left by a lost callback
        }
        oracle.setAssetPrice(address(weth), PRICE_CRASH);
        emit RunStarted(msg.sender, runs, block.timestamp);
    }

    /// @notice Seconds until `run()` may be called again (0 = now).
    function waitTime() external view returns (uint256) {
        uint256 next = lastRun + COOLDOWN;
        return lastRun == 0 || block.timestamp >= next ? 0 : next - block.timestamp;
    }
}
