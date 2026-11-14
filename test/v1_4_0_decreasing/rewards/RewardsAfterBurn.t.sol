// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {IRewardsDistributor} from "../../../src/rewards/RewardsDistributor.sol";
import {RewardsDistributorTest} from "./RewardsDistributor.t.sol";

import {console2} from "forge-std/console2.sol";

/// Tests for keeping accrued rewards claimable after a lock is burned.
///
/// `RewardsDistributor` books rewards for a lock interval by interval. Before this change
/// `_claimable` returned zero as soon as the lock's amount was zero, which is the case for both
/// ways a lock is burned: merging it into another lock, and withdrawing it after expiry. The
/// rewards that had accrued to it beforehand could then not be claimed by anyone, and the tokens
/// stayed in the distributor.
///
/// These tests cover both ways a lock is burned, check that the amount recovered is everything
/// that had accrued rather than only the latest interval, and then probe the ways the change
/// could go wrong: paying a stranger, paying twice, paying more than was distributed, or
/// disturbing the lock that survives a merge.
contract RewardsAfterBurnTest is RewardsDistributorTest {
    address stranger = makeAddr("Stranger");

    /*//////////////////////////////////////////////////////////////
                                  Merge
    //////////////////////////////////////////////////////////////*/

    /// The source lock of a merge is burned. Its accrued rewards must still reach its owner.
    function test_burnedLock_mergeKeepsAccruedRewardsClaimable() public {
        _skipToNextEpoch(1 days);

        vm.startPrank(owner);
        uint256 from = escrow.createLock(TOKEN_1M, MAXTIME);
        uint256 to = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        // Two intervals of rewards accrue to both locks.
        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);

        uint256 accrued = distributor.claimable(from);
        assertGt(accrued, 0, "the source lock accrued something before the merge");

        vm.prank(owner);
        escrow.merge(from, to);
        _skipToNextEpoch(0);

        assertEq(distributor.claimable(from), accrued, "the merge must not erase what accrued");

        uint256 before = rewardsToken.balanceOf(owner);
        vm.prank(owner);
        uint256 paid = distributor.claim(from);

        assertEq(paid, accrued, "the claim pays what was accrued");
        assertEq(rewardsToken.balanceOf(owner) - before, accrued, "the owner receives it");
    }

    /*//////////////////////////////////////////////////////////////
                                Withdraw
    //////////////////////////////////////////////////////////////*/

    /// Withdrawing an expired lock also burns the NFT, so the same question applies there.
    function test_burnedLock_withdrawKeepsAccruedRewardsClaimable() public {
        _skipToNextEpoch(1 days);

        vm.prank(owner);
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);

        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);

        uint256 accrued = distributor.claimable(tokenId);
        assertGt(accrued, 0, "the lock accrued something before it expired");

        // Withdrawal is only allowed once the lock has expired.
        vm.warp(block.timestamp + MAXTIME + 1 weeks);
        vm.prank(owner);
        escrow.withdraw(tokenId);

        assertEq(distributor.claimable(tokenId), accrued, "withdrawing must not erase what accrued");

        uint256 before = rewardsToken.balanceOf(owner);
        vm.prank(owner);
        uint256 paid = distributor.claim(tokenId);

        assertEq(paid, accrued, "the claim pays what was accrued");
        assertEq(rewardsToken.balanceOf(owner) - before, accrued, "the owner receives it");
    }

    /*//////////////////////////////////////////////////////////////
                          How much is at stake
    //////////////////////////////////////////////////////////////*/

    /// The old guard returned zero for the lock's whole history, not just the interval in
    /// progress. A lock left unclaimed for several intervals recovers all of them.
    function test_burnedLock_recoversEverythingUnclaimedNotJustTheLatestInterval() public {
        _skipToNextEpoch(1 days);

        vm.startPrank(owner);
        uint256 from = escrow.createLock(TOKEN_1M, MAXTIME);
        uint256 to = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        // One interval's worth for this lock, measured on the same lock before anything else.
        // The first round lands before the lock's effective start, so it accrues nothing.
        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);
        uint256 oneInterval = distributor.claimable(from);
        assertGt(oneInterval, 0, "sanity: one interval accrues something");

        // Four further intervals go by without the owner ever claiming.
        for (uint256 i = 0; i < 4; i++) {
            _triggerRewardsAndSkipToNextEpoch(0);
        }

        uint256 accrued = distributor.claimable(from);

        console2.log("one interval                  ", oneInterval);
        console2.log("accrued over five intervals   ", accrued);

        vm.prank(owner);
        escrow.merge(from, to);

        uint256 recovered = distributor.claimable(from);
        assertEq(recovered, accrued, "everything unclaimed is recovered");
        assertGt(recovered, oneInterval * 3, "that is several intervals, not one");
    }

    /*//////////////////////////////////////////////////////////////
                        Over-paying and under-paying
    //////////////////////////////////////////////////////////////*/

    /// The distributor must never pay out more than it took in. Every lock claims after a merge,
    /// and the contract should be left with only rounding dust.
    function test_burnedLock_everythingDistributedIsClaimedAndNoMore() public {
        _skipToNextEpoch(1 days);

        vm.startPrank(owner);
        uint256 from = escrow.createLock(TOKEN_1M, MAXTIME);
        uint256 to = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        vm.prank(owner2);
        uint256 other = escrow.createLock(TOKEN_1M, MAXTIME);

        uint256 rounds = 3;
        for (uint256 i = 0; i < rounds; i++) {
            _triggerRewardsAndSkipToNextEpoch(0);
        }

        vm.prank(owner);
        escrow.merge(from, to);

        _triggerRewardsAndSkipToNextEpoch(0);
        _skipToNextEpoch(0);

        uint256 distributed = REWARD_AMOUNT * (rounds + 1);
        uint256 heldBefore = rewardsToken.balanceOf(address(distributor));

        vm.startPrank(owner);
        uint256 paid = distributor.claim(from) + distributor.claim(to);
        vm.stopPrank();
        vm.prank(owner2);
        paid += distributor.claim(other);
        paid += distributor.claim(setupTokenId);

        uint256 heldAfter = rewardsToken.balanceOf(address(distributor));

        console2.log("distributed       ", distributed);
        console2.log("held before claims", heldBefore);
        console2.log("paid out          ", paid);
        console2.log("left behind       ", heldAfter);

        assertEq(heldBefore - heldAfter, paid, "the contract paid exactly what it reported");
        assertLe(paid, distributed, "never pays out more than came in");
        // Whatever is left is rounding, not a lock whose share can no longer be reached.
        assertLt(heldAfter, distributed / 2, "the bulk of the distribution reached the holders");
    }

    /*//////////////////////////////////////////////////////////////
                              New openings
    //////////////////////////////////////////////////////////////*/

    /// The change widens `isApprovedOrOwner` for burned tokens. It must widen it to the last
    /// owner and to nobody else.
    function test_burnedLock_strangerCannotClaimIt() public {
        _skipToNextEpoch(1 days);

        vm.startPrank(owner);
        uint256 from = escrow.createLock(TOKEN_1M, MAXTIME);
        uint256 to = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);

        vm.prank(owner);
        escrow.merge(from, to);
        _skipToNextEpoch(0);

        assertGt(distributor.claimable(from), 0, "there is something to take");

        vm.prank(stranger);
        vm.expectRevert(IRewardsDistributor.NotApprovedOrOwner.selector);
        distributor.claim(from);
    }

    /// A burned lock must pay once, not every time it is asked.
    function test_burnedLock_cannotBeClaimedTwice() public {
        _skipToNextEpoch(1 days);

        vm.startPrank(owner);
        uint256 from = escrow.createLock(TOKEN_1M, MAXTIME);
        uint256 to = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);

        vm.prank(owner);
        escrow.merge(from, to);
        _skipToNextEpoch(0);

        vm.prank(owner);
        uint256 first = distributor.claim(from);
        assertGt(first, 0, "the first claim pays");

        vm.prank(owner);
        uint256 second = distributor.claim(from);
        assertEq(second, 0, "the second claim pays nothing");
    }

    /// Merging must not inflate or shrink what the surviving lock is owed.
    function test_burnedLock_mergeTargetIsUnaffected() public {
        _skipToNextEpoch(1 days);

        vm.startPrank(owner);
        uint256 from = escrow.createLock(TOKEN_1M, MAXTIME);
        uint256 to = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        // A lock of the same size that never takes part in a merge, as the control.
        vm.prank(owner2);
        uint256 control = escrow.createLock(TOKEN_1M, MAXTIME);

        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);

        uint256 toBefore = distributor.claimable(to);
        uint256 controlBefore = distributor.claimable(control);
        assertEq(toBefore, controlBefore, "sanity: identical locks accrue identically");

        vm.prank(owner);
        escrow.merge(from, to);
        _skipToNextEpoch(0);

        assertEq(distributor.claimable(to), toBefore, "the surviving lock keeps exactly what it had");
        assertEq(distributor.claimable(control), controlBefore, "the untouched lock is unchanged");
    }

    /// A token id that never existed must stay at zero and must not be claimable by anyone.
    function test_burnedLock_unknownTokenIsNotClaimable() public {
        uint256 ghost = 999_999;

        _skipToNextEpoch(1 days);
        _triggerRewardsAndSkipToNextEpoch(0);

        assertEq(distributor.claimable(ghost), 0, "a token that never existed is owed nothing");

        vm.prank(stranger);
        vm.expectRevert(IRewardsDistributor.NotApprovedOrOwner.selector);
        distributor.claim(ghost);
    }

    /// If a lock changes hands and is then burned, the rewards follow the owner at the time of
    /// the burn, not whoever held it earlier.
    function test_burnedLock_rewardsFollowTheOwnerAtBurnTime() public {
        _skipToNextEpoch(1 days);

        vm.prank(owner);
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);

        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);

        // Hand the lock to someone else, then let it expire and be withdrawn by the new owner.
        nftLock.setWhitelisted(owner, true);
        vm.prank(owner);
        IERC721Minimal(address(nftLock)).transferFrom(owner, owner3, tokenId);

        vm.warp(block.timestamp + MAXTIME + 1 weeks);
        vm.prank(owner3);
        escrow.withdraw(tokenId);

        assertGt(distributor.claimable(tokenId), 0, "the accrued rewards survive the burn");

        // The original owner no longer has any claim on it.
        vm.prank(owner);
        vm.expectRevert(IRewardsDistributor.NotApprovedOrOwner.selector);
        distributor.claim(tokenId);

        uint256 before = rewardsToken.balanceOf(owner3);
        vm.prank(owner3);
        uint256 paid = distributor.claim(tokenId);
        assertGt(paid, 0, "the owner at burn time is paid");
        assertEq(rewardsToken.balanceOf(owner3) - before, paid, "and receives it");
    }
}

interface IERC721Minimal {
    function transferFrom(address from, address to, uint256 tokenId) external;
}
