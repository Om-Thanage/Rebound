// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {MockERC20} from "./MockTokens.sol";
import {MockAaveOracle} from "./MockAaveOracle.sol";

/// Read-only aToken stand-in: `balanceOf(user)` is the user's collateral of one asset in the pool, which is what
/// the shield reads from Aave's real aTokens to report per-asset collateral.
contract MockAToken {
    MockAavePool public immutable pool;
    address public immutable underlying;

    constructor(MockAavePool pool_, address underlying_) {
        pool = pool_;
        underlying = underlying_;
    }

    function balanceOf(address user) external view returns (uint256) {
        return pool.collateralOf(underlying, user);
    }
}

/// A lending pool with Aave V3's function signatures and health-factor maths: several collateral assets with
/// their own liquidation thresholds, one debt asset (USDC), and optional simple interest on debt.
/// shortcut: no liquidation function, no supply caps or e-modes; swap in the real Aave Pool for a live market.
contract MockAavePool {
    struct ReserveConfigurationMap {
        uint256 data; // Aave V3 layout: bits 0-15 LTV, 16-31 liquidation threshold, 32-47 bonus, 48-55 decimals
    }

    struct Collateral {
        uint16 ltvBps;
        uint16 liqThresholdBps;
        uint16 liqBonusBps; // 10_000 + bonus, as Aave stores it
        uint8 decimals;
        bool listed;
        MockAToken aToken;
    }

    address public immutable owner;
    MockERC20 public immutable weth;
    MockERC20 public immutable usdc;
    MockAaveOracle public immutable oracle;

    address[] public collateralAssets;
    mapping(address => Collateral) public collaterals;
    mapping(address => mapping(address => uint256)) public collateralOf; // asset => user => amount

    uint256 public borrowRateBps; // simple yearly interest on debt; 0 keeps the demo deterministic
    mapping(address => uint256) internal debtPrincipal; // USDC, 6 decimals
    mapping(address => uint256) internal debtSince;

    event Supply(address indexed reserve, address user, address indexed onBehalfOf, uint256 amount, uint16 indexed referralCode);
    event Borrow(address indexed reserve, address user, address indexed onBehalfOf, uint256 amount, uint256 interestRateMode, uint256 borrowRate, uint16 indexed referralCode);
    event Repay(address indexed reserve, address indexed user, address indexed repayer, uint256 amount, bool useATokens);
    event Withdraw(address indexed reserve, address indexed user, address indexed to, uint256 amount);

    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(MockERC20 weth_, MockERC20 usdc_, MockAaveOracle oracle_) {
        owner = msg.sender;
        weth = weth_;
        usdc = usdc_;
        oracle = oracle_;
        _list(address(weth_), 8000, 8250, 10_500, 18); // Aave V3 Base launch values for WETH, LT rounded
    }

    /// Deployer only: list another collateral asset (for example WBTC) with its own risk parameters.
    function listCollateral(address asset, uint16 ltvBps, uint16 liqThresholdBps, uint16 liqBonusBps, uint8 decimals)
        external
        onlyOwner
    {
        require(!collaterals[asset].listed, "listed");
        require(ltvBps <= liqThresholdBps && liqThresholdBps < 10_000, "bad params");
        _list(asset, ltvBps, liqThresholdBps, liqBonusBps, decimals);
    }

    /// Deployer only: set simple yearly interest on debt, to show the mirrored debt drifting between snapshots.
    function setBorrowRate(uint256 bps) external onlyOwner {
        require(bps <= 10_000, "rate");
        borrowRateBps = bps;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        require(collaterals[asset].listed, "not collateral");
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        collateralOf[asset][onBehalfOf] += amount;
        emit Supply(asset, msg.sender, onBehalfOf, amount, referralCode);
    }

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external {
        require(asset == address(usdc), "only USDC debt");
        require(onBehalfOf == msg.sender, "no credit delegation");
        _setDebt(msg.sender, debt(msg.sender) + amount);
        (uint256 c, uint256 d,,, uint256 ltv,) = getUserAccountData(msg.sender);
        require(c * ltv >= d * 10_000, "exceeds LTV");
        usdc.mint(msg.sender, amount);
        emit Borrow(asset, msg.sender, onBehalfOf, amount, interestRateMode, borrowRateBps, referralCode);
    }

    /// Anyone may repay on behalf of a borrower, as in Aave V3.
    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
        require(asset == address(usdc), "only USDC debt");
        uint256 owed = debt(onBehalfOf);
        if (amount > owed) amount = owed;
        usdc.transferFrom(msg.sender, address(this), amount);
        _setDebt(onBehalfOf, owed - amount);
        emit Repay(asset, onBehalfOf, msg.sender, amount, false);
        return amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(collaterals[asset].listed, "not collateral");
        collateralOf[asset][msg.sender] -= amount;
        (,,,,, uint256 hf) = getUserAccountData(msg.sender);
        require(hf >= 1e18, "would be liquidatable");
        MockERC20(asset).transfer(to, amount);
        emit Withdraw(asset, msg.sender, to, amount);
        return amount;
    }

    // ---------------------------------------------------------------- views

    /// WETH collateral of `user` (kept for the scripts and DemoLoan, which predate multi-asset support).
    function collateral(address user) external view returns (uint256) {
        return collateralOf[address(weth)][user];
    }

    /// Debt including simple interest since the last change (USDC, 6 decimals).
    function debt(address user) public view returns (uint256) {
        uint256 p = debtPrincipal[user];
        if (p == 0 || borrowRateBps == 0) return p;
        return p + p * borrowRateBps * (block.timestamp - debtSince[user]) / (10_000 * 365 days);
    }

    function aTokenOf(address asset) external view returns (address) {
        return address(collaterals[asset].aToken);
    }

    function collateralAssetCount() external view returns (uint256) {
        return collateralAssets.length;
    }

    /// Same bit layout as Aave V3 `IPool.getConfiguration`.
    function getConfiguration(address asset) external view returns (ReserveConfigurationMap memory m) {
        Collateral memory c = collaterals[asset];
        m.data = uint256(c.ltvBps) | (uint256(c.liqThresholdBps) << 16) | (uint256(c.liqBonusBps) << 32)
            | (uint256(c.decimals) << 48);
    }

    /// Same return layout as Aave V3 `IPool.getUserAccountData` (base currency = USD, 8 decimals).
    /// The liquidation threshold and LTV are collateral-weighted averages, as in Aave.
    function getUserAccountData(address user)
        public
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        uint256 weightedLt;
        uint256 weightedLtv;
        for (uint256 i; i < collateralAssets.length; ++i) {
            address a = collateralAssets[i];
            uint256 amount = collateralOf[a][user];
            if (amount == 0) continue;
            Collateral memory c = collaterals[a];
            uint256 value = amount * oracle.getAssetPrice(a) / (10 ** c.decimals);
            totalCollateralBase += value;
            weightedLt += value * c.liqThresholdBps;
            weightedLtv += value * c.ltvBps;
        }
        totalDebtBase = debt(user) * 100; // 6-dec USDC at $1 -> 8-dec USD
        if (totalCollateralBase > 0) {
            currentLiquidationThreshold = weightedLt / totalCollateralBase;
            ltv = weightedLtv / totalCollateralBase;
        }
        uint256 maxBorrow = totalCollateralBase * ltv / 10_000;
        availableBorrowsBase = maxBorrow > totalDebtBase ? maxBorrow - totalDebtBase : 0;
        healthFactor = totalDebtBase == 0 ? type(uint256).max : weightedLt * 1e18 / (totalDebtBase * 10_000);
    }

    function _list(address asset, uint16 ltvBps, uint16 lt, uint16 bonus, uint8 decimals) internal {
        collaterals[asset] = Collateral(ltvBps, lt, bonus, decimals, true, new MockAToken(this, asset));
        collateralAssets.push(asset);
    }

    function _setDebt(address user, uint256 amount) internal {
        debtPrincipal[user] = amount;
        debtSince[user] = block.timestamp;
    }
}
