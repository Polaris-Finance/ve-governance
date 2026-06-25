// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.17;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotingEscrowDecreasing as IVotingEscrow} from "@escrow/IVotingEscrowDecreasing.sol";
import {IEscrowCurveDecreasing as IEscrowCurve} from "@curve/IEscrowCurveDecreasing.sol";
import {IRewardsDistributor} from "./IRewardsDistributor.sol";

/*
 * @title Curve Fee Distribution modified for ve(3,3) emissions
 * @author Curve Finance, andrecronje
 * @author velodrome.finance, @figs999, @pegahcarter
 * @author polaris
 */
// TODO: Rewards are lost for epochs where total supply is zero
// TODO: Rewards are lost for the from token after merge?
contract RewardsDistributor is IRewardsDistributor {
    using SafeERC20 for IERC20;
    /// @inheritdoc IRewardsDistributor
    uint256 public constant WEEK = 1 weeks;
    // Iterations for the claim loop
    uint256 public constant CLAIM_MAX_WEEKS = 52;
    // We cap the checkpointing loop to avoid gas issues. It is unlikely that no rewards arrive for more than 4 years,
    // and even if that happens, it probably doesn't make much sense to rewind further than that.
    uint256 public constant CHECKPOINT_BATCH_SIZE = 208;

    /// @inheritdoc IRewardsDistributor
    uint256 public immutable START_WEEK_TIME;
    /// @inheritdoc IRewardsDistributor
    mapping(uint256 => uint256) public timeCursorOf;

    /// @inheritdoc IRewardsDistributor
    uint256 public lastTokenWeekTime;
    uint256[1000000000000000] public tokensPerWeek;

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
        uint256 _t = (block.timestamp / WEEK) * WEEK;
        START_WEEK_TIME = _t;
        lastTokenWeekTime = _t;
        ve = IVotingEscrow(_ve);
        token = _rewardsToken;
        curve = IEscrowCurve(ve.curve());
        rewardsSender = _rewardsSender;
    }

    /// @inheritdoc IRewardsDistributor
    function checkpointToken() external {
        if (msg.sender != rewardsSender) revert NotRewardsSender();

        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        uint256 toDistribute = tokenBalance - tokenLastBalance;
        if (toDistribute == 0) return;

        uint256 _lastTokenWeekTime = lastTokenWeekTime;
        uint256 currentWeekTime = block.timestamp / WEEK * WEEK;
        if (currentWeekTime == _lastTokenWeekTime) {
            tokensPerWeek[currentWeekTime] += toDistribute;
        } else {
            lastTokenWeekTime = currentWeekTime;
            uint256 weeksSinceLast = (currentWeekTime - _lastTokenWeekTime) / WEEK;
            uint256 thisWeekPointer = _lastTokenWeekTime;
            // We cap the max loop to avoid gas issues
            if (weeksSinceLast > CHECKPOINT_BATCH_SIZE) {
                weeksSinceLast = CHECKPOINT_BATCH_SIZE;
                thisWeekPointer = currentWeekTime - CHECKPOINT_BATCH_SIZE * WEEK;
            }
            uint256 weeklyAmount = toDistribute / weeksSinceLast;
            // We make sure that leaks due to rounding don't get lost when we update tokenLastBalance below
            toDistribute = weeklyAmount * weeksSinceLast;
            for (uint256 i = 0; i < weeksSinceLast; i++) {
                thisWeekPointer += WEEK;
                tokensPerWeek[thisWeekPointer] = weeklyAmount;
            }
        }

        tokenLastBalance += toDistribute;

        emit CheckpointToken(currentWeekTime, toDistribute);
    }

    function _claim(uint256 _tokenId, uint256 _lastTokenWeekTime, uint256 _maxWeeks) internal returns (uint256) {
        _requireApprovedOrOwner(_tokenId);
        (uint256 toDistribute, uint256 epochStart, uint256 weekCursor) =
            _claimable(_tokenId, _lastTokenWeekTime, _maxWeeks);
        timeCursorOf[_tokenId] = weekCursor;
        if (toDistribute == 0) return 0;

        emit Claimed(_tokenId, epochStart, weekCursor, toDistribute);
        return toDistribute;
    }

    function _claimable(uint256 _tokenId, uint256 _lastTokenWeekTime, uint256 _maxWeeks)
        internal
        view
        returns (uint256 toDistribute, uint256 weekCursorStart, uint256 weekCursor)
    {
        weekCursor = timeCursorOf[_tokenId];
        weekCursorStart = weekCursor;

        // case where token does not exist
        uint256 locked = ve.locked(_tokenId).amount;
        if (locked == 0) return (0, weekCursorStart, weekCursor);

        // case where token exists but has never been claimed
        if (weekCursor == 0) {
            IEscrowCurve.TokenPoint memory userPoint = curve.tokenPointHistory(_tokenId, 1);
            weekCursor = userPoint.writtenTs;
            weekCursorStart = weekCursor;
        }
        if (weekCursor < START_WEEK_TIME) weekCursor = START_WEEK_TIME;

        uint256 currentWeekTime = block.timestamp / WEEK * WEEK;
        for (uint256 i = 0; i < _maxWeeks; i++) {
            // weekCursor > _lastTokenWeekTime: No rewards after this point
            // weekCursor >= currentWeekTime: We don't claim until week finishes, as new rewards may arrive
            if (weekCursor > _lastTokenWeekTime || weekCursor >= currentWeekTime) break;

            uint256 balance = ve.votingPowerAt(_tokenId, weekCursor);
            uint256 supply = ve.totalVotingPowerAt(weekCursor);
            if (supply > 0) {
                toDistribute += (balance * tokensPerWeek[weekCursor]) / supply;
            }
            weekCursor += WEEK;
        }
    }

    /// @inheritdoc IRewardsDistributor
    function claimable(uint256 _tokenId) external view returns (uint256 claimable_) {
        (claimable_,,) = _claimable(_tokenId, lastTokenWeekTime, CLAIM_MAX_WEEKS);
    }

    /// @inheritdoc IRewardsDistributor
    function claimable(uint256 _tokenId, uint256 _maxWeeks) external view returns (uint256 claimable_) {
        (claimable_,,) = _claimable(_tokenId, lastTokenWeekTime, _maxWeeks);
    }

    /// @inheritdoc IRewardsDistributor
    function claim(uint256 _tokenId) external returns (uint256) {
        return claim(_tokenId, msg.sender, CLAIM_MAX_WEEKS);
    }

    /// @inheritdoc IRewardsDistributor
    function claim(uint256 _tokenId, address _receiver, uint256 _maxWeeks) public returns (uint256) {
        uint256 amount = _claim(_tokenId, lastTokenWeekTime, _maxWeeks);
        if (amount != 0) {
            IERC20(token).safeTransfer(_receiver, amount);
            tokenLastBalance -= amount;
        }
        return amount;
    }

    /// @inheritdoc IRewardsDistributor
    function claimMany(uint256[] calldata _tokenIds) external returns (bool) {
        return claimMany(_tokenIds, msg.sender, CLAIM_MAX_WEEKS);
    }

    /// @inheritdoc IRewardsDistributor
    function claimMany(uint256[] calldata _tokenIds, address _receiver, uint256 _maxWeeks) public returns (bool) {
        uint256 total = 0;
        uint256 _length = _tokenIds.length;

        for (uint256 i = 0; i < _length; i++) {
            uint256 _tokenId = _tokenIds[i];
            if (_tokenId == 0) continue;
            uint256 amount = _claim(_tokenId, lastTokenWeekTime, _maxWeeks);
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
