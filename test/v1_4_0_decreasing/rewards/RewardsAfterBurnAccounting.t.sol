// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {RewardsDistributorTest} from "./RewardsDistributor.t.sol";
import {RewardsDistributor, IRewardsDistributor} from "../../../src/rewards/RewardsDistributor.sol";
import {RewardsClaimAggregator} from "../../../src/rewards/RewardsClaimAggregator.sol";
import {console2} from "forge-std/console2.sol";

/// More tests for keeping accrued rewards claimable after a lock is burned.
/// They look for ways the change could pay too much, pay the wrong person, or let a burned
/// lock id be used for anything other than claiming.
contract RewardsAfterBurnAccountingTest is RewardsDistributorTest {
    uint256 constant STEPS = 80;

    uint256[] internal ids;
    mapping(uint256 => address) internal holder; // current owner, or the owner when it was burned
    mapping(uint256 => bool) internal burned;
    address[] internal actors;

    uint256 internal distributed;
    uint256 internal paid;

    uint256 internal nMerge;
    uint256 internal nMergeExpired;
    uint256 internal nMergePermanent;
    uint256 internal nWithdraw;
    uint256 internal nSplit;
    uint256 internal nTransfer;
    uint256 internal nClaimBurned;

    address stranger = makeAddr("Stranger");
    address operator = makeAddr("Operator");
    address tokenOperator = makeAddr("Token operator");

    // The parent setUp is not virtual, so the extra preparation runs at the start of each test.
    modifier prepared() {
        _prepare();
        _;
    }

    function _prepare() internal {
        // Transfers are enabled, so locks can change owner.
        nftLock.enableTransfers();
        escrow.enableSplit();

        mintAndApproveEscrow(owner, 1e27);
        mintAndApproveEscrow(owner2, 1e27);
        mintAndApproveEscrow(owner3, 1e27);
        actors.push(owner);
        actors.push(owner2);
        actors.push(owner3);

        // Far enough from zero that a one week lock has a valid virtual start.
        vm.warp(300 weeks + 1 days);
        distributor = new RewardsDistributor(address(escrow), address(rewardsToken), rewardsSender);

        // The lock made by the parent setUp has expired by now. Keep it in the population.
        _track(setupTokenId, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                    Random sequences: where does the money go
    //////////////////////////////////////////////////////////////*/

    function testFuzz_everyRewardIsClaimableOnceAndNoMore(uint256 _seed) public prepared {
        _run(_seed);
        _settleAndCheck();
    }

    /// Not a check. Prints how often the random sequences reach the interesting operations.
    function test_coverageOfTheRandomSequences() public prepared {
        for (uint256 seed = 0; seed < 5; seed++) {
            _run(seed);
        }
        console2.log("locks created        ", ids.length);
        console2.log("merges               ", nMerge);
        console2.log("  of expired locks   ", nMergeExpired);
        console2.log("  of permanent locks ", nMergePermanent);
        console2.log("withdrawals          ", nWithdraw);
        console2.log("splits               ", nSplit);
        console2.log("transfers            ", nTransfer);
        console2.log("claims on burned ids ", nClaimBurned);
        _settleAndCheck();
    }

    function _run(uint256 _seed) internal {
        for (uint256 i = 0; i < STEPS; i++) {
            _step(uint256(keccak256(abi.encode(_seed, i))));
        }
    }

    function _step(uint256 r) internal {
        uint256 op = r % 100;
        r = r / 100;

        if (op < 20) _create(r);
        else if (op < 36) {
            if (!_mergeAny(r)) _create(r);
        } else if (op < 44) {
            if (!_withdrawAny(r)) _warp(r, true);
        } else if (op < 50) _increaseAmountAny(r);
        else if (op < 55) _lockPermanentAny(r);
        else if (op < 58) _unlockPermanentAny(r);
        else if (op < 62) _increaseUnlockTimeAny(r);
        else if (op < 67) _transferAny(r);
        else if (op < 71) _splitAny(r);
        else if (op < 76) _claimAny(r);
        else if (op < 88) _reward(r);
        else _warp(r, op >= 97);
    }

    function _track(uint256 _id, address _holder) internal {
        ids.push(_id);
        holder[_id] = _holder;
    }

    function _duration(uint256 r) internal view returns (uint256) {
        uint256 pick = r % 4;
        if (pick == 0) return 1 weeks;
        if (pick == 1) return 2 weeks;
        if (pick == 2) return 4 weeks;
        return MAX_TIME;
    }

    function _create(uint256 r) internal {
        address actor = actors[r % 3];
        uint256 amount = bound(r >> 8, 1e18, 1e24);
        vm.prank(actor);
        uint256 id = escrow.createLock(amount, _duration(r >> 100));
        _track(id, actor);
    }

    function _mergeAny(uint256 r) internal returns (bool) {
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 from = ids[(r + i) % n];
            if (burned[from]) continue;
            for (uint256 j = 0; j < n; j++) {
                uint256 to = ids[(r / 7 + j) % n];
                if (to == from || burned[to] || holder[from] != holder[to]) continue;
                if (escrow.locked(from).start != escrow.locked(to).start) continue;

                if (escrow.isPermanent(from)) nMergePermanent++;
                else if (escrow.isLockCurrentlyExpired(from)) nMergeExpired++;

                vm.prank(holder[from]);
                escrow.merge(from, to);
                burned[from] = true;
                nMerge++;
                return true;
            }
        }
        return false;
    }

    function _withdrawAny(uint256 r) internal returns (bool) {
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = ids[(r + i) % n];
            if (burned[id] || !escrow.isLockCurrentlyExpired(id)) continue;

            vm.prank(holder[id]);
            escrow.withdraw(id);
            burned[id] = true;
            nWithdraw++;
            return true;
        }
        return false;
    }

    function _increaseAmountAny(uint256 r) internal {
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = ids[(r + i) % n];
            if (burned[id] || escrow.isLockExpiredAtNextCheckpoint(id)) continue;

            vm.prank(holder[id]);
            escrow.increaseAmount(id, bound(r >> 16, 1e18, 1e23));
            return;
        }
    }

    function _lockPermanentAny(uint256 r) internal {
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = ids[(r + i) % n];
            if (burned[id] || escrow.isPermanent(id) || escrow.isLockExpiredAtNextCheckpoint(id)) continue;

            vm.prank(holder[id]);
            escrow.lockPermanent(id);
            return;
        }
    }

    function _unlockPermanentAny(uint256 r) internal {
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = ids[(r + i) % n];
            if (burned[id] || !escrow.isPermanent(id)) continue;

            vm.prank(holder[id]);
            escrow.unlockPermanent(id);
            return;
        }
    }

    function _increaseUnlockTimeAny(uint256 r) internal {
        uint256 n = ids.length;
        uint256 duration = _duration(r >> 100);
        uint256 next = clock.nextCheckpointTs();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = ids[(r + i) % n];
            if (burned[id] || escrow.isPermanent(id) || escrow.isLockExpiredAtNextCheckpoint(id)) continue;
            if (next + duration <= uint256(escrow.locked(id).start) + MAX_TIME) continue;

            vm.prank(holder[id]);
            escrow.increaseUnlockTime(id, duration);
            return;
        }
    }

    function _transferAny(uint256 r) internal {
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = ids[(r + i) % n];
            if (burned[id]) continue;

            address to = actors[(r >> 16) % 3];
            if (to == holder[id]) to = actors[((r >> 16) + 1) % 3];

            vm.prank(holder[id]);
            nftLock.transferFrom(holder[id], to, id);
            holder[id] = to;
            nTransfer++;
            return;
        }
    }

    function _splitAny(uint256 r) internal {
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = ids[(r + i) % n];
            if (burned[id]) continue;

            uint256 half = uint256(escrow.locked(id).amount) / 2;
            vm.prank(holder[id]);
            uint256 newId = escrow.split(id, half);
            _track(newId, holder[id]);
            nSplit++;
            return;
        }
    }

    function _claimAny(uint256 r) internal {
        uint256 id = ids[r % ids.length];
        if (burned[id]) nClaimBurned++;
        vm.prank(holder[id]);
        paid += distributor.claim(id);
    }

    function _reward(uint256 r) internal {
        uint256 amount = bound(r, 1, 100e18);
        _triggerRewards(amount);
        distributed += amount;
    }

    function _warp(uint256 r, bool _far) internal {
        skip(_far ? bound(r, 10 weeks, 30 weeks) : bound(r, 1 hours, 3 weeks));
        vm.roll(block.number + 1);
    }

    function _settleAndCheck() internal {
        // Let the last interval finish so everything distributed can be claimed.
        skip(2 weeks);
        vm.roll(block.number + 1);

        uint256 interval = distributor.CHECKPOINT_INTERVAL();
        uint256 current = block.timestamp / interval * interval;
        uint256 n = ids.length;

        uint256 expected;
        uint256 lostToEmptyIntervals;
        uint256 intervals;

        for (uint256 t = distributor.START_INTERVAL_TIME(); t < current; t += interval) {
            uint256 supply = escrow.totalVotingPowerAt(t);
            uint256 tokens = distributor.tokensPerInterval(t);
            uint256 sum;
            for (uint256 i = 0; i < n; i++) {
                uint256 power = escrow.votingPowerAt(ids[i], t);
                sum += power;
                if (supply > 0) expected += power * tokens / supply;
            }
            // Live and burned locks together must never have more power than the recorded total.
            // If they did, the distributor would owe more than it holds.
            assertEq(sum, supply, "locks do not add up to the total supply");
            if (supply == 0) lostToEmptyIntervals += tokens;
            intervals++;
        }

        for (uint256 i = 0; i < n; i++) {
            uint256 id = ids[i];
            for (uint256 k = 0; k < 30; k++) {
                uint256 cursor = distributor.timeCursorOf(id);
                if (cursor != 0 && cursor > distributor.lastTokenIntervalTime()) break;
                vm.prank(holder[id]);
                paid += distributor.claim(id);
            }
        }

        assertEq(paid, expected, "claims are not each lock's share of each interval");
        assertLe(paid, distributed, "paid out more than came in");
        assertEq(rewardsToken.balanceOf(address(distributor)), distributed - paid, "balance does not match");

        // What is left is rounding, plus rewards for intervals when nobody had any voting power.
        assertLe(distributed - paid, lostToEmptyIntervals + intervals * n + 1000, "rewards are left behind");

        uint256 lockedInLiveLocks;
        for (uint256 i = 0; i < n; i++) {
            vm.prank(holder[ids[i]]);
            assertEq(distributor.claim(ids[i]), 0, "a lock paid twice");

            if (burned[ids[i]]) {
                assertEq(escrow.locked(ids[i]).amount, 0, "a burned lock still holds tokens");
                assertEq(nftLock.lastOwnerOf(ids[i]), holder[ids[i]], "last owner is not the owner at burn");
            } else {
                lockedInLiveLocks += escrow.locked(ids[i]).amount;
                assertEq(nftLock.ownerOf(ids[i]), holder[ids[i]]);
                assertEq(nftLock.lastOwnerOf(ids[i]), address(0), "a live lock has a last owner");
            }
        }
        // The locked tokens themselves: nothing created or lost by merging and withdrawing.
        assertEq(lockedInLiveLocks, escrow.totalLocked(), "live locks do not add up to totalLocked");
        assertEq(token.balanceOf(address(escrow)), escrow.totalLocked(), "escrow balance");
    }

    /*//////////////////////////////////////////////////////////////
                         Merging against a control
    //////////////////////////////////////////////////////////////*/

    /// Two locks merged in the middle of an interval must together earn what two identical
    /// locks that never merge earn.
    function test_mergeMidInterval_earnsWhatTwoUnmergedLocksEarn() public prepared {
        _mergeAgainstControl(false);
    }

    function test_mergeOfPermanentLocks_earnsWhatTwoUnmergedLocksEarn() public prepared {
        _mergeAgainstControl(true);
    }

    function _mergeAgainstControl(bool _permanent) internal {
        _skipToNextEpoch(1 days);

        vm.startPrank(owner);
        uint256 from = escrow.createLock(TOKEN_1M, MAX_TIME);
        uint256 to = escrow.createLock(TOKEN_1M, MAX_TIME);
        if (_permanent) {
            escrow.lockPermanent(from);
            escrow.lockPermanent(to);
        }
        vm.stopPrank();

        vm.startPrank(owner2);
        uint256 control1 = escrow.createLock(TOKEN_1M, MAX_TIME);
        uint256 control2 = escrow.createLock(TOKEN_1M, MAX_TIME);
        if (_permanent) {
            escrow.lockPermanent(control1);
            escrow.lockPermanent(control2);
        }
        vm.stopPrank();

        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);

        // Rewards arrive in the interval of the merge, both before and after it.
        skip(2 days);
        _triggerRewards(REWARD_AMOUNT);
        vm.prank(owner);
        escrow.merge(from, to);
        skip(1 days);
        _triggerRewards(REWARD_AMOUNT);
        _skipToNextEpoch(0);

        uint256 powerOfMerged = escrow.votingPower(to);
        assertEq(escrow.votingPower(from), 0, "the burned lock has no power once the merge is effective");
        assertEq(powerOfMerged, escrow.votingPower(control1) + escrow.votingPower(control2), "merged power");

        for (uint256 i = 0; i < 3; i++) {
            _triggerRewardsAndSkipToNextEpoch(0);
        }
        _skipToNextEpoch(0);

        vm.startPrank(owner);
        uint256 merged = distributor.claim(from) + distributor.claim(to);
        vm.stopPrank();
        vm.startPrank(owner2);
        uint256 control = distributor.claim(control1) + distributor.claim(control2);
        vm.stopPrank();

        console2.log("merged pair  ", merged);
        console2.log("control pair ", control);
        assertGt(merged, 0);
        // One wei of rounding per interval at most.
        assertApproxEqAbs(merged, control, 10, "merging changed what the pair earns");
    }

    /// Two expired locks with the same start can be merged. This shows what that does to the
    /// accounting: total voting power and total locked are unchanged, and the survivor withdraws the sum.
    function test_mergeOfExpiredLocks_keepsRewardsAndPrincipal() public prepared {
        _skipToNextEpoch(1 days);

        vm.startPrank(owner);
        uint256 from = escrow.createLock(TOKEN_1M, 2 weeks);
        uint256 to = escrow.createLock(TOKEN_1M, 2 weeks);
        vm.stopPrank();
        uint256 amount = escrow.locked(from).amount;

        for (uint256 i = 0; i < 4; i++) {
            _triggerRewardsAndSkipToNextEpoch(0);
        }

        assertTrue(escrow.isLockCurrentlyExpired(from));
        assertTrue(escrow.isLockCurrentlyExpired(to));
        uint256 accruedFrom = distributor.claimable(from);
        uint256 accruedTo = distributor.claimable(to);
        assertGt(accruedFrom, 0);
        uint256 supplyBefore = escrow.totalVotingPower();
        uint256 totalLockedBefore = escrow.totalLocked();

        vm.prank(owner);
        escrow.merge(from, to);
        _skipToNextEpoch(0);

        assertEq(escrow.totalVotingPower(), supplyBefore, "total voting power");
        assertEq(escrow.votingPower(to), 0, "the merged lock is still expired");
        assertEq(escrow.totalLocked(), totalLockedBefore, "total locked");
        assertEq(escrow.locked(to).amount, 2 * amount, "the survivor holds both amounts");
        assertTrue(escrow.isLockCurrentlyExpired(to));
        assertEq(distributor.claimable(from), accruedFrom, "rewards of the burned lock");
        assertEq(distributor.claimable(to), accruedTo, "rewards of the survivor");

        uint256 before = token.balanceOf(owner);
        vm.startPrank(owner);
        escrow.withdraw(to);
        assertEq(token.balanceOf(owner) - before, 2 * amount, "withdraws the sum");
        assertEq(distributor.claim(from), accruedFrom);
        assertEq(distributor.claim(to), accruedTo);
        vm.stopPrank();
    }

    /// A lock that is merged away before it ever had voting power earns nothing and breaks nothing.
    function test_lockMergedAwayBeforeItStarts_earnsNothing() public prepared {
        _skipToNextEpoch(1 days);

        vm.startPrank(owner);
        uint256 from = escrow.createLock(TOKEN_1M, MAX_TIME);
        uint256 to = escrow.createLock(TOKEN_1M, MAX_TIME);
        escrow.merge(from, to);
        vm.stopPrank();

        for (uint256 i = 0; i < 3; i++) {
            _triggerRewardsAndSkipToNextEpoch(0);
        }

        assertEq(distributor.claimable(from), 0);
        vm.prank(owner);
        assertEq(distributor.claim(from), 0);
        assertGt(distributor.claimable(to), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            Who can claim
    //////////////////////////////////////////////////////////////*/

    /// Rewards follow the NFT. Whoever owns the lock when it is burned claims, the earlier owner cannot.
    function test_transferThenBurn_paysTheOwnerAtBurn() public prepared {
        _skipToNextEpoch(1 days);

        vm.prank(owner);
        uint256 from = escrow.createLock(TOKEN_1M, MAX_TIME);
        vm.prank(owner2);
        uint256 to = escrow.createLock(TOKEN_1M, MAX_TIME);

        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);
        uint256 accrued = distributor.claimable(from);
        assertGt(accrued, 0);

        vm.prank(owner);
        nftLock.transferFrom(owner, owner2, from);
        vm.prank(owner2);
        escrow.merge(from, to);
        _skipToNextEpoch(0);

        assertEq(nftLock.lastOwnerOf(from), owner2);
        assertFalse(escrow.isApprovedOrOwner(owner, from), "the earlier owner");
        assertTrue(escrow.isApprovedOrOwner(owner2, from), "the owner at burn");

        vm.prank(owner);
        vm.expectRevert(IRewardsDistributor.NotApprovedOrOwner.selector);
        distributor.claim(from);

        vm.prank(owner2);
        assertEq(distributor.claim(from), accrued);
    }

    /// Approvals do not survive the burn. Only the last owner can claim, and only directly.
    function test_approvalsDoNotSurviveTheBurn_andTheAggregatorCannotClaimABurnedLock() public prepared {
        RewardsClaimAggregator aggregator = new RewardsClaimAggregator(address(escrow));
        IRewardsDistributor[] memory distributors = new IRewardsDistributor[](1);
        distributors[0] = IRewardsDistributor(address(distributor));

        _skipToNextEpoch(1 days);

        vm.startPrank(owner);
        uint256 from = escrow.createLock(TOKEN_1M, MAX_TIME);
        uint256 to = escrow.createLock(TOKEN_1M, MAX_TIME);
        nftLock.setApprovalForAll(operator, true);
        nftLock.setApprovalForAll(address(aggregator), true);
        nftLock.approve(tokenOperator, from);
        vm.stopPrank();

        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);

        assertTrue(escrow.isApprovedOrOwner(operator, from), "live: operator for all");
        assertTrue(escrow.isApprovedOrOwner(tokenOperator, from), "live: operator for the token");

        vm.prank(owner);
        escrow.merge(from, to);
        _skipToNextEpoch(0);

        assertFalse(escrow.isApprovedOrOwner(operator, from), "burned: operator for all");
        assertFalse(escrow.isApprovedOrOwner(tokenOperator, from), "burned: operator for the token");
        assertFalse(escrow.isApprovedOrOwner(address(aggregator), from), "burned: aggregator");
        assertFalse(escrow.isApprovedOrOwner(stranger, from), "burned: stranger");
        assertFalse(escrow.isApprovedOrOwner(address(0), from), "burned: zero address");
        assertTrue(escrow.isApprovedOrOwner(owner, from), "burned: last owner");

        vm.prank(operator);
        vm.expectRevert(IRewardsDistributor.NotApprovedOrOwner.selector);
        distributor.claim(from);

        // The aggregator works for the live lock...
        uint256 before = rewardsToken.balanceOf(owner);
        uint256 claimableTo = distributor.claimable(to);
        vm.prank(owner);
        aggregator.claim(distributors, to, 52);
        assertEq(rewardsToken.balanceOf(owner) - before, claimableTo);

        // ...but not for the burned one, even when called by its last owner.
        vm.prank(owner);
        vm.expectRevert(IRewardsDistributor.NotApprovedOrOwner.selector);
        aggregator.claim(distributors, from, 52);

        // A batch that contains one burned lock fails as a whole.
        uint256[] memory both = new uint256[](2);
        both[0] = to;
        both[1] = from;
        vm.prank(owner);
        vm.expectRevert(IRewardsDistributor.NotApprovedOrOwner.selector);
        aggregator.claimMany(distributors, both, 52);

        // Directly at the distributor it works, alone or in a batch with live locks.
        uint256 claimableFrom = distributor.claimable(from);
        assertGt(claimableFrom, 0);
        before = rewardsToken.balanceOf(owner);
        vm.prank(owner);
        distributor.claimMany(both);
        assertEq(rewardsToken.balanceOf(owner) - before, claimableFrom);
    }

    /// `withdraw` pays whoever calls it. The reward claim must still belong to the owner.
    function test_operatorWithdraws_ownerKeepsTheRewardClaim() public prepared {
        _skipToNextEpoch(1 days);

        vm.startPrank(owner);
        uint256 tokenId = escrow.createLock(TOKEN_1M, 2 weeks);
        nftLock.setApprovalForAll(operator, true);
        vm.stopPrank();

        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);
        _triggerRewardsAndSkipToNextEpoch(0);
        skip(1 weeks);

        uint256 accrued = distributor.claimable(tokenId);
        assertGt(accrued, 0, "the lock earned something while it had power");
        assertTrue(escrow.isLockCurrentlyExpired(tokenId));

        vm.prank(operator);
        escrow.withdraw(tokenId);

        assertEq(nftLock.lastOwnerOf(tokenId), owner, "last owner is the owner, not the caller");

        vm.prank(operator);
        vm.expectRevert(IRewardsDistributor.NotApprovedOrOwner.selector);
        distributor.claim(tokenId);

        vm.prank(owner);
        assertEq(distributor.claim(tokenId), accrued);
    }

    /*//////////////////////////////////////////////////////////////
               A burned lock id is good for claiming only
    //////////////////////////////////////////////////////////////*/

    function test_burnedLockIdCannotBeUsedForAnythingElse() public prepared {
        _skipToNextEpoch(1 days);

        vm.startPrank(owner);
        uint256 from = escrow.createLock(TOKEN_1M, MAX_TIME);
        uint256 to = escrow.createLock(TOKEN_1M, MAX_TIME);
        uint256 other = escrow.createLock(TOKEN_1M, MAX_TIME);
        vm.stopPrank();

        _triggerRewardsAndSkipToNextEpoch(0);

        vm.prank(owner);
        escrow.merge(from, to);
        _skipToNextEpoch(0);

        assertTrue(escrow.isApprovedOrOwner(owner, from), "sanity: the gate is open for the last owner");
        assertEq(escrow.locked(from).amount, 0);
        assertEq(escrow.votingPower(from), 0);
        assertEq(nftLock.balanceOf(owner), 2, "the burned lock is not counted");

        uint256[] memory burnedOnly = new uint256[](1);
        burnedOnly[0] = from;

        vm.startPrank(owner);

        vm.expectRevert();
        nftLock.ownerOf(from);
        vm.expectRevert();
        escrow.ownerOf(from);
        vm.expectRevert();
        nftLock.approve(operator, from);
        vm.expectRevert();
        nftLock.transferFrom(owner, owner2, from);
        vm.expectRevert();
        nftLock.safeTransferFrom(owner, owner2, from);

        vm.expectRevert();
        escrow.merge(from, other);
        vm.expectRevert();
        escrow.merge(other, from);
        vm.expectRevert();
        escrow.withdraw(from);
        vm.expectRevert();
        escrow.split(from, 1e18);
        vm.expectRevert();
        escrow.increaseAmount(from, 1e18);
        vm.expectRevert();
        escrow.increaseUnlockTime(from, MAX_TIME);
        vm.expectRevert();
        escrow.lockPermanent(from);
        vm.expectRevert();
        escrow.unlockPermanent(from);

        vm.expectRevert();
        ivotesAdapter.delegate(burnedOnly);
        vm.expectRevert();
        ivotesAdapter.undelegate(burnedOnly);

        vm.stopPrank();

        // The escrow still holds exactly what the two live locks hold.
        assertEq(escrow.totalLocked(), uint256(escrow.locked(to).amount) + escrow.locked(other).amount + escrow.locked(setupTokenId).amount);
    }

    function test_lastOwnerIsOnlySetByABurn() public prepared {
        _skipToNextEpoch(1 days);
        vm.startPrank(owner);
        uint256 from = escrow.createLock(TOKEN_1M, MAX_TIME);
        uint256 to = escrow.createLock(TOKEN_1M, MAX_TIME);
        vm.stopPrank();

        assertEq(nftLock.lastOwnerOf(from), address(0));
        vm.prank(owner);
        nftLock.transferFrom(owner, owner2, from);
        assertEq(nftLock.lastOwnerOf(from), address(0), "a transfer does not set it");
        vm.prank(owner2);
        nftLock.transferFrom(owner2, owner, from);

        vm.prank(owner);
        escrow.merge(from, to);
        assertEq(nftLock.lastOwnerOf(from), owner);
        assertEq(nftLock.lastOwnerOf(to), address(0));
    }
}
