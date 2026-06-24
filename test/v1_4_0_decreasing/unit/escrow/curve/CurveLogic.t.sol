pragma solidity ^0.8.17;

import {
    Clock,
    CurveConstantLib,
    Curve,
    ILockedBalanceDecreasing,
    IVotingEscrowDecreasing as IVotingEscrow,
    IEscrowCurveDecreasing as IEscrowCurve,
    IDeprecated
} from "../../../versions.sol";
import {CurveBase} from "./CurveBase.t.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract TestDecreasingCurveLogic is CurveBase {
    using SafeCast for int256;
    using SafeCast for uint256;

    address attacker = address(0x1);
    error InvalidCheckpoint();
    error CheckpointOnDepositIntervalNotAllowed();
    error InvalidLocks(
        uint256 tokenId,
        LockedBalanceDecreasing fromLocked,
        LockedBalanceDecreasing newLocked
    );

    function testUUPSUpgrade() public {
        (int256 constantCoefficient, int256 linearDenominator, uint256 maxEpochs) = CurveConstantLib.getParams();
        address newImpl = address(new Curve(constantCoefficient, linearDenominator, maxEpochs));
        curve.upgradeTo(newImpl);
        assertEq(curve.implementation(), newImpl);

        bytes memory err = _authErr(attacker, address(curve), curve.CURVE_ADMIN_ROLE());
        vm.prank(attacker);
        vm.expectRevert(err);
        curve.upgradeTo(newImpl);
    }

    function testCannotWriteNewCheckpointInPast() public {
        vm.warp(2 weeks + 1 hours);

        LockedBalanceDecreasing memory first = _lockedBalanceToDecreasing(100, 2 weeks);
        LockedBalanceDecreasing memory second = _lockedBalanceToDecreasing(200, 1 weeks);

        escrow.checkpoint(1, _getEmptyLockedBalance(), first);
        vm.expectRevert(InvalidCheckpoint.selector);
        escrow.checkpoint(1, first, second);
    }

    function testCanWritenewCheckpointAtWeekBoundary() public {
        vm.warp(3 weeks);

        escrow.checkpoint(1, _getEmptyLockedBalance(), _lockedBalanceToDecreasing(100, 3 weeks));
    }

    function testCanCheckpointWithDifferentStartDates() public {
        vm.warp(2 weeks + 1 hours);

        LockedBalanceDecreasing memory first = _lockedBalanceToDecreasing(100, 2 weeks);
        LockedBalanceDecreasing memory second = _lockedBalanceToDecreasing(200, 2 weeks + 1 hours);

        // The escrow is responsible for ensuring valid lock transitions (e.g. via canMerge).
        // The curve itself allows checkpointing with different start dates to support
        // increaseUnlockTime and other legitimate operations.
        escrow.checkpoint(1, first, second);
    }

    function testCanWriteNewCheckpointsAtSameTime() public {
        vm.warp(1 weeks + 1 hours);

        LockedBalanceDecreasing memory first = _lockedBalanceToDecreasing(100, 1 weeks);
        LockedBalanceDecreasing memory second = _lockedBalanceToDecreasing(300, 1 weeks);

        escrow.checkpoint(1, _getEmptyLockedBalance(), first);
        escrow.checkpoint(1, first, second);

        // check we have only 1 token interval
        assertEq(curve.tokenPointIntervals(1), 1);
        assertEq(curve.tokenPointHistory(1, 1).bias.toInt256(), biasFP(second.lockedBalance.amount, 0));
        assertEq(curve.tokenPointHistory(1, 1).slope, slopeFP(second.lockedBalance.amount));
    }
}
