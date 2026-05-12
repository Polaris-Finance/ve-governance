// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.17;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {console2 as console} from "forge-std/console2.sol";

// TODO: come up with better name..
contract FixedPointBase {
    using SafeCast for int256;
    using SafeCast for uint256;

    uint256 maxTime;
    uint256 checkpointInterval;
    int256 linearDenominator;

    function setDenominator(int256 _linearDenominator) public {
        linearDenominator = _linearDenominator;
    }

    function initialize(
        uint256 _maxTime,
        uint256 _checkpointInterval,
        int256 _linearDenominator
    ) public {
        maxTime = _maxTime;
        checkpointInterval = _checkpointInterval;
        setDenominator(_linearDenominator);
    }

    function getFlooredAmount(uint256 _amount) internal view returns (uint256) {
        uint256 denominator = (-linearDenominator).toUint256();
        return _amount / denominator * denominator;
    }

    function getFlooredAmount208(uint208 _amount) internal view returns (uint208) {
        uint256 newAmount = getFlooredAmount(uint256(_amount));
        return uint208(newAmount);
    }

    function slopeFP(uint256 _amount) internal view returns (int256) {
        if (maxTime == 0) return 0;

        _amount = getFlooredAmount(_amount);
        return _amount.toInt256() * 1e18 / linearDenominator;
    }

    function biasFP(uint256 _amount, uint256 _duration) internal view returns (int256) {
        _amount = getFlooredAmount(_amount);
        int256 slope = maxTime == 0 ? int256(0) : _amount.toInt256() * 1e18 / linearDenominator;
        return _amount.toInt256() * int256(1e18) + slope * _duration.toInt256();
    }

    function biasFPCapped(uint256 _amount, uint256 _duration) internal view returns (int256) {
        int256 biasRaw = biasFP(_amount, _duration);
        if (biasRaw < 0) biasRaw = 0;
        return biasRaw;
    }

    function bias(uint256 _amount, uint256 _duration) internal view returns (uint256 bias_) {
        return (biasFPCapped(_amount, _duration) / 1e18).toUint256();
    }

    function previousCheckpointTs() internal view returns (uint256) {
        return previousCheckpointTs(block.timestamp);
    }

    function previousCheckpointTs(uint256 _time) internal view returns (uint256) {
        return _time / checkpointInterval * checkpointInterval;
    }

    function weekStartTs(uint256 _time) internal view returns (uint256) {
        uint256 result = _time / checkpointInterval * checkpointInterval;
        if (result < _time) result += checkpointInterval;
        return result;
    }

    // bias's decrease stops after `_startTime + maxTime`. In case `maxTime` is small
    // such that `_startTime + maxTime` ends up being less than `writtenTs`. That means that
    // it has already stopped at the time of writing a new point. In such case, we return
    // bigger or equal value of `_writtenTs`. Otherwise, if we always warp to
    // `_startTime + maxTime`, this can cause underflow/overflow in the `curve`'s checkpoint function.
    function getEndTimestamp(
        uint256 _startTimeTs,
        uint256 _writtenTs,
        uint256 _extra
    ) internal view returns (uint256) {
        if (_startTimeTs + maxTime >= _writtenTs) {
            return _startTimeTs + maxTime + _extra;
        }

        return _writtenTs + _extra;
    }

    function getEndTimestamp(
        uint256 _startTimeTs,
        uint256 _writtenTs
    ) internal view returns (uint256) {
        return getEndTimestamp(_startTimeTs, _writtenTs, 0);
    }
}
