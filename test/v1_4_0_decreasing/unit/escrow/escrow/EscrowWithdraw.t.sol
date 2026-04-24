pragma solidity ^0.8.17;

import {EscrowBase} from "../../../base/EscrowBase.sol";

import {console2 as console} from "forge-std/console2.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {Multisig, MultisigSetup} from "@aragon/multisig/src/MultisigSetup.sol";

import {ProxyLib} from "@libs/ProxyLib.sol";

import {
    Lock,
    Clock,
    VotingEscrow,
    SimpleGaugeVoter,
    SimpleGaugeVoterSetup,
    IEscrowCurveTokenStorage,
    IGaugeVote
} from "../../../versions.sol";

contract TestWithdraw is IEscrowCurveTokenStorage, IGaugeVote, EscrowBase {
    address gauge = address(1);

    GaugeVote[] votes;

    function setUp() public override {
        super.setUp();

        vm.warp(1);

        // make a voting gauge
        voter.createGauge(gauge, "metadata");
        votes.push(GaugeVote({gauge: gauge, weight: 1}));

        escrow.setMinDeposit(0);
    }

    function testRevertIfCreateLockAndWithdrawInSameTx() public {
        token.mint(address(this), 100e18);
        token.approve(address(escrow), 100e18);

        uint256 tokenId = escrow.createLock(100e18, MAX_TIME);
        nftLock.approve(address(escrow), tokenId);

        vm.expectRevert(CannotWithdrawInSameBlock.selector);
        escrow.withdraw(tokenId);

        vm.warp(block.timestamp + 1);
        escrow.withdraw(tokenId);
    }

    function testFuzz_enterWithdrawal(uint128 _dep, address _who) public {
        assert(false);
        /* TODO
        vm.assume(_who != address(0) && address(_who).code.length == 0);
        vm.assume(_dep > 0);
        uint queueAt;

        uint256 startTime = block.timestamp;

        // make a deposit
        token.mint(_who, _dep);
        uint tokenId;
        vm.startPrank(_who);
        {
            token.approve(address(escrow), _dep);
            tokenId = escrow.createLock(_dep, MAX_TIME);

            // voting active after cooldown
            vm.warp(block.timestamp + 2 weeks + 1 hours);
            queueAt = block.timestamp;

            ivotesAdapter.delegate(_who);

            // make a vote
            voter.vote(votes);
        }
        vm.stopPrank();

        // enter a withdrawal
        vm.startPrank(_who);
        {
            nftLock.approve(address(escrow), tokenId);
            // Check backwards compat
            escrow.resetVotesAndBeginWithdrawal(tokenId);
        }
        vm.stopPrank();

        // should now have the nft in the escrow
        assertEq(nftLock.balanceOf(_who), 0);
        assertEq(nftLock.balanceOf(address(escrow)), 1);

        assertEq(escrow.votingPower(tokenId), 0);

        // but we should have written a token point in the future
        TokenPoint memory up = curve.tokenPointHistory(tokenId, 2);
        assertEq(up.bias, 0);
        assertEq(up.writtenTs, block.timestamp);
        assertEq(up.checkpointTs, weekStartTs(startTime));
        assertEq(up.coefficients[0], 0);
        assertEq(up.coefficients[1], 0);

        // should have a ticket expiring in a few days
        assertEq(queue.canExit(tokenId), false);
        assertEq(queue.queue(tokenId).queuedAt, queueAt);

        // check the future to see the voting power expired
        vm.warp(3 weeks + 1);
        assertEq(escrow.votingPower(tokenId), 0);
        */
    }


    // HAL-13: locks are re-used causing reverts and duplications
    function testCanCreateLockAfterBurning() public {
        assert(false);
        /* TODO
        address USER1 = address(1);
        address USER2 = address(2);

        // mint
        token.mint(USER1, 100);
        token.mint(USER2, 100);

        vm.prank(USER1);
        token.approve(address(escrow), 100);

        vm.prank(USER2);
        token.approve(address(escrow), 100);

        vm.prank(USER1);
        uint256 tokenId = escrow.createLockFor(100, MAX_TIME, USER1); // Token ID 1

        vm.prank(USER2);
        uint256 tokenId2 = escrow.createLockFor(100, MAX_TIME, USER2); // Token ID 2

        // approve
        uint256 tokenId3;
        vm.startPrank(USER1);
        {
            nftLock.approve(address(escrow), tokenId);

            vm.warp(1 weeks + 1 days);

            escrow.withdraw(tokenId);

            TicketV2 memory ticket = queue.queue(tokenId);
            vm.warp(ticket.queuedAt + queue.cooldown());

            escrow.withdraw(tokenId);
            token.approve(address(escrow), 100);
            tokenId3 = escrow.createLockFor(100, MAX_TIME, USER1); // Token ID 2 - Duplicated - Reescrowrt
        }
        vm.stopPrank();

        // assert that the lock Id is incremented
        assertEq(tokenId3, 3);
        assertNotEq(tokenId2, tokenId3);
        assertEq(nftLock.totalSupply(), 2);
        assertEq(escrow.lastLockId(), 3);
        */
    }
}
