// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.17;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotingEscrowDecreasing as IVotingEscrow} from "@escrow/IVotingEscrowDecreasing.sol";
import {IEscrowCurveDecreasing as IEscrowCurve} from "@curve/IEscrowCurveDecreasing.sol";
import {IClockV1_2_0 as IClock} from "@clock/IClock_v1_2_0.sol";
import {IRewardsDistributor} from "./IRewardsDistributor.sol";

/*
 * @title Curve Fee Distribution modified for ve(3,3) emissions
 * @author Curve Finance, andrecronje
 * @author velodrome.finance, @figs999, @pegahcarter
 * @author polaris
 */
// @dev Warning: Rewards are lost for epochs where total supply is zero
// @dev Warning: Rewards are lost for the from token after merge
contract RewardsDistributor is IRewardsDistributor {
    using SafeERC20 for IERC20;
    /// @inheritdoc IRewardsDistributor
    uint256 public immutable CHECKPOINT_INTERVAL; // Typically 1 week
    // Iterations for the claim loop
    uint256 public constant CLAIM_MAX_INTERVALS = 52;
    // We cap the checkpointing loop to avoid gas issues. It is unlikely that no rewards arrive for more than 4 years,
    // and even if that happens, it probably doesn't make much sense to rewind further than that.
    // @dev: Take into account if you use a checkpoint interval shorter than 1 week
    uint256 public constant CHECKPOINT_BATCH_SIZE = 208;

    /// @inheritdoc IRewardsDistributor
    uint256 public immutable START_INTERVAL_TIME;
    /// @inheritdoc IRewardsDistributor
    mapping(uint256 => uint256) public timeCursorOf;

    /// @inheritdoc IRewardsDistributor
    uint256 public lastTokenIntervalTime;
    uint256[1000000000000000] public tokensPerInterval;

    /// @inheritdoc IRewardsDistributor
    IVotingEscrow public immutable ve;
    IEscrowCurve public immutable curve;
    /// @inheritdoc IRewardsDistributor
    address public token;
    /// @inheritdoc IRewardsDistributor
    address public rewardsSender;
    /// @inheritdoc IRewardsDistributor
    uint256 public tokenLastBalance;

    constructor(address _ve, address _rewardsToken, address _rewardsSender) {
        ve = IVotingEscrow(_ve);
        CHECKPOINT_INTERVAL = IClock(ve.clock()).checkpointInterval();
        uint256 _t = (block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL;
        START_INTERVAL_TIME = _t;
        lastTokenIntervalTime = _t;
        curve = IEscrowCurve(ve.curve());
        token = _rewardsToken;
        rewardsSender = _rewardsSender;
    }

    /// @inheritdoc IRewardsDistributor
    function checkpointToken() external {
        if (msg.sender != rewardsSender) revert NotRewardsSender();

        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        uint256 toDistribute = tokenBalance - tokenLastBalance;
        if (toDistribute == 0) return;

        uint256 _lastTokenIntervalTime = lastTokenIntervalTime;
        uint256 currentIntervalTime = block.timestamp / CHECKPOINT_INTERVAL * CHECKPOINT_INTERVAL;
        if (currentIntervalTime == _lastTokenIntervalTime) {
            tokensPerInterval[currentIntervalTime] += toDistribute;
        } else {
            lastTokenIntervalTime = currentIntervalTime;
            uint256 intervalsSinceLast = (currentIntervalTime - _lastTokenIntervalTime) / CHECKPOINT_INTERVAL;
            uint256 thisIntervalPointer = _lastTokenIntervalTime;
            // We cap the max loop to avoid gas issues
            if (intervalsSinceLast > CHECKPOINT_BATCH_SIZE) {
                intervalsSinceLast = CHECKPOINT_BATCH_SIZE;
                thisIntervalPointer = currentIntervalTime - CHECKPOINT_BATCH_SIZE * CHECKPOINT_INTERVAL;
            }
            uint256 amountPerInterval = toDistribute / intervalsSinceLast;
            // We make sure that leaks due to rounding don't get lost when we update tokenLastBalance below
            toDistribute = amountPerInterval * intervalsSinceLast;
            for (uint256 i = 0; i < intervalsSinceLast; i++) {
                thisIntervalPointer += CHECKPOINT_INTERVAL;
                tokensPerInterval[thisIntervalPointer] = amountPerInterval;
            }
        }

        tokenLastBalance += toDistribute;

        emit CheckpointToken(currentIntervalTime, toDistribute);
    }

    function _claim(uint256 _tokenId, uint256 _lastTokenIntervalTime, uint256 _maxIntervals) internal returns (uint256) {
        _requireApprovedOrOwner(_tokenId);
        (uint256 toDistribute, uint256 epochStart, uint256 intervalCursor) =
            _claimable(_tokenId, _lastTokenIntervalTime, _maxIntervals);
        timeCursorOf[_tokenId] = intervalCursor;
        if (toDistribute == 0) return 0;

        emit Claimed(_tokenId, epochStart, intervalCursor, toDistribute);
        return toDistribute;
    }

    function _claimable(uint256 _tokenId, uint256 _lastTokenIntervalTime, uint256 _maxIntervals)
        internal
        view
        returns (uint256 toDistribute, uint256 intervalCursorStart, uint256 intervalCursor)
    {
        intervalCursor = timeCursorOf[_tokenId];
        intervalCursorStart = intervalCursor;

        // case where token does not exist
        uint256 locked = ve.locked(_tokenId).amount;
        if (locked == 0) return (0, intervalCursorStart, intervalCursor);

        // case where token exists but has never been claimed
        if (intervalCursor == 0) {
            IEscrowCurve.TokenPoint memory userPoint = curve.tokenPointHistory(_tokenId, 1);
            intervalCursor = userPoint.writtenTs;
            intervalCursorStart = intervalCursor;
        }
        if (intervalCursor < START_INTERVAL_TIME) intervalCursor = START_INTERVAL_TIME;

        uint256 currentIntervalTime = block.timestamp / CHECKPOINT_INTERVAL * CHECKPOINT_INTERVAL;
        for (uint256 i = 0; i < _maxIntervals; i++) {
            // intervalCursor > _lastTokenIntervalTime: No rewards after this point
            // intervalCursor >= currentIntervalTime: We don't claim until interval finishes, as new rewards may arrive
            if (intervalCursor > _lastTokenIntervalTime || intervalCursor >= currentIntervalTime) break;

            uint256 balance = ve.votingPowerAt(_tokenId, intervalCursor);
            uint256 supply = ve.totalVotingPowerAt(intervalCursor);
            if (supply > 0) {
                toDistribute += (balance * tokensPerInterval[intervalCursor]) / supply;
            }
            intervalCursor += CHECKPOINT_INTERVAL;
        }
    }

    /// @inheritdoc IRewardsDistributor
    function claimable(uint256 _tokenId) external view returns (uint256 claimable_) {
        (claimable_,,) = _claimable(_tokenId, lastTokenIntervalTime, CLAIM_MAX_INTERVALS);
    }

    /// @inheritdoc IRewardsDistributor
    function claimable(uint256 _tokenId, uint256 _maxIntervals) external view returns (uint256 claimable_) {
        (claimable_,,) = _claimable(_tokenId, lastTokenIntervalTime, _maxIntervals);
    }

    /// @inheritdoc IRewardsDistributor
    function claim(uint256 _tokenId) external returns (uint256) {
        return claim(_tokenId, msg.sender, CLAIM_MAX_INTERVALS);
    }

    /// @inheritdoc IRewardsDistributor
    function claim(uint256 _tokenId, address _receiver, uint256 _maxIntervals) public returns (uint256) {
        uint256 amount = _claim(_tokenId, lastTokenIntervalTime, _maxIntervals);
        if (amount != 0) {
            IERC20(token).safeTransfer(_receiver, amount);
            tokenLastBalance -= amount;
        }
        return amount;
    }

    /// @inheritdoc IRewardsDistributor
    function claimMany(uint256[] calldata _tokenIds) external returns (bool) {
        return claimMany(_tokenIds, msg.sender, CLAIM_MAX_INTERVALS);
    }

    /// @inheritdoc IRewardsDistributor
    function claimMany(uint256[] calldata _tokenIds, address _receiver, uint256 _maxIntervals) public returns (bool) {
        uint256 total = 0;
        uint256 _length = _tokenIds.length;

        for (uint256 i = 0; i < _length; i++) {
            uint256 _tokenId = _tokenIds[i];
            if (_tokenId == 0) continue;
            uint256 amount = _claim(_tokenId, lastTokenIntervalTime, _maxIntervals);
            if (amount != 0) {
                total += amount;
            }
        }
        if (total != 0) {
            IERC20(token).safeTransfer(_receiver, total);
            tokenLastBalance -= total;
        }

        return true;
    }

    function _requireApprovedOrOwner(uint256 _tokenId) internal view {
        if (!ve.isApprovedOrOwner(msg.sender, _tokenId)) revert NotApprovedOrOwner();
    }
}
