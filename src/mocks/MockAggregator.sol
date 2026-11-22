// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// Chainlink-style price aggregator (8 decimals) whose answer anyone can move, so the demo can simulate a crash.
/// It emits the same `AnswerUpdated` event as Chainlink's aggregators, with the price in topic 1, so the reactive
/// contract reads it exactly as it would read a live feed.
contract MockAggregator {
    int256 public latestAnswer;
    uint256 public latestRound;
    uint256 public latestTimestamp;
    uint8 public constant decimals = 8;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    function updateAnswer(int256 answer) external {
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
    MockAggregator public aggregator;

    event AggregatorConfirmed(address indexed previous, address indexed latest);

    constructor(MockAggregator aggregator_) {
        aggregator = aggregator_;
    }

    /// Testnet only: anyone may swap the aggregator, to demonstrate that the reactive contract follows it.
    function confirmAggregator(MockAggregator next) external {
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
