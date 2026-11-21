// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// Aave-style price oracle (USD, 8 decimals) whose price anyone can move, so the demo can simulate a crash.
contract MockAaveOracle {
    mapping(address => uint256) public prices;

    event AssetPriceUpdated(address indexed asset, uint256 price, uint256 timestamp);

    function getAssetPrice(address asset) external view returns (uint256) {
        return prices[asset];
    }

    function setAssetPrice(address asset, uint256 price) external {
        require(price > 0, "price=0");
        prices[asset] = price;
        emit AssetPriceUpdated(asset, price, block.timestamp);
    }
}
