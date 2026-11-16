// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {EscrowBase} from "../../base/EscrowBase.sol";
import {IEscrowIVotesAdapterErrorsAndEvents} from "../../versions.sol";

/// Anyone can create a lock for anyone else, so an expired lock can arrive uninvited.
/// `delegate(address)` must not revert on it, must leave it undelegated, and the delegate
/// must not gain or lose anything from it, now or later.
contract TestSkipExpiredLocks is EscrowBase {
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address dave = address(0xDA7E);
    address carol = address(0xCA201);
    address attacker = address(0xBAD);

    uint256 constant AMOUNT = 100e18;

    // The smallest lockable amount: deposits are floored to a multiple of maxTime wei.
    uint256 DUST;

    uint256 aliceLock;
    uint256 daveLock;
    uint256 dustLock;

    function setUp() public override {
        super.setUp();
        DUST = MAX_TIME;

        // A short lock dates its virtual start maxTime before its end, so the clock has to
        // be past maxTime before one can be created at all.
        vm.warp(block.timestamp + MAX_TIME + 1 weeks);
    }

    /// Alice holds a live lock and an expired one-week lock she never asked for.
    /// Dave holds only the live lock, as the control.
    function _givenAnUninvitedExpiredLock() internal {
        mintAndApproveEscrow(alice, AMOUNT);
        mintAndApproveEscrow(dave, AMOUNT);
        mintAndApproveEscrow(attacker, DUST);

        vm.prank(attacker);
        dustLock = escrow.createLockFor(DUST, 1 weeks, alice);

        vm.prank(alice);
        aliceLock = escrow.createLock(AMOUNT, MAX_TIME);

        vm.prank(dave);
        daveLock = escrow.createLock(AMOUNT, MAX_TIME);

        vm.warp(block.timestamp + 4 weeks);
        assertTrue(escrow.isLockExpiredAtNextCheckpoint(dustLock), "the planted lock should be expired");
        assertFalse(escrow.isLockExpiredAtNextCheckpoint(aliceLock), "alice's own lock should be live");
    }

    function test_expiredLockDoesNotBlockDelegating() public {
        _givenAnUninvitedExpiredLock();

        vm.prank(alice);
        ivotesAdapter.delegate(bob);

        assertEq(ivotesAdapter.delegates(alice), bob);
        assertTrue(ivotesAdapter.tokenIsDelegated(aliceLock), "the live lock is delegated");
        assertFalse(ivotesAdapter.tokenIsDelegated(dustLock), "the expired lock is skipped");
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);
    }

    function test_expiredLockAddsNothingToTheDelegate() public {
        _givenAnUninvitedExpiredLock();

        vm.prank(alice);
        ivotesAdapter.delegate(bob);
        vm.prank(dave);
        ivotesAdapter.delegate(carol);

        uint256 effective = clock.nextCheckpointTs();
        vm.warp(effective);

        assertGt(ivotesAdapter.getVotes(carol), 0, "the control delegate should hold the live lock");
        assertEq(ivotesAdapter.getVotes(bob), ivotesAdapter.getVotes(carol));
        assertEq(ivotesAdapter.getVotes(bob), escrow.votingPowerAt(aliceLock, effective));
    }

    /// A skipped lock must leave no slope change behind. If it did, the two delegates
    /// would drift apart somewhere along the live lock's decay.
    function test_expiredLockDoesNotDisturbTheDelegateLater() public {
        _givenAnUninvitedExpiredLock();

        vm.prank(alice);
        ivotesAdapter.delegate(bob);
        vm.prank(dave);
        ivotesAdapter.delegate(carol);

        for (uint256 i = 0; i < 22; i++) {
            vm.warp(block.timestamp + 10 weeks);
            assertEq(ivotesAdapter.getVotes(bob), ivotesAdapter.getVotes(carol), "votes diverged");
        }

        assertEq(ivotesAdapter.getVotes(bob), 0, "both locks have ended by now");
    }

    function test_expiredLockCanStillBeWithdrawnAfterDelegating() public {
        _givenAnUninvitedExpiredLock();

        vm.prank(alice);
        ivotesAdapter.delegate(bob);

        uint256 votesBefore = ivotesAdapter.getVotes(bob);
        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        escrow.withdraw(dustLock);

        assertEq(ivotesAdapter.getVotes(bob), votesBefore, "withdrawing it changes nothing");
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1, "the count was never raised for it");
        assertEq(token.balanceOf(alice) - balanceBefore, DUST, "alice keeps the planted tokens");
    }

    /// The expiry check is only meant to move off `delegate(address)`, not to disappear.
    function test_delegateByTokenIdStillRejectsAnExpiredLock() public {
        _givenAnUninvitedExpiredLock();

        uint256[] memory ids = new uint256[](1);
        ids[0] = dustLock;

        vm.startPrank(alice);
        ivotesAdapter.setAutoDelegationDisabled(true);
        ivotesAdapter.delegate(bob);

        vm.expectRevert(
            abi.encodeWithSelector(IEscrowIVotesAdapterErrorsAndEvents.LockExpired.selector, dustLock)
        );
        ivotesAdapter.delegate(ids);
        vm.stopPrank();
    }

    /// A holder of nothing but expired locks can still pick a delegate. The call used to
    /// revert, and under option 1 it would delegate the dead locks instead.
    function test_everyLockExpiredStillSetsTheDelegatee() public {
        mintAndApproveEscrow(alice, DUST * 2);

        vm.startPrank(alice);
        uint256 first = escrow.createLock(DUST, 1 weeks);
        uint256 second = escrow.createLock(DUST, 2 weeks);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 weeks);
        assertTrue(escrow.isLockExpiredAtNextCheckpoint(first));
        assertTrue(escrow.isLockExpiredAtNextCheckpoint(second));

        vm.prank(alice);
        ivotesAdapter.delegate(bob);

        assertEq(ivotesAdapter.delegates(alice), bob, "the delegatee is recorded");
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 0, "nothing was delegated");
        assertFalse(ivotesAdapter.tokenIsDelegated(first));
        assertFalse(ivotesAdapter.tokenIsDelegated(second));
        assertEq(ivotesAdapter.getVotes(bob), 0);
    }

    /// The delegatee recorded in that call still has to work for later locks, otherwise
    /// skipping would have left the account in a dead state.
    function test_delegateeSetWithOnlyExpiredLocksStillAppliesToANewLock() public {
        test_everyLockExpiredStillSetsTheDelegatee();

        mintAndApproveEscrow(alice, AMOUNT);
        vm.prank(alice);
        uint256 fresh = escrow.createLock(AMOUNT, MAX_TIME);

        assertTrue(ivotesAdapter.tokenIsDelegated(fresh), "a new lock follows the recorded delegatee");
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);

        uint256 effective = clock.nextCheckpointTs();
        vm.warp(effective);
        assertEq(ivotesAdapter.getVotes(bob), escrow.votingPowerAt(fresh, effective));
    }

    /// A lock that was delegated while live, and has since expired, is undelegated by the
    /// next `delegate(address)` and not delegated again.
    function test_aDelegatedLockThatExpiresIsUndelegatedAndNotRedelegated() public {
        mintAndApproveEscrow(alice, AMOUNT + DUST);

        vm.startPrank(alice);
        aliceLock = escrow.createLock(AMOUNT, MAX_TIME);
        uint256 shortLock = escrow.createLock(DUST, 4 weeks);
        ivotesAdapter.delegate(bob);
        vm.stopPrank();

        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 2, "both were live at first");

        vm.warp(block.timestamp + 6 weeks);
        assertTrue(escrow.isLockExpiredAtNextCheckpoint(shortLock));

        vm.prank(alice);
        ivotesAdapter.delegate(carol);

        assertFalse(ivotesAdapter.tokenIsDelegated(shortLock), "dropped out of the delegated set");
        assertTrue(ivotesAdapter.tokenIsDelegated(aliceLock));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);

        uint256 effective = clock.nextCheckpointTs();
        vm.warp(effective);
        assertEq(ivotesAdapter.getVotes(bob), 0, "the old delegate holds nothing");
        assertEq(ivotesAdapter.getVotes(carol), escrow.votingPowerAt(aliceLock, effective));
    }

    /// `delegate(address)` is not the only way a lock becomes delegated. A lock
    /// transferred to an account with a delegatee is delegated by the transfer hook, which
    /// has no expiry check, so an expired lock can sit in the delegated set after all.
    /// It adds nothing, and the next `delegate(address)` clears it.
    function test_anExpiredLockArrivingByTransferIsStillDelegated() public {
        nftLock.enableTransfers();

        mintAndApproveEscrow(alice, AMOUNT);
        mintAndApproveEscrow(attacker, DUST);

        vm.prank(alice);
        aliceLock = escrow.createLock(AMOUNT, MAX_TIME);
        vm.prank(alice);
        ivotesAdapter.delegate(bob);

        vm.prank(attacker);
        dustLock = escrow.createLock(DUST, 1 weeks);

        vm.warp(block.timestamp + 4 weeks);
        assertTrue(escrow.isLockExpiredAtNextCheckpoint(dustLock));

        uint256 votesBefore = ivotesAdapter.getVotes(bob);

        vm.prank(attacker);
        nftLock.transferFrom(attacker, alice, dustLock);

        assertTrue(ivotesAdapter.tokenIsDelegated(dustLock), "the transfer hook delegates it anyway");
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 2);
        assertEq(ivotesAdapter.getVotes(bob), votesBefore, "but it adds no voting power");

        // The next full re-delegation drops it again.
        vm.prank(alice);
        ivotesAdapter.delegate(carol);

        assertFalse(ivotesAdapter.tokenIsDelegated(dustLock));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);
    }

    /// A lock whose end falls exactly on the next checkpoint already counts as expired,
    /// while still holding voting power right now. It is skipped, and the delegate gets
    /// only the live lock.
    function test_lockEndingExactlyAtTheNextCheckpointIsSkipped() public {
        mintAndApproveEscrow(alice, AMOUNT + DUST);

        vm.startPrank(alice);
        aliceLock = escrow.createLock(AMOUNT, MAX_TIME);
        uint256 ending = escrow.createLock(DUST, 1 weeks);
        vm.stopPrank();

        vm.warp(escrow.locked(ending).start + MAX_TIME - 1);
        assertTrue(escrow.isLockExpiredAtNextCheckpoint(ending), "expired at the next checkpoint");
        assertFalse(escrow.isLockCurrentlyExpired(ending), "but not expired yet");
        assertGt(escrow.votingPower(ending), 0, "and still carrying voting power now");

        vm.prank(alice);
        ivotesAdapter.delegate(bob);

        assertFalse(ivotesAdapter.tokenIsDelegated(ending));

        uint256 effective = clock.nextCheckpointTs();
        vm.warp(effective);

        assertEq(ivotesAdapter.getVotes(bob), escrow.votingPowerAt(aliceLock, effective));
    }

    /// Whatever its size or duration, an expired lock is skipped and contributes nothing.
    /// The amount is not bounded to dust: an expired lock can be as large as its owner
    /// made it.
    function testFuzz_anExpiredLockIsSkipped(uint256 _amount, uint256 _weeks) public {
        uint256 amount = bound(_amount, DUST, 1_000_000e18);
        uint256 duration = bound(_weeks, 1, 100) * 1 weeks;

        mintAndApproveEscrow(attacker, amount);
        vm.prank(attacker);
        uint256 junk = escrow.createLockFor(amount, duration, alice);

        mintAndApproveEscrow(alice, AMOUNT);
        vm.prank(alice);
        aliceLock = escrow.createLock(AMOUNT, MAX_TIME);

        vm.warp(block.timestamp + duration + 2 weeks);
        assertTrue(escrow.isLockExpiredAtNextCheckpoint(junk));

        vm.prank(alice);
        ivotesAdapter.delegate(bob);

        assertFalse(ivotesAdapter.tokenIsDelegated(junk));
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 1);

        uint256 effective = clock.nextCheckpointTs();
        vm.warp(effective);

        assertEq(ivotesAdapter.getVotes(bob), escrow.votingPowerAt(aliceLock, effective));
    }
}
