pragma solidity ^0.8.17;

import {EscrowBase, IAddressGaugeVote} from "../../base/EscrowBase.sol";

import {
    Clock,
    IClock,
    Lock,
    VotingEscrow,
    IVotingEscrowDecreasing,
    IEscrowCurveDecreasing,
    IVotingEscrowCoreErrors,
    IMerge,
    ISplit,
    IEscrowCurveGlobalStorage,
    IEscrowCurveTokenStorage
} from "../../versions.sol";

contract TestModifyLock_DelegationAndVoter is
    IEscrowCurveTokenStorage,
    IEscrowCurveGlobalStorage,
    EscrowBase
{
    function setUp() public override {
        super.setUp();
        super.mintAndApproveEscrow();
    }

    function test_lockPermanent_updatesDelegationAndVotes() public {
        vm.warp(1);

        address alice = address(0x123);
        uint256 amount = getFlooredAmount(15e18);
        token.transfer(alice, amount);

        vm.warp(2 weeks + 1 hours + 1);
        address gauge = address(0x777);
        voter.createGauge(gauge, "metadata");

        // alice delegates before creating the lock so the new token is auto-delegated
        vm.startPrank(alice);
        ivotesAdapter.delegate(alice);
        token.approve(address(escrow), amount);
        escrow.createLock(amount, MAX_TIME);

        vm.warp(block.timestamp + 2 weeks);
        IAddressGaugeVote.GaugeVote[] memory votes = new IAddressGaugeVote.GaugeVote[](1);
        votes[0] = IAddressGaugeVote.GaugeVote(100, gauge);
        voter.vote(votes);
        vm.stopPrank();

        uint256 beforeVotes = ivotesAdapter.getVotes(alice);
        assertEq(voter.votes(alice, gauge), beforeVotes);
        assertTrue(ivotesAdapter.tokenIsDelegated(1));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);

        // lockPermanent should update the delegate votes
        vm.prank(alice);
        escrow.lockPermanent(1);

        // Move to next checkpoint so adapter point is visible
        vm.warp(weekStartTs(block.timestamp));

        assertTrue(ivotesAdapter.tokenIsDelegated(1));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);
        // votes on voter should remain the same unless user re-votes
        assertEq(voter.votes(alice, gauge), beforeVotes);
        // getVotes should still be non-zero after permanent lock
        assertGt(ivotesAdapter.getVotes(alice), 0);
    }

    function test_unlockPermanent_updatesDelegationAndVotes() public {
        vm.warp(1);

        address alice = address(0x123);
        uint256 amount = getFlooredAmount(15e18);
        token.transfer(alice, amount);

        vm.warp(2 weeks + 1 hours + 1);
        address gauge = address(0x777);
        voter.createGauge(gauge, "metadata");

        vm.startPrank(alice);
        ivotesAdapter.delegate(alice);
        token.approve(address(escrow), amount);
        escrow.createLock(amount, MAX_TIME);
        escrow.lockPermanent(1);

        vm.warp(block.timestamp + 2 weeks);
        IAddressGaugeVote.GaugeVote[] memory votes = new IAddressGaugeVote.GaugeVote[](1);
        votes[0] = IAddressGaugeVote.GaugeVote(100, gauge);
        voter.vote(votes);
        vm.stopPrank();

        uint256 beforeVotes = ivotesAdapter.getVotes(alice);
        assertEq(voter.votes(alice, gauge), beforeVotes);
        assertTrue(ivotesAdapter.tokenIsDelegated(1));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);

        vm.warp(block.timestamp + 2 weeks);
        vm.prank(alice);
        escrow.unlockPermanent(1);

        // Move to next checkpoint so adapter point is visible
        vm.warp(weekStartTs(block.timestamp));

        assertTrue(ivotesAdapter.tokenIsDelegated(1));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);
        assertEq(voter.votes(alice, gauge), beforeVotes);
        // getVotes should still be non-zero after unlocking permanent
        assertGt(ivotesAdapter.getVotes(alice), 0);
    }

    function test_increaseAmount_updatesDelegationAndVotes() public {
        vm.warp(1);

        address alice = address(0x123);
        uint256 amount = getFlooredAmount(15e18);
        token.transfer(alice, amount);

        vm.warp(2 weeks + 1 hours + 1);
        address gauge = address(0x777);
        voter.createGauge(gauge, "metadata");

        vm.startPrank(alice);
        ivotesAdapter.delegate(alice);
        token.approve(address(escrow), amount);
        escrow.createLock(amount, MAX_TIME);

        vm.warp(block.timestamp + 2 weeks);
        IAddressGaugeVote.GaugeVote[] memory votes = new IAddressGaugeVote.GaugeVote[](1);
        votes[0] = IAddressGaugeVote.GaugeVote(100, gauge);
        voter.vote(votes);
        vm.stopPrank();

        uint256 beforeVotes = ivotesAdapter.getVotes(alice);
        assertEq(voter.votes(alice, gauge), beforeVotes);
        assertTrue(ivotesAdapter.tokenIsDelegated(1));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);

        uint256 increaseValue = getFlooredAmount(5e18);
        token.mint(alice, increaseValue);
        vm.startPrank(alice);
        token.approve(address(escrow), increaseValue);
        escrow.increaseAmount(1, increaseValue);
        vm.stopPrank();

        // Move to next checkpoint so adapter point is visible
        vm.warp(weekStartTs(block.timestamp));

        assertTrue(ivotesAdapter.tokenIsDelegated(1));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);
        assertEq(voter.votes(alice, gauge), beforeVotes);
        // getVotes should still be non-zero after increasing amount
        assertGt(ivotesAdapter.getVotes(alice), 0);
    }

    function test_increaseUnlockTime_updatesDelegationAndVotes() public {
        vm.warp(1);

        address alice = address(0x123);
        uint256 amount = getFlooredAmount(15e18);
        token.transfer(alice, amount);

        vm.warp(2 weeks + 1 hours + 1);
        address gauge = address(0x777);
        voter.createGauge(gauge, "metadata");

        vm.startPrank(alice);
        ivotesAdapter.delegate(alice);
        token.approve(address(escrow), amount);
        escrow.createLock(amount, MAX_TIME - 2 weeks);

        vm.warp(block.timestamp + 2 weeks);
        IAddressGaugeVote.GaugeVote[] memory votes = new IAddressGaugeVote.GaugeVote[](1);
        votes[0] = IAddressGaugeVote.GaugeVote(100, gauge);
        voter.vote(votes);
        vm.stopPrank();

        uint256 beforeVotes = ivotesAdapter.getVotes(alice);
        assertEq(voter.votes(alice, gauge), beforeVotes);
        assertTrue(ivotesAdapter.tokenIsDelegated(1));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);

        vm.warp(block.timestamp + 2 weeks);
        vm.prank(alice);
        escrow.increaseUnlockTime(1, MAX_TIME);

        // Move to next checkpoint so adapter point is visible
        vm.warp(weekStartTs(block.timestamp));

        assertTrue(ivotesAdapter.tokenIsDelegated(1));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);
        assertEq(voter.votes(alice, gauge), beforeVotes);
        // getVotes should still be non-zero after increasing unlock time
        assertGt(ivotesAdapter.getVotes(alice), 0);
    }
}
