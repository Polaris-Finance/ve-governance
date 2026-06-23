/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// The initial bias is scaled by a multiplier, which defaults to 1x (no scaling).
// To start with a higher initial bias (e.g., 1.5x the amount), update this value accordingly.
// For example, set it to 1.5 in case you want to start with 1.5 * amount.
int256 constant INITIAL_BIAS_MULTIPLIER = 1;

/// @title CurveConstantLib
/// @notice Precomputed coefficients for escrow curve
/// Below are the shared coefficients for the linear terms
/// @dev This curve goes from 1x -> 0x voting power over a 4 year time horizon
/// Epochs are still 2 weeks long
library CurveConstantLib {
    int256 internal constant SHARED_CONSTANT_COEFFICIENT = INITIAL_BIAS_MULTIPLIER * 1e18;

    /// @dev straight line so the curve is decreasing only in the linear term
    /// - 1 / (104 * SECONDS_IN_2_WEEKS)
    int256 internal constant SHARED_LINEAR_DENOMINATOR = -int256(MAX_EPOCHS) * 2 weeks;
    int256 internal constant SHARED_LINEAR_COEFFICIENT = 1e18 / SHARED_LINEAR_DENOMINATOR;

    /// @dev this curve is linear
    int256 internal constant SHARED_QUADRATIC_COEFFICIENT = 0;

    /// @dev the maxiumum number of epochs the cure can keep decreasing (max lock time)
    /// 26 epochs in a year, 4 years = 104 epochs
    uint256 internal constant MAX_EPOCHS = 104;

    function getCoefficients() internal pure returns (int256[2] memory, uint256) {
        int256[2] memory coefficients;
        coefficients[0] = SHARED_CONSTANT_COEFFICIENT;
        coefficients[1] = SHARED_LINEAR_DENOMINATOR;
        uint256 maxEpoch = MAX_EPOCHS;

        return (coefficients, maxEpoch);
    }
}
