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
        (int256[2] memory coefficients, uint256 maxEpoch) = CurveConstantLib.getCoefficients();
        address newImpl = address(new Curve(coefficients, maxEpoch));
        curve.upgradeTo(newImpl);
        assertEq(curve.implementation(), newImpl);

        bytes memory err = _authErr(attacker, address(curve), curve.CURVE_ADMIN_ROLE());
        vm.prank(attacker);
        vm.expectRevert(err);
        curve.upgradeTo(newImpl);
    }

    function testCannotWriteNewCheckpointInPast() public {
        vm.warp(2 weeks + 1 hours);

        LockedBalanceDecreasing memory first = LockedBalanceDecreasing(LockedBalance({amount: 100, start: 2 weeks}), 0);
        LockedBalanceDecreasing memory second = LockedBalanceDecreasing(LockedBalance({amount: 200, start: 1 weeks}), 0);

        escrow.checkpoint(1, _getEmptyLockedBalance(), first);
        vm.expectRevert(InvalidCheckpoint.selector);
        escrow.checkpoint(1, first, second);
    }

    function testCannotWritenewCheckpointAtWeekBoundary() public {
        vm.warp(3 weeks);

        vm.expectRevert(CheckpointOnDepositIntervalNotAllowed.selector);
        escrow.checkpoint(1, _getEmptyLockedBalance(), LockedBalanceDecreasing(LockedBalance({amount: 100, start: 3 weeks}), 0));
    }

    function testCannotMergeIfNonMatureWithDifferentStartDates() public {
        vm.warp(2 weeks + 1 hours);

        LockedBalanceDecreasing memory first = LockedBalanceDecreasing(
            LockedBalance({amount: 100, start: 2 weeks}),
            0
        );
        LockedBalanceDecreasing memory second = LockedBalanceDecreasing(
            LockedBalance({amount: 200, start: 2 weeks + 1 hours}),
            0
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidLocks.selector, 1, first, second));
        escrow.checkpoint(1, first, second);
    }

    function testCanWriteNewCheckpointsAtSameTime() public {
        vm.warp(1 weeks + 1 hours);

        LockedBalanceDecreasing memory first = LockedBalanceDecreasing(
            LockedBalance({amount: 100, start: 1 weeks}),
            0
        );
        LockedBalanceDecreasing memory second = LockedBalanceDecreasing(
            LockedBalance({amount: 200, start: 1 weeks}),
            0
        );

        escrow.checkpoint(1, _getEmptyLockedBalance(), first);
        escrow.checkpoint(
            1,
            first,
            LockedBalanceDecreasing(
                LockedBalance({amount: first.lockedBalance.amount + second.lockedBalance.amount, start: 1 weeks}),
                0
            )
        );

        // check we have only 1 token interval
        assertEq(curve.tokenPointIntervals(1), 1);
        assertEq(
            curve.tokenPointHistory(1, 1).bias.toInt256(),
            biasFP(100, 1 hours) + biasFP(200, 1 hours)
        );
        assertEq(curve.tokenPointHistory(1, 1).slope, slopeFP(200) + slopeFP(100));
    }
}
