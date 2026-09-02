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

    function testRevertIfNonExpired() public {
        token.mint(address(this), 200e18);
        token.approve(address(escrow), 100e18);

        uint256 tokenId = escrow.createLock(100e18, MAX_TIME);
        nftLock.approve(address(escrow), tokenId);
        uint256 lockStart = weekStartTs(block.timestamp);
        uint256 lockEnd = lockStart + MAX_TIME;

        // Cannot withdraw even if it's not active until start of next checkpoint
        assertLt(block.timestamp, lockStart, "Not started yet");
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId);

        // Not expired
        vm.warp(lockStart);
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId);

        // Not expired
        vm.warp(lockStart + 1);
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId);

        // Not expired
        vm.warp(lockEnd - 1);
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId);

        // Finally expired
        vm.warp(lockEnd);
        escrow.withdraw(tokenId);
    }

    function testFuzz_withdraw(uint128 _dep, address _who) public {
        vm.assume(_who != address(0) && address(_who).code.length == 0);
        _dep = uint128(getFlooredAmount(uint256(_dep)));
        vm.assume(_dep > 1e6);

        // make a deposit
        token.mint(_who, _dep);
        uint tokenId;
        vm.startPrank(_who);
        {
            token.approve(address(escrow), _dep);
            tokenId = escrow.createLock(_dep, MAX_TIME);

            vm.warp(block.timestamp + 2 weeks + 1 hours);

            ivotesAdapter.delegate(_who);
            vm.warp(block.timestamp + 2 weeks);

            // make a vote
            voter.vote(votes);
        }
        vm.stopPrank();

        // withdraw
        vm.startPrank(_who);
        {
            assertGt(escrow.votingPower(tokenId), 0);
            // let the lock expire
            vm.warp(block.timestamp + MAX_TIME);
            // check the voting power expired
            assertEq(escrow.votingPower(tokenId), 0);
            // withdraw
            nftLock.approve(address(escrow), tokenId);
            escrow.withdraw(tokenId);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + 1 weeks);

        // the nft should have been burnt
        assertEq(nftLock.balanceOf(_who), 0);
        assertEq(nftLock.balanceOf(address(escrow)), 0);

        assertEq(escrow.votingPower(tokenId), 0);

        // we should not have written a token point in the future
        assertEq(curve.tokenPointLatestIndex(tokenId), 1);
    }


    // HAL-13: locks are re-used causing reverts and duplications
    function testCanCreateLockAfterBurning() public {
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

            vm.warp(MAX_TIME + 1 days);

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
    }

    /// Withdrawing a lock that was delegated must clear the
    /// account's delegation counter. Without that, the
    /// `numberOfDelegatedTokens` counter stays stuck above zero forever, which
    /// permanently blocks `setDelegateAddress()` for that account (it requires
    /// the counter to be 0).
    function test_withdraw_clearsDelegationCounterByOwner() public {
        address who = address(0xBEEF);
        uint256 dep = getFlooredAmount(100e18);

        token.mint(who, dep);

        vm.startPrank(who);
        token.approve(address(escrow), dep);
        uint256 tokenId = escrow.createLock(dep, MAX_TIME);

        // Activate at the next checkpoint, then self-delegate.
        vm.warp(block.timestamp + 2 weeks + 1 hours);
        ivotesAdapter.delegate(who);
        vm.stopPrank();

        // Precondition: the lock is now delegated.
        assertEq(ivotesAdapter.numberOfDelegatedTokens(who), 1, "precondition: token delegated");

        // Let the lock fully expire so voting power is 0 and withdrawal is allowed.
        vm.warp(block.timestamp + MAX_TIME + 2 weeks);
        assertEq(escrow.votingPower(tokenId), 0, "voting power must be 0 at expiry");

        // Withdraw (burns the NFT and returns the tokens).
        vm.startPrank(who);
        nftLock.approve(address(escrow), tokenId);
        escrow.withdraw(tokenId);
        vm.stopPrank();

        // The lock no longer exists, so the delegation counter must be 0.
        // Fails on unfixed code (stays at 1): the burn skips delegation cleanup.
        assertEq(
            ivotesAdapter.numberOfDelegatedTokens(who),
            0,
            "withdraw must clear the delegation counter"
        );
    }

    function test_withdraw_clearsDelegationCounterByApprovedAccount() public {
        address who = address(0xBEEF);
        address app = address(0xC0FFEE);
        uint256 dep = getFlooredAmount(100e18);

        token.mint(who, dep);

        vm.startPrank(who);
        token.approve(address(escrow), dep);
        uint256 tokenId = escrow.createLock(dep, MAX_TIME);
        // Approve to a 3rd party
        nftLock.approve(app, tokenId);

        // Activate at the next checkpoint, then self-delegate.
        vm.warp(block.timestamp + 2 weeks + 1 hours);
        ivotesAdapter.delegate(who);
        vm.stopPrank();

        // Precondition: the lock is now delegated.
        assertEq(ivotesAdapter.numberOfDelegatedTokens(who), 1, "precondition: token delegated");

        // Let the lock fully expire so voting power is 0 and withdrawal is allowed.
        vm.warp(block.timestamp + MAX_TIME + 2 weeks);
        assertEq(escrow.votingPower(tokenId), 0, "voting power must be 0 at expiry");

        // Withdraw by 3rd party (burns the NFT and returns the tokens).
        vm.startPrank(app);
        escrow.withdraw(tokenId);
        vm.stopPrank();

        // The lock no longer exists, so the delegation counter must be 0.
        // Fails on unfixed code (stays at 1): the burn skips delegation cleanup.
        assertEq(
            ivotesAdapter.numberOfDelegatedTokens(who),
            0,
            "withdraw must clear the delegation counter"
        );
    }
}
