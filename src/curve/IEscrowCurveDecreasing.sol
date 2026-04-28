/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../IDeprecated.sol";
import {ILockedBalanceIncreasing} from "@escrow/IVotingEscrowIncreasing.sol";

/*///////////////////////////////////////////////////////////////
                        Token Curve
//////////////////////////////////////////////////////////////*/

interface IEscrowCurveTokenStorage {
    /// @notice Captures the shape of the user's voting curve at a specific point in time
    /// @param bias The y intercept of the user's voting curve at the given time
    /// @param writtenTs The timestamp at which we locked the checkpoint / when the user voting curve is/was/will be updated
    /// @param coefficients The coefficients of the curve, supports up to quadratic curves.
    /// @dev Coefficients are stored in the following order: [constant, linear, quadratic]
    /// and not all coefficients are used for all curves.
    struct TokenPoint {
        uint256 bias;
        uint256 writtenTs;
        int256[3] coefficients;
    }
}

interface IEscrowCurveToken is IEscrowCurveTokenStorage {
    /// @notice Returns the latest index of the tokenId which can be used
    ///         to retrive token point from `tokenPointHistory` function.
    /// @dev This has been renamed to `tokenPointLatestIndex` in the latest upgrade, but
    ///      for backwards-compatibility, the function still stays in the contract.
    ///      Note that we treat it as deprecated, So use `tokenPointLatestIndex` instead.
    /// @return The latest index of the token id.
    function tokenPointIntervals(uint256 _tokenId) external view returns (uint256);

    /// @notice Returns the latest index of the tokenId which can be used
    ///         to retrive token point from `tokenPointHistory` function.
    /// @param _tokenId The NFT to return the latest token point index
    /// @return The latest index of the token id.
    function tokenPointLatestIndex(uint256 _tokenId) external view returns (uint256);

    /// @notice Returns the TokenPoint at the passed `_index`.
    /// @param _tokenId The NFT to return the TokenPoint for
    /// @param _index The index to return the TokenPoint at.
    function tokenPointHistory(
        uint256 _tokenId,
        uint256 _index
    ) external view returns (TokenPoint memory);
}

/*///////////////////////////////////////////////////////////////
                        Core Functions
//////////////////////////////////////////////////////////////*/

interface IEscrowCurveErrorsAndEvents {
    error InvalidTokenId();
    error InvalidCheckpoint();
    error OnlyEscrow();
    error CheckpointOnDepositIntervalNotAllowed();
    error InvalidLocks(
        uint256 tokenId,
        ILockedBalanceIncreasing.LockedBalance fromLocked,
        ILockedBalanceIncreasing.LockedBalance newLocked
    );
}

interface IEscrowCurveCore is IEscrowCurveErrorsAndEvents {
    /// @notice Get the current voting power for `_tokenId`
    /// @dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
    ///      Fetches last token point prior to a certain timestamp, then walks forward to timestamp.
    /// @param _tokenId NFT for lock
    /// @param _t Epoch time to return voting power at
    /// @return Token voting power
    function votingPowerAt(uint256 _tokenId, uint256 _t) external view returns (uint256);

    /// @notice Calculate total voting power at some point in the past
    /// @param _t Time to calculate the total voting power at
    /// @return Total voting power at that time
    function supplyAt(uint256 _t) external view returns (uint256);

    /// @notice Writes a snapshot of voting power at the current epoch
    /// @param _tokenId Snapshot a specific token
    /// @param _oldLocked The token's previous locked balance
    /// @param _newLocked The token's new locked balance
    function checkpoint(
        uint256 _tokenId,
        ILockedBalanceIncreasing.LockedBalance memory _oldLocked,
        ILockedBalanceIncreasing.LockedBalance memory _newLocked
    ) external;
}

interface IEscrowCurveMath {
    /// @notice Preview the curve coefficients for curves up to quadratic.
    /// @param amount The amount of tokens to calculate the coefficients for - given a fixed algebraic representation
    /// @return coefficients in the form [constant, linear, quadratic]
    /// @dev Not all coefficients are used for all curves
    function getCoefficients(uint256 amount) external view returns (int256[3] memory coefficients);

    /// @notice Bias is the token's voting weight
    function getBias(uint256 timeElapsed, uint256 amount) external view returns (uint256 bias);
}

/*///////////////////////////////////////////////////////////////
                        WARMUP CURVE
//////////////////////////////////////////////////////////////*/

interface IWarmupEvents {
    event WarmupSet(uint48 warmup);
}

interface IWarmup is IWarmupEvents {
    /// @notice Set the warmup period for the curve
    function setWarmupPeriod(uint48 _warmup) external;

    /// @notice the warmup period for the curve
    function warmupPeriod() external view returns (uint48);

    /// @notice check if the curve is past the warming period
    function isWarm(uint256 _tokenId) external view returns (bool);
}

// From v1_2_0:

/*///////////////////////////////////////////////////////////////
                        Global Curve
//////////////////////////////////////////////////////////////*/

interface IEscrowCurveGlobalStorage {
    /// @notice Captures the shape of the aggregate voting curve at a specific point in time
    /// @param bias The y intercept of the aggregate voting curve at the given time
    /// @param slope The slope of the aggregate voting curve at the given time
    /// @param writtenTs The timestamp at which the we last updated the aggregate voting curve
    struct GlobalPoint {
        int256 bias;
        int256 slope;
        uint48 writtenTs;
    }
}

interface IEscrowCurveGlobal is IEscrowCurveGlobalStorage {
    /// @notice Returns the global point at the passed epoch
    /// @param _index The index in an array to return the point for
    function globalPointHistory(uint256 _index) external view returns (GlobalPoint memory);
}

interface IEscrowCurveMaxTime is IEscrowCurveErrorsAndEvents {
    /// @return The max time allowed for the lock duration.
    function maxTime() external view returns (uint256);
}

/*///////////////////////////////////////////////////////////////
                        INCREASING CURVE
//////////////////////////////////////////////////////////////*/

interface IEscrowCurveDecreasing is
    IEscrowCurveCore,
    IEscrowCurveMath,
    IEscrowCurveToken,
    IEscrowCurveMaxTime,
    IEscrowCurveGlobal,
    IDeprecated
{}

