// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {IRewardsDistributor} from "../../../src/rewards/RewardsDistributor.sol";
import {RewardsClaimAggregator} from "../../../src/rewards/RewardsClaimAggregator.sol";
import {RewardsDistributorTest} from "./RewardsDistributor.t.sol";

/// `isApprovedOrOwner` used to revert for a burned token, because it looked up an owner that no
/// longer existed. It now answers the question instead: true for the address that owned the token
/// when it was burned, false for everyone else.
///
/// That function gates more than claiming rewards. These tests check every other caller of it in
/// the decreasing stack, and the edges of the new answer.
contract BurnedLockSurfaceTest is RewardsDistributorTest {
    address stranger = makeAddr("Stranger");
    address operator = makeAddr("Operator");

    RewardsClaimAggregator aggregator;

    /// The base test's `setUp` is not virtual, so the aggregator is built on first use.
    function _aggregator() internal returns (RewardsClaimAggregator) {
        if (address(aggregator) == address(0)) {
            aggregator = new RewardsClaimAggregator(address(escrow));
        }
        return aggregator;
    }

    /// Creates a lock for `owner`, lets two intervals of rewards accrue, then burns it by
    /// withdrawing after expiry. Returns the token id and what it accrued.
    function _lockAndBurn() internal returns (uint256 tokenId, uint256 accrued) {
        _skipToNextEpoch(1 days);

        vm.prank(owner);
        tokenId = escrow.createLock(TOKEN_1M, MAXTIME);

        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);

        accrued = distributor.claimable(tokenId);
        require(accrued > 0, "fixture: the lock should have accrued something");

        vm.warp(block.timestamp + MAXTIME + 1 weeks);
        vm.prank(owner);
        escrow.withdraw(tokenId);
    }

    function _distributors() internal view returns (IRewardsDistributor[] memory list) {
        list = new IRewardsDistributor[](1);
        list[0] = IRewardsDistributor(address(distributor));
    }

    /*//////////////////////////////////////////////////////////////
                        RewardsClaimAggregator
    //////////////////////////////////////////////////////////////*/

    /// The aggregator is the second caller of `isApprovedOrOwner`, and it is deployed. It works by
    /// being approved on the NFT and then calling the distributor itself, so the distributor sees
    /// the aggregator as the caller.
    ///
    /// Burning deletes the approvals, and the fix only remembers the owner. So the aggregator
    /// cannot finish a claim for a burned lock even though the owner authorised it beforehand.
    /// The owner has to call the distributor directly. Nothing is lost, but the two claim paths
    /// no longer behave the same, and a frontend that routes everything through the aggregator
    /// would show unreachable rewards.
    function test_aggregator_cannotClaimForABurnedLockEvenWhenItWasApproved() public {
        RewardsClaimAggregator agg = _aggregator();
        _skipToNextEpoch(1 days);

        vm.prank(owner);
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);

        // The owner approves the aggregator while the lock is alive, as it is meant to be used.
        vm.prank(owner);
        nftLock.setApprovalForAll(address(agg), true);

        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);

        // Control: the aggregator can claim for the live lock.
        uint256 beforeLive = rewardsToken.balanceOf(owner);
        vm.prank(owner);
        agg.claim(_distributors(), tokenId, 50);
        assertGt(rewardsToken.balanceOf(owner), beforeLive, "the aggregator works while the lock lives");

        // More rewards accrue, then the lock is burned by withdrawing after expiry.
        _triggerRewardsAndSkipToNextEpoch(0);
        vm.warp(block.timestamp + MAXTIME + 1 weeks);
        vm.prank(owner);
        escrow.withdraw(tokenId);

        uint256 accrued = distributor.claimable(tokenId);
        assertGt(accrued, 0, "there are rewards left to claim after the burn");

        // The aggregator's own gate passes, because the caller is the last owner.
        assertTrue(escrow.isApprovedOrOwner(owner, tokenId), "the last owner passes the gate");
        // But the distributor sees the aggregator as the caller, and the aggregator is not the
        // last owner, so the inner check rejects it.
        assertFalse(
            escrow.isApprovedOrOwner(address(agg), tokenId), "the aggregator does not pass the gate"
        );

        vm.prank(owner);
        vm.expectRevert(IRewardsDistributor.NotApprovedOrOwner.selector);
        agg.claim(_distributors(), tokenId, 50);

        // The direct path still works, so the rewards are reachable.
        uint256 beforeDirect = rewardsToken.balanceOf(owner);
        vm.prank(owner);
        uint256 paid = distributor.claim(tokenId);
        assertEq(paid, accrued, "the direct claim pays what accrued");
        assertEq(rewardsToken.balanceOf(owner) - beforeDirect, accrued, "and the owner receives it");
    }

    /*//////////////////////////////////////////////////////////////
                              Approvals
    //////////////////////////////////////////////////////////////*/

    /// For a live lock an approved operator passes the gate. After the burn only the owner does.
    /// The post-burn gate is narrower than the live one, which is the intended design: the person
    /// who owned the lock is paid, and nobody they had authorised keeps a claim on it.
    function test_burnedLock_anOperatorApprovedBeforeTheBurnCannotClaim() public {
        _skipToNextEpoch(1 days);

        vm.prank(owner);
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);

        vm.prank(owner);
        nftLock.approve(operator, tokenId);
        assertTrue(escrow.isApprovedOrOwner(operator, tokenId), "control: approved while alive");

        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);

        vm.warp(block.timestamp + MAXTIME + 1 weeks);
        vm.prank(owner);
        escrow.withdraw(tokenId);

        assertGt(distributor.claimable(tokenId), 0, "there is something to take");
        assertFalse(escrow.isApprovedOrOwner(operator, tokenId), "the approval does not survive the burn");

        vm.prank(operator);
        vm.expectRevert(IRewardsDistributor.NotApprovedOrOwner.selector);
        distributor.claim(tokenId);
    }

    /// The recorded owner is whoever held the token when it was burned, not whoever created it.
    function test_burnedLock_theRecordedOwnerIsTheOneAtBurnTime() public {
        _skipToNextEpoch(1 days);

        vm.prank(owner);
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);

        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);

        // Hand the lock to a second holder. Transfers are gated by the whitelist.
        nftLock.setWhitelisted(owner2, true);
        vm.prank(owner);
        nftLock.transferFrom(owner, owner2, tokenId);
        assertEq(nftLock.ownerOf(tokenId), owner2, "the second holder owns it");

        vm.warp(block.timestamp + MAXTIME + 1 weeks);
        vm.prank(owner2);
        escrow.withdraw(tokenId);

        assertTrue(escrow.isApprovedOrOwner(owner2, tokenId), "the holder at burn time can claim");
        assertFalse(escrow.isApprovedOrOwner(owner, tokenId), "the original creator cannot");

        vm.prank(owner);
        vm.expectRevert(IRewardsDistributor.NotApprovedOrOwner.selector);
        distributor.claim(tokenId);

        uint256 before = rewardsToken.balanceOf(owner2);
        vm.prank(owner2);
        uint256 paid = distributor.claim(tokenId);
        assertGt(paid, 0, "the holder at burn time is paid");
        assertEq(rewardsToken.balanceOf(owner2) - before, paid, "and receives it");
    }

    /*//////////////////////////////////////////////////////////////
                          Edges of the answer
    //////////////////////////////////////////////////////////////*/

    /// A token id that was never minted used to make `isApprovedOrOwner` revert inside `ownerOf`.
    /// It now returns false. Callers treat false as a rejection, so the outcome is the same, but
    /// the revert reason a caller sees changes from the ERC-721 error to `NotApprovedOrOwner`.
    function test_neverMintedToken_answersFalseInsteadOfReverting() public {
        uint256 ghost = 999_999;
        assertFalse(escrow.isApprovedOrOwner(owner, ghost), "nobody owns a token that never existed");
        assertEq(distributor.claimable(ghost), 0, "and it has nothing to claim");

        vm.prank(owner);
        vm.expectRevert(IRewardsDistributor.NotApprovedOrOwner.selector);
        distributor.claim(ghost);
    }

    /// The zero address must never pass, including for a token id with no recorded owner. Without
    /// the explicit zero check the comparison would be zero == zero and return true.
    function test_zeroAddressIsNeverApproved() public {
        (uint256 tokenId,) = _lockAndBurn();

        assertFalse(escrow.isApprovedOrOwner(address(0), tokenId), "not for a burned token");
        assertFalse(escrow.isApprovedOrOwner(address(0), 999_999), "not for a token that never existed");
    }

    /// The recorded owner is keyed by token id, so a reused id would hand an old owner a claim on
    /// a new lock. Ids come from a counter that only increases, so they are never reused.
    function test_tokenIdsAreNeverReused() public {
        (uint256 burned,) = _lockAndBurn();

        uint256 lastId = escrow.lastLockId();
        assertEq(burned, lastId, "the burned lock holds the latest id");

        vm.prank(owner2);
        uint256 fresh = escrow.createLock(TOKEN_1M, MAXTIME);

        assertEq(fresh, lastId + 1, "the next lock takes a new id");
        assertFalse(escrow.isApprovedOrOwner(owner, fresh), "the old owner has no claim on it");
        assertTrue(escrow.isApprovedOrOwner(owner2, fresh), "its own owner does");
    }

    /// A stranger must not reach a burned lock's rewards, whichever path they try.
    function test_strangerCannotReachABurnedLockThroughEitherPath() public {
        RewardsClaimAggregator agg = _aggregator();
        (uint256 tokenId,) = _lockAndBurn();

        assertGt(distributor.claimable(tokenId), 0, "there is something to take");

        vm.prank(stranger);
        vm.expectRevert(IRewardsDistributor.NotApprovedOrOwner.selector);
        distributor.claim(tokenId);

        vm.prank(stranger);
        vm.expectRevert(RewardsClaimAggregator.NotApprovedOrOwner.selector);
        agg.claim(_distributors(), tokenId, 50);

        // Nor by naming themselves as the receiver on the direct path.
        vm.prank(stranger);
        vm.expectRevert(IRewardsDistributor.NotApprovedOrOwner.selector);
        distributor.claim(tokenId, stranger, 50);
    }

    /*//////////////////////////////////////////////////////////////
                    Can a burned lock be acted on again
    //////////////////////////////////////////////////////////////*/

    /// `merge` and `withdraw` also call `isApprovedOrOwner`, so widening it for burned tokens
    /// raises the question of whether a burned lock can be operated on a second time. It cannot:
    /// both read `ownerOf` first, which still reverts for a token that no longer exists.
    function test_burnedLock_cannotBeWithdrawnAgain() public {
        (uint256 tokenId,) = _lockAndBurn();

        vm.prank(owner);
        vm.expectRevert();
        escrow.withdraw(tokenId);
    }

    function test_burnedLock_cannotBeMergedAgain() public {
        (uint256 burned,) = _lockAndBurn();

        vm.prank(owner);
        uint256 live = escrow.createLock(TOKEN_1M, MAXTIME);

        // Burned as the source.
        vm.prank(owner);
        vm.expectRevert();
        escrow.merge(burned, live);

        // And as the target.
        vm.prank(owner);
        vm.expectRevert();
        escrow.merge(live, burned);
    }

    /// Claiming part of the accrual before the burn must not let the rest be claimed twice.
    function test_claimingBeforeTheBurnDoesNotAllowDoubleClaimingAfterIt() public {
        _skipToNextEpoch(1 days);

        vm.prank(owner);
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);

        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);

        vm.prank(owner);
        uint256 beforeBurn = distributor.claim(tokenId);
        assertGt(beforeBurn, 0, "the first claim happens while the lock lives");

        _triggerRewardsAndSkipToNextEpoch(0);

        vm.warp(block.timestamp + MAXTIME + 1 weeks);
        vm.prank(owner);
        escrow.withdraw(tokenId);

        uint256 remaining = distributor.claimable(tokenId);

        vm.prank(owner);
        uint256 afterBurn = distributor.claim(tokenId);
        assertEq(afterBurn, remaining, "the second claim pays only what was left");

        vm.prank(owner);
        assertEq(distributor.claim(tokenId), 0, "and a third pays nothing");
    }
}
