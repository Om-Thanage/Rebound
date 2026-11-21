// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {MockERC20} from "./MockTokens.sol";
import {MockAaveOracle} from "./MockAaveOracle.sol";

/// A one-market lending pool with Aave V3's function signatures and health-factor math
/// (WETH collateral, USDC debt). The shield talks to it through the same interface as the real Aave Pool.
/// shortcut: single collateral + single debt asset, no interest; swap in the real Aave Pool for a live market.
contract MockAavePool {
    uint256 public constant LTV_BPS = 8000; // max borrow
    uint256 public constant LIQ_THRESHOLD_BPS = 8250; // liquidatable when HF < 1
    uint256 public constant LIQ_BONUS_BPS = 500; // what a liquidator would take

    MockERC20 public immutable weth;
    MockERC20 public immutable usdc;
    MockAaveOracle public immutable oracle;

    mapping(address => uint256) public collateral; // WETH wei
    mapping(address => uint256) public debt; // USDC (6 decimals)

    event Supply(address indexed reserve, address user, address indexed onBehalfOf, uint256 amount, uint16 indexed referralCode);
    event Borrow(address indexed reserve, address user, address indexed onBehalfOf, uint256 amount, uint256 interestRateMode, uint256 borrowRate, uint16 indexed referralCode);
    event Repay(address indexed reserve, address indexed user, address indexed repayer, uint256 amount, bool useATokens);
    event Withdraw(address indexed reserve, address indexed user, address indexed to, uint256 amount);

    constructor(MockERC20 weth_, MockERC20 usdc_, MockAaveOracle oracle_) {
        weth = weth_;
        usdc = usdc_;
        oracle = oracle_;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        require(asset == address(weth), "only WETH collateral");
        weth.transferFrom(msg.sender, address(this), amount);
        collateral[onBehalfOf] += amount;
        emit Supply(asset, msg.sender, onBehalfOf, amount, referralCode);
    }

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external {
        require(asset == address(usdc), "only USDC debt");
        require(onBehalfOf == msg.sender, "no credit delegation");
        debt[msg.sender] += amount;
        (uint256 c, uint256 d,,,,) = getUserAccountData(msg.sender);
        require(c * LTV_BPS >= d * 10_000, "exceeds LTV");
        usdc.mint(msg.sender, amount);
        emit Borrow(asset, msg.sender, onBehalfOf, amount, interestRateMode, 0, referralCode);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
        require(asset == address(usdc), "only USDC debt");
        if (amount > debt[onBehalfOf]) amount = debt[onBehalfOf];
        usdc.transferFrom(msg.sender, address(this), amount);
        debt[onBehalfOf] -= amount;
        emit Repay(asset, onBehalfOf, msg.sender, amount, false);
        return amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(weth), "only WETH collateral");
        collateral[msg.sender] -= amount;
        (, , , , , uint256 hf) = getUserAccountData(msg.sender);
        require(hf >= 1e18, "would be liquidatable");
        weth.transfer(to, amount);
        emit Withdraw(asset, msg.sender, to, amount);
        return amount;
    }

    /// Same return layout as Aave V3 `IPool.getUserAccountData` (base currency = USD, 8 decimals).
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
        totalCollateralBase = collateral[user] * oracle.getAssetPrice(address(weth)) / 1e18;
        totalDebtBase = debt[user] * 100; // 6-dec USDC at $1 -> 8-dec USD
        uint256 maxBorrow = totalCollateralBase * LTV_BPS / 10_000;
        availableBorrowsBase = maxBorrow > totalDebtBase ? maxBorrow - totalDebtBase : 0;
        currentLiquidationThreshold = LIQ_THRESHOLD_BPS;
        ltv = LTV_BPS;
        healthFactor = totalDebtBase == 0
            ? type(uint256).max
            : totalCollateralBase * LIQ_THRESHOLD_BPS * 1e18 / (totalDebtBase * 10_000);
    }
}
