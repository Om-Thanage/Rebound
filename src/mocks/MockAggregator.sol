// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// Chainlink-style price aggregator (8 decimals). It emits the same `AnswerUpdated` event as Chainlink's
/// aggregators, with the price in topic 1, so the reactive contract reads it exactly as it would read a live feed.
/// Only the deployer and one updater (the mock oracle, whose `setAssetPrice` anyone may call for the demo) may post.
contract MockAggregator {
    address public immutable owner;
    address public immutable updater; // 0 = owner only (the lead feed)
    int256 public latestAnswer;
    uint256 public latestRound;
    uint256 public latestTimestamp;
    uint8 public constant decimals = 8;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    error NotAllowed();

    constructor(address updater_) {
        owner = msg.sender;
        updater = updater_;
    }

    function updateAnswer(int256 answer) external {
        if (msg.sender != owner && msg.sender != updater) revert NotAllowed();
        require(answer > 0, "answer<=0");
        latestAnswer = answer;
        latestTimestamp = block.timestamp;
        latestRound++;
        emit AnswerUpdated(answer, latestRound, block.timestamp);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (uint80(latestRound), latestAnswer, latestTimestamp, latestTimestamp, uint80(latestRound));
    }
}

/// Chainlink-style proxy: consumers read through it while the aggregator behind it can be replaced.
/// Emits `AggregatorConfirmed(previous, latest)` on replacement, which the reactive contract follows.
contract MockAggregatorProxy {
    address public immutable owner;
    MockAggregator public aggregator;

    event AggregatorConfirmed(address indexed previous, address indexed latest);

    error NotOwner();

    constructor(MockAggregator aggregator_) {
        owner = msg.sender;
        aggregator = aggregator_;
    }

    /// Only the deployer may swap the aggregator, as only Chainlink can on a live feed: an open swap would let anyone
    /// point the oracle at a contract that reverts and stop every price read.
    function confirmAggregator(MockAggregator next) external {
        if (msg.sender != owner) revert NotOwner();
        address previous = address(aggregator);
        aggregator = next;
        emit AggregatorConfirmed(previous, address(next));
    }

    function latestAnswer() external view returns (int256) {
        return aggregator.latestAnswer();
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}
