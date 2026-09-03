pragma solidity ^0.8.17;

import {EscrowBase} from "../../../base/EscrowBase.sol";

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
} from "../../../versions.sol";

//import {console2} from "forge-std/Test.sol";

contract TestEscrowModifyLock is IEscrowCurveTokenStorage, IEscrowCurveGlobalStorage, EscrowBase {
    function setUp() public override {
        super.setUp();
        super.mintAndApproveEscrow();
    }

    /*//////////////////////////////////////////////////////////////
                              lockPermanent
    //////////////////////////////////////////////////////////////*/

    function test_lockPermanent_revertsIfPaused() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        escrow.pause();
        vm.expectRevert("Pausable: paused");
        escrow.lockPermanent(tokenId);
    }

    function test_lockPermanent_revertsIfNotOwnerOrApproved() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        vm.prank(address(999));
        vm.expectRevert(NotApprovedOrOwner.selector);
        escrow.lockPermanent(tokenId);
    }

    function test_lockPermanent_revertsIfNoLockFound() public {
        vm.expectRevert("ERC721: invalid token ID");
        escrow.lockPermanent(999);
    }

    function test_lockPermanent_revertsIfAlreadyPermanent() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        escrow.lockPermanent(tokenId);
        vm.expectRevert(PermanentLock.selector);
        escrow.lockPermanent(tokenId);
    }

    function test_lockPermanent_revertsIfLockExpired() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        vm.warp(block.timestamp + MAX_TIME + 1 weeks);
        vm.expectRevert(LockExpired.selector);
        escrow.lockPermanent(tokenId);
    }

    function test_lockPermanent_success() public {
        vm.warp(1 weeks + 1 hours);
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        uint256 nextCheckpoint = weekStartTs(block.timestamp);

        vm.expectEmit(true, true, true, true);
        emit LockPermanent(address(this), tokenId, Lock_1_Amount, nextCheckpoint);

        escrow.lockPermanent(tokenId);

        LockedBalance memory lock = escrow.locked(tokenId);
        assertEq(lock.amount, Lock_1_Amount);
        assertEq(lock.start, 0);
        assertTrue(escrow.isPermanent(tokenId));

        // Curve should have recorded a permanent lock: bias = amount, slope = 0
        uint256 latestIndex = curve.tokenPointLatestIndex(tokenId);
        TokenPoint memory tp = curve.tokenPointHistory(tokenId, latestIndex);
        assertEq(tp.bias, Lock_1_Amount * 1e18);
        assertEq(tp.slope, 0);
        assertEq(tp.writtenTs, nextCheckpoint);
    }

    function test_lockPermanent_canBeCalledByApproved() public {
        address approved = address(0x123);
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        nftLock.approve(approved, tokenId);

        vm.prank(approved);
        escrow.lockPermanent(tokenId);
        assertTrue(escrow.isPermanent(tokenId));
    }

    /*//////////////////////////////////////////////////////////////
                              unlockPermanent
    //////////////////////////////////////////////////////////////*/

    function test_unlockPermanent_revertsIfPaused() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        escrow.lockPermanent(tokenId);
        escrow.pause();
        vm.expectRevert("Pausable: paused");
        escrow.unlockPermanent(tokenId);
    }

    function test_unlockPermanent_revertsIfNotOwnerOrApproved() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        escrow.lockPermanent(tokenId);
        vm.prank(address(999));
        vm.expectRevert(NotApprovedOrOwner.selector);
        escrow.unlockPermanent(tokenId);
    }

    function test_unlockPermanent_revertsIfNotPermanent() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        vm.expectRevert(NotPermanentLock.selector);
        escrow.unlockPermanent(tokenId);
    }

    function test_unlockPermanent_success() public {
        vm.warp(1 weeks + 1 hours);
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        escrow.lockPermanent(tokenId);
        assertTrue(escrow.isPermanent(tokenId));

        vm.warp(block.timestamp + 2 weeks);
        uint256 nextCheckpoint = weekStartTs(block.timestamp);

        vm.expectEmit(true, true, true, true);
        emit UnlockPermanent(address(this), tokenId, Lock_1_Amount, nextCheckpoint);

        escrow.unlockPermanent(tokenId);

        LockedBalance memory lock = escrow.locked(tokenId);
        assertEq(lock.amount, Lock_1_Amount);
        assertEq(lock.start, nextCheckpoint);
        assertFalse(escrow.isPermanent(tokenId));

        // Curve should have recorded a non-permanent lock: bias = amount, slope < 0
        uint256 latestIndex = curve.tokenPointLatestIndex(tokenId);
        TokenPoint memory tp = curve.tokenPointHistory(tokenId, latestIndex);
        assertEq(tp.bias, Lock_1_Amount * 1e18);
        assertLt(tp.slope, 0);
        assertEq(tp.writtenTs, nextCheckpoint);
    }

    function test_unlockPermanent_canBeCalledByApproved() public {
        address approved = address(0x123);
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        escrow.lockPermanent(tokenId);
        nftLock.approve(approved, tokenId);

        vm.prank(approved);
        escrow.unlockPermanent(tokenId);
        assertFalse(escrow.isPermanent(tokenId));
    }

    /*//////////////////////////////////////////////////////////////
                              increaseAmount
    //////////////////////////////////////////////////////////////*/

    function test_increaseAmount_revertsIfPaused() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        escrow.pause();
        vm.expectRevert("Pausable: paused");
        escrow.increaseAmount(tokenId, 1e18);
    }

    function test_increaseAmount_revertsIfNotOwnerOrApproved() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        vm.prank(address(999));
        vm.expectRevert(NotApprovedOrOwner.selector);
        escrow.increaseAmount(tokenId, 1e18);
    }

    function test_increaseAmount_revertsIfNoLockFound() public {
        vm.expectRevert("ERC721: invalid token ID");
        escrow.increaseAmount(999, 1e18);
    }

    function test_increaseAmount_revertsIfLockExpired() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        vm.warp(block.timestamp + MAX_TIME + 1 weeks);
        vm.expectRevert(LockExpired.selector);
        escrow.increaseAmount(tokenId, 1e18);
    }

    function test_increaseAmount_revertsIfZeroAmount() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        vm.expectRevert(ZeroAmount.selector);
        escrow.increaseAmount(tokenId, 0);
    }

    function test_increaseAmount_success_nonPermanent() public {
        vm.warp(1 weeks + 1 hours);
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        uint256 checkpointTs = weekStartTs(block.timestamp);

        vm.warp(block.timestamp + 2 weeks);
        uint256 nextCheckpoint = weekStartTs(block.timestamp);
        uint256 increaseValue = getFlooredAmount(10e18);
        uint256 duration = checkpointTs + MAX_TIME - nextCheckpoint;

        vm.expectEmit(true, true, true, true);
        emit Deposit(address(this), tokenId, nextCheckpoint, checkpointTs, duration, increaseValue, Lock_1_Amount + increaseValue);

        escrow.increaseAmount(tokenId, increaseValue);

        LockedBalance memory lock = escrow.locked(tokenId);
        assertEq(lock.amount, Lock_1_Amount + increaseValue);
        assertEq(lock.start, checkpointTs);
        assertEq(escrow.totalLocked(), Lock_1_Amount + increaseValue);
        assertFalse(escrow.isPermanent(tokenId));
    }

    function test_increaseAmount_success_permanent() public {
        vm.warp(1 weeks + 1 hours);
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        escrow.lockPermanent(tokenId);

        vm.warp(block.timestamp + 2 weeks);
        uint256 increaseValue = getFlooredAmount(10e18);

        escrow.increaseAmount(tokenId, increaseValue);

        LockedBalance memory lock = escrow.locked(tokenId);
        assertEq(lock.amount, Lock_1_Amount + increaseValue);
        assertEq(lock.start, 0);
        assertTrue(escrow.isPermanent(tokenId));
        assertEq(escrow.totalLocked(), Lock_1_Amount + increaseValue);
    }

    function test_increaseAmount_canBeCalledByApproved() public {
        address approved = address(0x123);
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        nftLock.approve(approved, tokenId);
        uint256 increaseValue = getFlooredAmount(10e18);
        token.mint(approved, increaseValue);
        vm.startPrank(approved);
        token.approve(address(escrow), increaseValue);
        escrow.increaseAmount(tokenId, increaseValue);
        vm.stopPrank();
        assertEq(escrow.locked(tokenId).amount, Lock_1_Amount + increaseValue);
    }

    /*//////////////////////////////////////////////////////////////
                              increaseUnlockTime
    //////////////////////////////////////////////////////////////*/

    function test_increaseUnlockTime_revertsIfPaused() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        escrow.pause();
        vm.expectRevert("Pausable: paused");
        escrow.increaseUnlockTime(tokenId, MAX_TIME);
    }

    function test_increaseUnlockTime_revertsIfNotOwnerOrApproved() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        vm.prank(address(999));
        vm.expectRevert(NotApprovedOrOwner.selector);
        escrow.increaseUnlockTime(tokenId, MAX_TIME);
    }

    function test_increaseUnlockTime_revertsIfNoLockFound() public {
        vm.expectRevert("ERC721: invalid token ID");
        escrow.increaseUnlockTime(999, MAX_TIME);
    }

    function test_increaseUnlockTime_revertsIfPermanent() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        escrow.lockPermanent(tokenId);
        vm.expectRevert(PermanentLock.selector);
        escrow.increaseUnlockTime(tokenId, MAX_TIME);
    }

    function test_increaseUnlockTime_revertsIfLockExpired() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        vm.warp(block.timestamp + MAX_TIME + 1 weeks);
        vm.expectRevert(LockExpired.selector);
        escrow.increaseUnlockTime(tokenId, MAX_TIME);
    }

    function test_increaseUnlockTime_revertsIfDurationNotIncreased() public {
        // Fast forward to allow for virtual start
        vm.warp(block.timestamp + MAX_TIME);

        uint256 tokenId = escrow.createLock(Lock_1_Amount, 2 weeks);
        vm.expectRevert(DurationNotIncreased.selector);
        escrow.increaseUnlockTime(tokenId, 2 weeks);

        vm.warp(block.timestamp + 1 weeks);
        vm.expectRevert(DurationNotIncreased.selector);
        escrow.increaseUnlockTime(tokenId, 1 weeks);
    }

    function test_increaseUnlockTime_revertsIfDurationTooLong() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        vm.expectRevert(DurationTooLong.selector);
        escrow.increaseUnlockTime(tokenId, MAX_TIME + 1 weeks);
    }

    function test_increaseUnlockTime_revertsIfDurationTooShort() public {
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        vm.expectRevert(DurationTooShort.selector);
        escrow.increaseUnlockTime(tokenId, 1 days);
    }

    function test_increaseUnlockTime_revertsIfDurationNotMultiple() public {
        // Fast forward to allow for virtual start
        vm.warp(block.timestamp + MAX_TIME);

        uint256 tokenId = escrow.createLock(Lock_1_Amount, 2 weeks);
        vm.expectRevert(DurationNotMultipleOfInterval.selector);
        escrow.increaseUnlockTime(tokenId, MAX_TIME - 1 days);
    }

    function test_increaseUnlockTime_success() public {
        // Fast forward to allow for virtual start
        vm.warp(block.timestamp + MAX_TIME);

        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME - 2 weeks);
        uint256 oldCheckpoint = weekStartTs(block.timestamp);

        vm.warp(block.timestamp + 2 weeks);
        uint256 nextCheckpoint = weekStartTs(block.timestamp);
        uint256 newVirtualStart = escrow.getVirtualStart(nextCheckpoint, MAX_TIME);

        vm.expectEmit(true, true, true, true);
        emit Deposit(address(this), tokenId, nextCheckpoint, newVirtualStart, MAX_TIME, Lock_1_Amount, Lock_1_Amount);

        escrow.increaseUnlockTime(tokenId, MAX_TIME);

        LockedBalance memory lock = escrow.locked(tokenId);
        assertEq(lock.amount, Lock_1_Amount);
        assertEq(lock.start, newVirtualStart);
        assertFalse(escrow.isPermanent(tokenId));
    }

    function test_increaseUnlockTime_canBeCalledByApproved() public {
        address approved = address(0x123);

        // Fast forward to allow for virtual start
        vm.warp(block.timestamp + MAX_TIME);

        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME - 2 weeks);
        nftLock.approve(approved, tokenId);

        vm.warp(block.timestamp + 2 weeks);
        vm.prank(approved);
        escrow.increaseUnlockTime(tokenId, MAX_TIME);
        assertEq(escrow.locked(tokenId).start, weekStartTs(block.timestamp));
    }
}
