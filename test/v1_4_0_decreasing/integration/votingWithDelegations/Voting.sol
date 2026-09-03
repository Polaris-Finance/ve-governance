pragma solidity ^0.8.17;

import {IGaugeVote} from "../../versions.sol";

import {EscrowBase} from "../../base/EscrowBase.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";

contract TestVotingWithDelegation is EscrowBase {
    address tokenOwner = address(this);

    address gauge = address(0x777);

    address alice = address(1);
    address bob = address(2);

    uint256[] tokenIds = new uint256[](2);

    function setUp() public override {
        super.setUp();

        super.mintAndApproveEscrow();

        tokenIds[0] = escrow.createLock(Lock_1_Amount, MAX_TIME);
        tokenIds[1] = escrow.createLock(Lock_2_Amount, MAX_TIME);
        vm.warp(block.timestamp + 1 weeks);

        nftLock.enableTransfers();

        // create a gauge
        voter.createGauge(gauge, "metadata");
    }

    /*//////////////////////////////////////////////////////////////
                      IVotes Delegate
    //////////////////////////////////////////////////////////////*/

    function test_Vote_Self_Delegating_Tokens() public {
        uint256 start = previousCheckpointTs(block.timestamp);

        // make tokenOwner self delegatee
        ivotesAdapter.delegate(tokenOwner);
        vm.warp(block.timestamp + 1 weeks);

        assertEq(ivotesAdapter.numberOfDelegatedTokens(tokenOwner), 2);

        uint256 token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        uint256 token2Bias = bias(Lock_2_Amount, block.timestamp - start);
        uint256 total = token1Bias + token2Bias;

        assertEq(ivotesAdapter.getVotes(tokenOwner), total);
        assertEq(voter.votes(tokenOwner, gauge), 0);

        vm.warp(clock.epochVoteStartTs());

        token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        token2Bias = bias(Lock_2_Amount, block.timestamp - start);
        total = token1Bias + token2Bias;

        IGaugeVote.GaugeVote[] memory votes = new IGaugeVote.GaugeVote[](1);
        votes[0] = IGaugeVote.GaugeVote({gauge: gauge, weight: 1});

        vm.prank(tokenOwner);
        voter.vote(votes);

        assertEq(voter.votes(tokenOwner, gauge), total);
    }

    function test_Vote_Delegating_Tokens() public {
        uint256 start = previousCheckpointTs(block.timestamp);

        // make tokenOwner self delegatee
        ivotesAdapter.delegate(alice);
        vm.warp(block.timestamp + 1 weeks);

        assertEq(ivotesAdapter.numberOfDelegatedTokens(tokenOwner), 2);

        uint256 token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        uint256 token2Bias = bias(Lock_2_Amount, block.timestamp - start);
        uint256 total = token1Bias + token2Bias;

        assertEq(ivotesAdapter.getVotes(alice), total);

        vm.warp(clock.epochVoteStartTs());

        token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        token2Bias = bias(Lock_2_Amount, block.timestamp - start);
        total = token1Bias + token2Bias;

        IGaugeVote.GaugeVote[] memory votes = new IGaugeVote.GaugeVote[](1);
        votes[0] = IGaugeVote.GaugeVote({gauge: gauge, weight: 1});

        assertEq(voter.votes(alice, gauge), 0);

        vm.prank(alice);
        voter.vote(votes);

        assertEq(voter.votes(alice, gauge), total);
    }

    function test_Vote_And_Transfer_Delegated_Tokens() public {
        address tokenReceiver = address(123);

        uint256 start = previousCheckpointTs(block.timestamp);

        {
            // make Alice delegatee with tokenId = 1 and 2
            ivotesAdapter.setAutoDelegationDisabled(true);
            ivotesAdapter.delegate(alice);
            ivotesAdapter.delegate(tokenIds);
        }

        {
            // make Bob delegatee
            vm.startPrank(tokenReceiver);
            ivotesAdapter.setAutoDelegationDisabled(true);
            ivotesAdapter.delegate(bob);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + 1 weeks);

        assertEq(ivotesAdapter.numberOfDelegatedTokens(tokenOwner), 2);

        uint256 token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        uint256 token2Bias = bias(Lock_2_Amount, block.timestamp - start);
        uint256 total = token1Bias + token2Bias;

        assertEq(ivotesAdapter.getVotes(alice), total);
        assertEq(ivotesAdapter.getVotes(bob), 0);

        vm.warp(clock.epochVoteStartTs());

        token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        token2Bias = bias(Lock_2_Amount, block.timestamp - start);
        total = token1Bias + token2Bias;

        IGaugeVote.GaugeVote[] memory votes = new IGaugeVote.GaugeVote[](1);
        votes[0] = IGaugeVote.GaugeVote({gauge: gauge, weight: 1});

        assertEq(voter.votes(alice, gauge), 0);
        assertEq(voter.votes(bob, gauge), 0);

        // Alice votes
        vm.prank(alice);
        voter.vote(votes);

        assertEq(voter.votes(alice, gauge), total);
        assertEq(voter.votes(bob, gauge), 0);

        // Transfer lock to receiver
        nftLock.transferFrom(address(this), tokenReceiver, tokenIds[0]);

        uint256 nextCheckpointTsAfterTransfer = weekStartTs(block.timestamp);
        uint256 biasAfterTransfer = bias(Lock_2_Amount, nextCheckpointTsAfterTransfer - start);

        assertEq(voter.epochId(), 1, "Epoch should be 1");

        assertEq(ivotesAdapter.getVotes(alice), total);
        assertEq(ivotesAdapter.getVotes(bob), 0);

        // On transfer alice voting power was reduced to the amount of the next checkpoint
        assertEq(voter.votes(alice, gauge), biasAfterTransfer);
        // AddressGaugeVoter only updates voting power on decreasing
        assertEq(voter.votes(bob, gauge), 0);

        // Move forward 1 week
        vm.warp(block.timestamp + 1 weeks);
        assertEq(voter.epochId(), 1, "Epoch should be 1");

        token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        token2Bias = bias(Lock_2_Amount, block.timestamp - start);

        assertEq(ivotesAdapter.getVotes(alice), token2Bias);
        assertEq(ivotesAdapter.getVotes(bob), token1Bias);

        assertEq(voter.votes(alice, gauge), biasAfterTransfer);
        assertEq(voter.votes(bob, gauge), 0);

        // Move forward 1 week
        vm.warp(block.timestamp + 1 weeks);
        assertEq(voter.epochId(), 2, "Epoch should be 2");

        token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        token2Bias = bias(Lock_2_Amount, block.timestamp - start);

        assertEq(ivotesAdapter.getVotes(alice), token2Bias);
        assertEq(ivotesAdapter.getVotes(bob), token1Bias);

        assertEq(voter.votes(alice, gauge), biasAfterTransfer);
        assertEq(voter.votes(bob, gauge), 0);

        // Receiver returns the lock
        vm.prank(tokenReceiver);
        nftLock.transferFrom(tokenReceiver, address(this), tokenIds[0]);

        vm.warp(block.timestamp + 1 weeks);
        assertEq(voter.epochId(), 2, "Epoch should be 2");

        token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        token2Bias = bias(Lock_2_Amount, block.timestamp - start);
        total = token1Bias + token2Bias;

        assertEq(ivotesAdapter.getVotes(alice), total);
        assertEq(ivotesAdapter.getVotes(bob), 0);

        // AddressGaugeVoter only updates voting power on decreasing
        // So it does not go back up after receiving back the token
        assertEq(voter.votes(alice, gauge), biasAfterTransfer);
        assertEq(voter.votes(bob, gauge), 0);

        vm.warp(block.timestamp + 1 weeks);
        assertEq(voter.epochId(), 3, "Epoch should be 3");

        token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        token2Bias = bias(Lock_2_Amount, block.timestamp - start);
        total = token1Bias + token2Bias;

        assertEq(ivotesAdapter.getVotes(alice), total);
        assertEq(ivotesAdapter.getVotes(bob), 0);

        assertEq(voter.votes(alice, gauge), biasAfterTransfer);
        assertEq(voter.votes(bob, gauge), 0);
    }

    function test_Vote_And_Undelegate_Tokens() public {
        address tokenReceiver = address(123);

        uint256 start = previousCheckpointTs(block.timestamp);

        {
            // make Alice delegatee with tokenId = 1 and 2
            ivotesAdapter.setAutoDelegationDisabled(true);
            ivotesAdapter.delegate(alice);
            ivotesAdapter.delegate(tokenIds);
        }

        vm.warp(block.timestamp + 1 weeks);

        assertEq(ivotesAdapter.numberOfDelegatedTokens(tokenOwner), 2);

        uint256 token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        uint256 token2Bias = bias(Lock_2_Amount, block.timestamp - start);
        uint256 total = token1Bias + token2Bias;

        assertEq(ivotesAdapter.getVotes(alice), total);

        vm.warp(clock.epochVoteStartTs());

        token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        token2Bias = bias(Lock_2_Amount, block.timestamp - start);
        total = token1Bias + token2Bias;

        IGaugeVote.GaugeVote[] memory votes = new IGaugeVote.GaugeVote[](1);
        votes[0] = IGaugeVote.GaugeVote({gauge: gauge, weight: 1});

        assertEq(voter.votes(alice, gauge), 0);

        // Alice votes
        vm.prank(alice);
        voter.vote(votes);

        assertEq(voter.votes(alice, gauge), total);

        // Undelegate
        uint256[] memory undelegatedTokenIds = new uint256[](1);
        undelegatedTokenIds[0] = tokenIds[0];
        ivotesAdapter.undelegate(undelegatedTokenIds);

        uint256 nextCheckpointTsAfterUndelegation = weekStartTs(block.timestamp);
        uint256 biasAfterUndelegation = bias(Lock_2_Amount, nextCheckpointTsAfterUndelegation - start);
        // On undelegation alice voting power was reduced to the amount of the next checkpoint

        assertEq(voter.epochId(), 1, "Epoch should be 1");
        assertEq(ivotesAdapter.getVotes(alice), total);
        assertEq(voter.votes(alice, gauge), biasAfterUndelegation);

        // Move forward 1 week
        vm.warp(block.timestamp + 1 weeks);
        assertEq(voter.epochId(), 1, "Epoch should be 1");

        token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        token2Bias = bias(Lock_2_Amount, block.timestamp - start);

        assertEq(ivotesAdapter.getVotes(alice), token2Bias);
        assertEq(voter.votes(alice, gauge), biasAfterUndelegation);

        // Move forward 1 week
        vm.warp(block.timestamp + 1 weeks);
        assertEq(voter.epochId(), 2, "Epoch should be 2");

        token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        token2Bias = bias(Lock_2_Amount, block.timestamp - start);

        assertEq(ivotesAdapter.getVotes(alice), token2Bias);
        assertEq(voter.votes(alice, gauge), biasAfterUndelegation);

        // Delegate it again
        ivotesAdapter.delegate(undelegatedTokenIds);

        vm.warp(block.timestamp + 1 weeks);
        assertEq(voter.epochId(), 2, "Epoch should be 2");

        token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        token2Bias = bias(Lock_2_Amount, block.timestamp - start);
        total = token1Bias + token2Bias;

        assertEq(ivotesAdapter.getVotes(alice), total);
        // AddressGaugeVoter only updates voting power on decreasing
        // So it does not go back up after delegating again
        assertEq(voter.votes(alice, gauge), biasAfterUndelegation);

        vm.warp(block.timestamp + 1 weeks);
        assertEq(voter.epochId(), 3, "Epoch should be 3");

        token1Bias = bias(Lock_1_Amount, block.timestamp - start);
        token2Bias = bias(Lock_2_Amount, block.timestamp - start);
        total = token1Bias + token2Bias;

        assertEq(ivotesAdapter.getVotes(alice), total);
        assertEq(voter.votes(alice, gauge), biasAfterUndelegation);
    }
}
