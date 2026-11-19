pragma solidity ^0.8.17;

import {EscrowBase, IAddressGaugeVote} from "../../base/EscrowBase.sol";

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

contract TestCreateLock_DelegationAndVoter is
    IEscrowCurveTokenStorage,
    IEscrowCurveGlobalStorage,
    EscrowBase
{
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();

        super.mintAndApproveEscrow();
    }

    function test_CreateLock_CorrectlyUpdatesDelegationAndVotes() public {
        vm.warp(1);

        uint256 lock1Amount = getFlooredAmount(15e18);
        uint256 lock2Amount = getFlooredAmount(35e18);

        token.transfer(alice, lock1Amount + lock2Amount);

        address gauge = address(0x777);

        // activate cp & warp to an active window
        vm.warp(2 weeks + 1 hours + 1);
        voter.createGauge(gauge, "metadata");

        // alice creates lock, delegates to herself and votes.
        vm.startPrank(alice);
        ivotesAdapter.delegate(alice);

        token.approve(address(escrow), lock1Amount);
        uint256 checkpointTs = weekStartTs(block.timestamp);
        escrow.createLock(lock1Amount, MAX_TIME);
        vm.warp(block.timestamp + 2 weeks);

        IAddressGaugeVote.GaugeVote[] memory votes = new IAddressGaugeVote.GaugeVote[](1);
        votes[0] = IAddressGaugeVote.GaugeVote(100, gauge);
        voter.vote(votes);
        vm.stopPrank();

        uint256 alice1Bias = bias(lock1Amount, block.timestamp - checkpointTs);
        assertEq(ivotesAdapter.getVotes(alice), alice1Bias);
        assertEq(voter.votes(alice, gauge), alice1Bias);
        assertTrue(ivotesAdapter.tokenIsDelegated(1));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);

        // alice creates second lock which should
        // automatically increase her delegation power.
        vm.startPrank(alice);
        token.approve(address(escrow), lock2Amount);
        uint256 checkpointTs2 = weekStartTs(block.timestamp);
        createLockAndMoveToNextWeek(lock2Amount, MAX_TIME);
        vm.stopPrank();
        alice1Bias = bias(lock1Amount, block.timestamp - checkpointTs);
        uint256 alice2Bias = bias(lock2Amount, block.timestamp - checkpointTs2);

        assertEq(ivotesAdapter.getVotes(alice), alice1Bias + alice2Bias);
        assertEq(voter.votes(alice, gauge), bias(lock1Amount, block.timestamp - checkpointTs - 1 weeks));
        assertTrue(ivotesAdapter.tokenIsDelegated(2));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 2);
    }

    function test_CreateLock_AndDelegatesImmediatelyWithIds() public {
        vm.warp(1);

        vm.prank(bob);
        ivotesAdapter.delegate(bob);

        uint256 lock1Amount = getFlooredAmount(15e18);

        token.transfer(alice, lock1Amount);

        address gauge = address(0x777);

        // activate cp & warp to an active window
        vm.warp(2 weeks + 1 hours + 1);
        voter.createGauge(gauge, "metadata");

        uint256 checkpointTs = weekStartTs(block.timestamp);

        // alice creates lock and delegates
        vm.startPrank(alice);

        token.approve(address(escrow), lock1Amount);
        uint256 tokenId = escrow.createLock(lock1Amount, MAX_TIME);
        nftLock.approve(bob, tokenId);

        ivotesAdapter.setDelegateAddress(bob);
        uint256[] memory delegatedIds = new uint256[](1);
        delegatedIds[0] = tokenId;
        ivotesAdapter.delegate(delegatedIds);

        vm.stopPrank();

        vm.warp(block.timestamp + 2 weeks);

        // Bob now votes with power delegated from alice token
        vm.startPrank(bob);
        IAddressGaugeVote.GaugeVote[] memory votes = new IAddressGaugeVote.GaugeVote[](1);
        votes[0] = IAddressGaugeVote.GaugeVote(100, gauge);
        voter.vote(votes);
        vm.stopPrank();

        uint256 bias = bias(lock1Amount, block.timestamp - checkpointTs);
        assertEq(ivotesAdapter.getVotes(alice), 0);
        assertEq(voter.votes(alice, gauge), 0);
        assertEq(ivotesAdapter.getVotes(bob), bias);
        assertEq(voter.votes(bob, gauge), bias);
        assertTrue(ivotesAdapter.tokenIsDelegated(tokenId));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);
    }

    function test_CreateLock_AndDelegatesImmediatelyToAddress() public {
        vm.warp(1);

        vm.prank(bob);
        ivotesAdapter.delegate(bob);

        uint256 lock1Amount = getFlooredAmount(15e18);

        token.transfer(alice, lock1Amount);

        address gauge = address(0x777);

        // activate cp & warp to an active window
        vm.warp(2 weeks + 1 hours + 1);
        voter.createGauge(gauge, "metadata");

        uint256 checkpointTs = weekStartTs(block.timestamp);

        // alice creates lock and delegates
        vm.startPrank(alice);

        token.approve(address(escrow), lock1Amount);
        uint256 tokenId = escrow.createLock(lock1Amount, MAX_TIME);
        nftLock.approve(bob, tokenId);

        ivotesAdapter.delegate(bob);

        vm.stopPrank();

        vm.warp(block.timestamp + 2 weeks);

        // Bob now votes with power delegated from alice token
        vm.startPrank(bob);
        IAddressGaugeVote.GaugeVote[] memory votes = new IAddressGaugeVote.GaugeVote[](1);
        votes[0] = IAddressGaugeVote.GaugeVote(100, gauge);
        voter.vote(votes);
        vm.stopPrank();

        uint256 bias = bias(lock1Amount, block.timestamp - checkpointTs);
        assertEq(ivotesAdapter.getVotes(alice), 0);
        assertEq(voter.votes(alice, gauge), 0);
        assertEq(ivotesAdapter.getVotes(bob), bias);
        assertEq(voter.votes(bob, gauge), bias);
        assertTrue(ivotesAdapter.tokenIsDelegated(tokenId));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);
    }
}
