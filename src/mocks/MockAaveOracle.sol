// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {MockAggregator, MockAggregatorProxy} from "./MockAggregator.sol";

/// Aave-style price oracle (USD, 8 decimals). Like Aave's `AaveOracle`, it reads each asset's price from a
/// Chainlink-style source; `setAssetPrice` pushes a new answer into that source so the demo can simulate a crash,
/// and the price event comes from the aggregator (`AnswerUpdated`), as it would on mainnet.
contract MockAaveOracle {
    address public immutable owner;
    address public demo; // the DemoLoan, the one other caller allowed to move prices
    mapping(address => MockAggregatorProxy) public sources;

    event AssetSourceUpdated(address indexed asset, address indexed source);

    error NotOwner();

    constructor() {
        owner = msg.sender;
    }

    /// Only the deployer may point an asset at a source (Aave's pool admin does this on mainnet).
    function setAssetSource(address asset, MockAggregatorProxy source) external {
        if (msg.sender != owner) revert NotOwner();
        sources[asset] = source;
        emit AssetSourceUpdated(asset, address(source));
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        MockAggregatorProxy s = sources[asset];
        if (address(s) == address(0)) return 0;
        int256 answer = s.latestAnswer();
        return answer > 0 ? uint256(answer) : 0;
    }

    /// Deployer only: name the DemoLoan (its address is predicted before it is deployed). Set once.
    function setDemo(address demo_) external {
        if (msg.sender != owner || demo != address(0)) revert NotOwner();
        demo = demo_;
    }

    /// Moves a test price. Only the deployer and the DemoLoan may: every price event costs the reactive contract
    /// lREACT, so an open setter would let anyone drain it. DemoLoan.run() allows one run a minute.
    function setAssetPrice(address asset, uint256 price) external {
        if (msg.sender != owner && msg.sender != demo) revert NotOwner();
        require(price > 0 && price <= uint256(type(int256).max), "bad price");
        MockAggregatorProxy s = sources[asset];
        require(address(s) != address(0), "no source");
        s.aggregator().updateAnswer(int256(price));
    }
}
