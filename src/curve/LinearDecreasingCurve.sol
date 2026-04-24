/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// interfaces
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {
    IVotingEscrowDecreasing as IVotingEscrow
} from "@escrow/IVotingEscrowDecreasing.sol";
import {
    IEscrowCurveDecreasing as IEscrowCurve,
    IEscrowCurveGlobal,
    IEscrowCurveCore,
    IEscrowCurveToken
} from "@curve/IEscrowCurveDecreasing.sol";

import {IClockUser, IClockV1_2_0 as IClock} from "@clock/IClock_v1_2_0.sol";

// libraries
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedFixedPointMath} from "@libs/SignedFixedPointMathLib.sol";
import {CurveConstantLib} from "@libs/CurveConstantLib.sol";

// contracts
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable as ReentrancyGuard
} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {
    DaoAuthorizableUpgradeable as DaoAuthorizable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";

/// @title Linear Decreasing Escrow Curve
contract LinearDecreasingCurve is
    IEscrowCurve,
    IClockUser,
    ReentrancyGuard,
    DaoAuthorizable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SignedFixedPointMath for int256;

    /// @notice Administrator role for the contract
    bytes32 public constant CURVE_ADMIN_ROLE = keccak256("CURVE_ADMIN_ROLE");

    /// @notice The VotingEscrow contract address
    address public escrow;

    /// @notice The Clock contract address
    address public clock;

    /// @notice tokenId => latest index: incremented on a per-tokenId basis
    /// @custom:oz-renamed-from tokenPointIntervals
    mapping(uint256 => uint256) public tokenPointLatestIndex;

    /// @dev tokenId => tokenPointIntervals => TokenPoint
    /// @dev The Array is fixed so we can write to it in the future
    /// This implementation means that very short intervals may be challenging
    mapping(uint256 => TokenPoint[1_000_000_000]) internal _tokenPointHistory;

    /*//////////////////////////////////////////////////////////////
                                MATH
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    int256 private immutable SHARED_LINEAR_DENOMINATOR;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    int256 private immutable SHARED_CONSTANT_COEFFICIENT;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 private immutable MAX_EPOCHS;

    /*//////////////////////////////////////////////////////////////
                            ADDED: TOTAL SUPPLY(1.2.0)
    //////////////////////////////////////////////////////////////*/

    /// @dev The latest global point index.
    uint256 public globalPointLatestIndex;

    // endTime => summed up slopes at that endTime
    mapping(uint256 => int256) public slopeChanges;

    /// @dev The global point history
    mapping(uint256 => GlobalPoint) internal _globalPointHistory;

    /*//////////////////////////////////////////////////////////////
                              INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(int256[2] memory _coefficients, uint256 _maxEpochs) {
        SHARED_CONSTANT_COEFFICIENT = _coefficients[0];
        SHARED_LINEAR_DENOMINATOR = _coefficients[1];

        MAX_EPOCHS = _maxEpochs;

        _disableInitializers();
    }

    /// @param _escrow VotingEscrow contract address
    function initialize(address _escrow, address _dao, address _clock) external initializer {
        escrow = _escrow;
        clock = _clock;

        __ReentrancyGuard_init();
        __DaoAuthorizableUpgradeable_init(IDAO(_dao));

        // other initializers are empty
    }

    /*//////////////////////////////////////////////////////////////
                              CURVE COEFFICIENTS
    //////////////////////////////////////////////////////////////*/

    /// @return The coefficient for the curve's linear term, for the given amount
    function _getLinearCoeff(uint256 amount) internal view virtual returns (int256) {
        return amount.toInt256() * 1e18 / SHARED_LINEAR_DENOMINATOR;
    }

    /// @return The constant coefficient of the decreasing curve, for the given amount
    /// @dev In this case, the constant term is 1 so we just case the amount
    function _getConstantCoeff(uint256 amount) internal view virtual returns (int256) {
        return amount.toInt256() * SHARED_CONSTANT_COEFFICIENT;
    }

    /// @return The coefficients of the linear curve, for the given amount
    /// @dev The coefficients are returned in the order [constant, linear]
    function _getCoefficients(uint256 amount) internal view virtual returns (int256[2] memory) {
        return [_getConstantCoeff(amount), _getLinearCoeff(amount)];
    }

    /// @return The coefficients of the linear curve, for the given amount
    /// @dev The coefficients are returned in the order [constant, linear]
    /// and are converted to regular 256-bit signed integers instead of their fixed-point representation
    function getCoefficients(uint256 amount) external view virtual returns (int256[2] memory) {
        int256[2] memory coefficients = _getCoefficients(amount);

        return [
            coefficients[0] / 1e18, // amount
            coefficients[1] / 1e18 // slope
        ];
    }

    // To make sure that locks reach zero exactly at the end of the epoch
    function getFlooredAmount(uint256 _amount) public view returns (uint256) {
        uint256 denominator = (-SHARED_LINEAR_DENOMINATOR).toUint256();
        return _amount / denominator * denominator;
    }

    /*//////////////////////////////////////////////////////////////
                              CURVE BIAS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the bias for the given time elapsed and amount, up to the maximum time
    function getBias(uint256 timeElapsed, uint256 amount) external view returns (uint256) {
        int256[2] memory coefficients = _getCoefficients(getFlooredAmount(amount));
        return _getBias(timeElapsed, coefficients[0], coefficients[1]);
    }

    /// @notice Returns the bias for the given time elapsed and amount, up to the maximum time
    /// @dev Returned values from these functions are in fixed point representation
    ///    which is not the case in `getBias`.
    function _getBias(
        uint256 _timeElapsed,
        int256 _constantCoeff,
        int256 _linearCoeff
    ) internal pure returns (uint256) {
        int256 bias = _linearCoeff * int256(_timeElapsed) + _constantCoeff;
        if (bias < 0) bias = 0;

        return bias.toUint256();
    }

    function _getBiasAndSlope(
        uint256 _timeElapsed,
        uint256 _amount
    ) internal view returns (uint256, int256) {
        int256 slope = _getLinearCoeff(_amount);
        uint256 bias = _getBias(
            _timeElapsed,
            _getConstantCoeff(_amount),
            slope
        );

        return (bias, slope);
    }

    function maxTime() public view virtual returns (uint256) {
        return IClock(clock).epochDuration() * MAX_EPOCHS;
    }

    /*//////////////////////////////////////////////////////////////
                              BALANCE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEscrowCurveToken
    function tokenPointHistory(
        uint256 _tokenId,
        uint256 _index
    ) external view returns (TokenPoint memory point) {
        return _tokenPointHistory[_tokenId][_index];
    }

    /// @inheritdoc IEscrowCurveGlobal
    function globalPointHistory(uint256 _index) public view returns (GlobalPoint memory) {
        return _globalPointHistory[_index];
    }

    /// @inheritdoc IEscrowCurveToken
    function tokenPointIntervals(uint256 _tokenId) external view returns (uint256) {
        return tokenPointLatestIndex[_tokenId];
    }

    /// @inheritdoc IEscrowCurveCore
    function votingPowerAt(uint256 _tokenId, uint256 _t) external view returns (uint256) {
        uint256 interval = _getPastTokenPointInterval(_tokenId, _t);

        // epoch 0 is an empty point
        if (interval == 0) return 0;

        // Note that very first point is saved at index 1.
        // Grab last point before `_t`.
        TokenPoint memory lastPoint = _tokenPointHistory[_tokenId][interval];
        int256 bias = lastPoint.bias.toInt256();
        int256 slope = lastPoint.slope;

        uint256 elapsed = _t - lastPoint.writtenTs;

        return _getBias(elapsed, bias, slope) / 1e18;
    }

    /// @inheritdoc IEscrowCurveCore
    function supplyAt(uint256 _timestamp) external view returns (uint256) {
        return _supplyAt(_timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                              CHECKPOINT
    //////////////////////////////////////////////////////////////*/

    /// @notice A checkpoint can be called by the VotingEscrow contract to snapshot the user's voting power
    function checkpoint(
        uint256 _tokenId,
        IVotingEscrow.LockedBalanceDecreasing memory _oldLocked,
        IVotingEscrow.LockedBalanceDecreasing memory _newLocked
    ) external nonReentrant {
        if (msg.sender != escrow) revert OnlyEscrow();
        _checkpoint(_tokenId, _oldLocked, _newLocked);
    }

    /// @notice Record user data to checkpoints. Used by VotingEscrow system.
    /// @param _tokenId NFT token ID.
    /// @param _fromLocked The locked from which we're moving.
    /// @param _newLocked New locked amount / end lock time for the user
    function _checkpoint(
        uint256 _tokenId,
        IVotingEscrow.LockedBalanceDecreasing memory _fromLocked,
        IVotingEscrow.LockedBalanceDecreasing memory _newLocked
    ) internal {
        // this implementation doesn't yet support manual checkpointing
        if (_tokenId == 0) revert InvalidTokenId();

        if (_newLocked.lockedBalance.start < _fromLocked.lockedBalance.start) {
            revert InvalidCheckpoint();
        }

        uint256 _globalPointLatestIndex = globalPointLatestIndex;

        // Get the slope and bias for `_newLocked`...
        (uint256 newLockBias, int256 newLockSlope) = _getBiasAndSlope(
             _newLocked.effectiveStart - _newLocked.lockedBalance.start,
             getFlooredAmount(_newLocked.lockedBalance.amount)
        );

        GlobalPoint memory lastPoint = GlobalPoint({
            bias: 0,
            slope: 0,
            writtenTs: uint48(_newLocked.effectiveStart)
        });

        if (_globalPointLatestIndex > 0) {
            lastPoint = _globalPointHistory[_globalPointLatestIndex];
        }

        {
            uint256 checkpointInterval = IClock(clock).checkpointInterval();
            uint256 lastPointCheckpoint = lastPoint.writtenTs;
            uint256 t_i = lastPointCheckpoint;

            for (uint256 i = 0; i < 255; ++i) {
                t_i += checkpointInterval;
                int256 dSlope;

                if (t_i > _newLocked.effectiveStart) {
                    t_i = _newLocked.effectiveStart;
                } else {
                    dSlope = slopeChanges[t_i];
                }

                //int256 newBias = lastPoint.bias.toInt256() + lastPoint.slope * (t_i - lastPointCheckpoint).toInt256();
                // Note: We assume _newLocked.effectiveStart >= _newLocked.effectiveStart
                lastPoint.bias = _getBias(t_i - lastPointCheckpoint, lastPoint.bias.toInt256(), lastPoint.slope);

                lastPoint.slope -= dSlope;
                if (lastPoint.slope > 0) lastPoint.slope = 0;

                lastPointCheckpoint = t_i;
                lastPoint.writtenTs = uint48(t_i);
                _globalPointLatestIndex += 1;

                // Here we store intermediate points, the last one is stored at the end
                if (t_i == _newLocked.effectiveStart) {
                    break;
                } else {
                    _globalPointHistory[_globalPointLatestIndex] = lastPoint;
                }
            }
        }

        uint256 _maxTime = maxTime();
        uint256 newLockedEnd = _newLocked.lockedBalance.start + _maxTime;
        uint256 fromLockedEnd = _fromLocked.lockedBalance.start + _maxTime;

        // The following condition is true if merging non-mature locks with different start dates.
        // current version of ve-governance is built around the assumption that merge can only
        // occur if tokens are either mature or have the same start dates. Even though `escrow`
        // does this check before calling `checkpoint` on curve, it's still a safety measure to repeat
        // the check in case the code of checkpoint might be called by another contract in the future.
        if (
            _fromLocked.lockedBalance.start != 0 &&
            _newLocked.lockedBalance.start != 0 &&
            _fromLocked.lockedBalance.start != _newLocked.lockedBalance.start &&
            (newLockedEnd >= _newLocked.effectiveStart || fromLockedEnd >= _newLocked.effectiveStart)
        ) {
            revert InvalidLocks(_tokenId, _fromLocked, _newLocked);
        }

        // newLocked could be ended in case of merge, when
        // a token is already mature.
        if (newLockedEnd <= _newLocked.effectiveStart) {
            newLockSlope = 0;
        }

        (uint256 oldLockBias, int256 oldLockSlope) = (0, 0);

        if (_fromLocked.lockedBalance.amount > 0) {
            (oldLockBias, oldLockSlope) = _getBiasAndSlope(
                _newLocked.effectiveStart - _fromLocked.lockedBalance.start,
                getFlooredAmount(_fromLocked.lockedBalance.amount)
            );

            // In case fromLocked already ended, its slope would already
            // be subtracted from `lastPoint.slope` in the above for loop.
            // So we make this 0 to not subtract double times.
            if (fromLockedEnd <= _newLocked.effectiveStart) {
                oldLockSlope = 0;
            }
        }

        {

            int256 lastPointNewBias = lastPoint.bias.toInt256() + newLockBias.toInt256() - oldLockBias.toInt256();
            if (lastPointNewBias < 0) {
                lastPoint.bias = 0;
            } else {
                lastPoint.bias = lastPointNewBias.toUint256();
            }
            lastPoint.slope += (newLockSlope - oldLockSlope);
            if (lastPoint.slope > 0) lastPoint.slope = 0;
        }

        uint256 tokenLatestIndex = tokenPointLatestIndex[_tokenId];

        // The token point already exists..
        if (tokenLatestIndex > 0) {
            if (fromLockedEnd > _newLocked.effectiveStart) {
                slopeChanges[fromLockedEnd] -= oldLockSlope;
            }
        }

        // store new slope change
        slopeChanges[newLockedEnd] += newLockSlope;

        // Record the latest global point.
        _storeLatestGlobalPoint(lastPoint, _globalPointLatestIndex);

        // Create new token point and store.
        TokenPoint memory tNew;
        tNew.bias = newLockBias;
        tNew.slope = newLockSlope;
        tNew.writtenTs = _newLocked.effectiveStart;

        // Record the latest token point.
        _storeLatestTokenPoint(tNew, _tokenId, tokenLatestIndex);
    }

    /// @dev The private helper function to either store latest global point on a new index or overwrite it.
    ///      In case of overwriting, the latest global point index is not incremented.
    function _storeLatestGlobalPoint(GlobalPoint memory _p, uint256 _index) private {
        // If the timestamp of last stored global point is the same as
        // current timestamp, overwrite it, otherwise store a new one
        // to reduce unnecessary global points in the history for
        // gas costs and binary search efficiency.
        if (_index != 1 && _globalPointHistory[_index - 1].writtenTs == _p.writtenTs) {
            _globalPointHistory[_index - 1] = _p;
        } else {
            globalPointLatestIndex = _index;
            _globalPointHistory[_index] = _p;
        }
    }

    /// @dev The private helper function to either store latest token point on a new index or overwrite it.
    ///      In case of overwriting, the latest token point index is not incremented.
    function _storeLatestTokenPoint(
        TokenPoint memory _p,
        uint256 _tokenId,
        uint256 _index
    ) private {
        // If the timestamp of last stored token point is the same as
        // current timestamp, overwrite it, otherwise store a new one
        // to reduce unnecessary global points in the history for
        // gas costs and binary search efficiency.
        if (_index != 0 && _tokenPointHistory[_tokenId][_index].writtenTs == _p.writtenTs) {
            _tokenPointHistory[_tokenId][_index] = _p;
        } else {
            tokenPointLatestIndex[_tokenId] = ++_index;
            _tokenPointHistory[_tokenId][_index] = _p;
        }
    }

    /*///////////////////////////////////////////////////////////////
            Total Supply and Voting Power Calculations
    //////////////////////////////////////////////////////////////*/

    /// @notice Binary search to get the token point interval for a token id at or prior to a given timestamp
    /// Once we have the point , we can apply the bias calculation to get the voting power.
    /// @dev If a token point does not exist prior to the timestamp, this will return 0.
    function _getPastTokenPointInterval(
        uint256 _tokenId,
        uint256 _timestamp
    ) internal view returns (uint256) {
        uint256 tokenInterval = tokenPointLatestIndex[_tokenId];

        if (tokenInterval == 0) return 0;

        // if the most recent point is before the timestamp, return it
        if (_tokenPointHistory[_tokenId][tokenInterval].writtenTs <= _timestamp)
            return (tokenInterval);

        // Check if the first balance is after the timestamp
        // this means that the first epoch has yet to start
        if (_tokenPointHistory[_tokenId][1].writtenTs > _timestamp) return 0;

        uint256 lower = 0;
        uint256 upper = tokenInterval;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            TokenPoint storage tokenPoint = _tokenPointHistory[_tokenId][center];
            if (tokenPoint.writtenTs == _timestamp) {
                return center;
            } else if (tokenPoint.writtenTs < _timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    /// @notice Binary search to get the global point index at or prior to a given timestamp
    /// @dev If a checkpoint does not exist prior to the timestamp, this will return 0.
    /// @param _timestamp The timestamp to get a checkpoint at.
    /// @return Global point index
    function getPastGlobalPointIndex(uint256 _timestamp) internal view returns (uint256) {
        if (globalPointLatestIndex == 0) return 0;
        // First check most recent balance
        if (_globalPointHistory[globalPointLatestIndex].writtenTs <= _timestamp)
            return (globalPointLatestIndex);
        // Next check implicit zero balance
        if (_globalPointHistory[1].writtenTs > _timestamp) return 0;

        uint256 lower = 0;
        uint256 upper = globalPointLatestIndex;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            GlobalPoint storage globalPoint = _globalPointHistory[center];
            if (globalPoint.writtenTs == _timestamp) {
                return center;
            } else if (globalPoint.writtenTs < _timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    /// @notice Calculate total voting power at some point in the past
    /// @param _timestamp Time to calculate the total voting power at
    /// @return Total voting power at that time
    function _supplyAt(uint256 _timestamp) internal view returns (uint256) {
        uint256 epoch_ = getPastGlobalPointIndex(_timestamp);
        // epoch 0 is an empty point
        if (epoch_ == 0) return 0;
        GlobalPoint memory _point = _globalPointHistory[epoch_];

        int256 bias = _point.bias.toInt256();
        int256 slope = _point.slope;
        uint256 ts = _point.writtenTs; // changes in for loop.
        uint256 t_i = ts;

        uint256 checkpointInterval = IClock(clock).checkpointInterval();

        for (uint256 i = 0; i < 255; ++i) {
            t_i += checkpointInterval;
            int256 dSlope = 0;

            if (t_i > _timestamp) {
                t_i = _timestamp;
            } else {
                dSlope = slopeChanges[t_i];
            }

            bias += slope * int256(t_i - ts);

            if (t_i == _timestamp) {
                break;
            }
            slope -= dSlope;
            ts = t_i;
        }

        if (bias < 0) bias = 0;

        return uint256(bias / 1e18);
    }

    /*///////////////////////////////////////////////////////////////
                            UUPS Upgrade
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the address of the implementation contract in the [proxy storage slot](https://eips.ethereum.org/EIPS/eip-1967) slot the [UUPS proxy](https://eips.ethereum.org/EIPS/eip-1822) is pointing to.
    /// @return The address of the implementation contract.
    function implementation() public view returns (address) {
        return _getImplementation();
    }

    /// @notice Internal method authorizing the upgrade of the contract via the [upgradeability mechanism for UUPS proxies](https://docs.openzeppelin.com/contracts/4.x/api/proxy#UUPSUpgradeable) (see [ERC-1822](https://eips.ethereum.org/EIPS/eip-1822)).
    function _authorizeUpgrade(address) internal virtual override auth(CURVE_ADMIN_ROLE) {}

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[42] private __gap;
}
