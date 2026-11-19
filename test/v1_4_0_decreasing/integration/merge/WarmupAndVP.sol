pragma solidity ^0.8.17;

import {EscrowBase} from "../../base/EscrowBase.sol";

import {
    Clock,
    IClock,
    Lock,
    VotingEscrow,
    IVotingEscrowDecreasing,
    IEscrowCurveDecreasing,
    IVotingEscrowDecreasing,
    IVotingEscrowCoreErrors,
    IMerge,
    ISplit,
    ILockedBalanceIncreasing,
    IEscrowCurveGlobalStorage,
    IEscrowCurveTokenStorage,
    IEscrowCurveGlobalStorage
} from "../../versions.sol";

contract TestMerge_WarmUpAndVotingPower is
    IEscrowCurveTokenStorage,
    IEscrowCurveGlobalStorage,
    EscrowBase
{
    uint256 from;
    uint256 to;
    uint256 weekStart;

    function setUp() public override {
        super.setUp();

        super.mintAndApproveEscrow();

        // Start from 1, so weekStartTs and block.timestamp differ.
        vm.warp(1);

        from = escrow.createLock(Lock_1_Amount, MAX_TIME);
        to = escrow.createLock(Lock_2_Amount, MAX_TIME);
        weekStart = weekStartTs(block.timestamp);
    }

    function test_Merge() public {
        escrow.merge(from, to);

        vm.warp(block.timestamp + 1 weeks);

        assertEq(escrow.votingPower(from), 0);
        assertEq(
            escrow.votingPower(to),
            bias(Lock_1_Amount, block.timestamp - weekStart) +
                bias(Lock_2_Amount, block.timestamp - weekStart)
        );
    }
}
