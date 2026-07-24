// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {
    IVotingEscrowDecreasing as IVotingEscrow,
    VotingEscrow,
    IEscrowCurveDecreasing as IEscrowCurve
} from "../versions.sol";
import {RewardsDistributor} from "../../../src/rewards/RewardsDistributor.sol";

import {MockERC20} from "@mocks/MockERC20.sol";
import {EscrowBase} from "../base/EscrowBase.sol";

/// Regression test: first-claim week cursor must land on the distributor's
/// WEEK grid.
///
/// RewardsDistributor._claimable() starts a lock's first claim cursor at
/// `userPoint.writtenTs` — an escrow CLOCK checkpoint timestamp — while
/// `tokensPerWeek` buckets are keyed on multiples of the distributor's WEEK.
/// If the two grids don't coincide, the cursor starts off-grid, `+= WEEK`
/// keeps it off-grid forever, every bucket read hits an empty slot, and the
/// lock can never claim anything — even when its week was funded and it held
/// power at the week start. (Curve's FeeDistributor, which this design
/// follows, rounds the initial cursor onto the week grid.)
///
/// On the fast-governance profile (clock checkpoints hourly, WEEK = 2 days)
/// virtually every lock activates off-grid, so the bug is total. On the
/// stock configuration both grids are 1-week multiples and the bug is masked
/// by coincidence — which is why the pre-existing suite never caught it.
///
/// Observed live on the Sepolia testnet: distributor bucket funded with
/// ~114 USDp, a lock holding 54% of voting power at the week start,
/// claimable() == 0.
contract RewardsDistributorCursorAlignmentTest is EscrowBase {
    uint256 constant TOKEN_1M = 1e24;
    uint256 constant REWARD_AMOUNT = 12e18;

    RewardsDistributor distributor;
    MockERC20 rewardsToken;
    address rewardsSender;
    address owner;

    function setUp() public override {
        super.setUp();
        rewardsToken = new MockERC20();
        rewardsSender = makeAddr("Rewards Sender");
        owner = makeAddr("Owner");
        mintAndApproveEscrow(owner, TOKEN_1M);

        // Start on a clean distributor grid point well past zero.
        vm.warp(52 weeks);
        distributor = new RewardsDistributor(address(escrow), address(rewardsToken), rewardsSender);
    }

    function _fundAndCheckpoint(uint256 amount) internal {
        rewardsToken.mint(address(distributor), amount);
        vm.prank(rewardsSender);
        distributor.checkpointToken();
    }

    function testMisalignedLockCanClaimFundedElapsedWeek() public {
        uint256 WEEK_ = distributor.WEEK();
        uint256 interval = clock.checkpointInterval();

        // Premise of the regression: the clock grid must NOT be a subset of
        // the distributor grid (true on the fast-governance profile: 1h vs
        // 2d). If a future config re-aligns the grids, this test's trigger
        // disappears — fail loudly so it gets re-thought rather than
        // silently passing.
        assertTrue(WEEK_ % interval == 0 && interval < WEEK_, "config: clock must subdivide WEEK for this repro");

        // Create the lock ONE CLOCK CHECKPOINT after a distributor week
        // boundary → its activation (writtenTs) is off the WEEK grid.
        uint256 week0 = (block.timestamp / WEEK_ + 1) * WEEK_;
        vm.warp(week0 + interval);
        // (maxTime read hoisted — an external call in the arg list would
        //  consume the prank and createLock would pull from the test.)
        uint256 maxT = curve.maxTime();
        vm.prank(owner);
        uint256 tokenId = escrow.createLock(TOKEN_1M, maxT);

        IEscrowCurve.TokenPoint memory userPoint = curve.tokenPointHistory(tokenId, 1);
        assertTrue(uint256(userPoint.writtenTs) % WEEK_ != 0, "premise: activation must be off the WEEK grid");

        // week1 is the first full week the lock is powered for.
        uint256 week1 = week0 + WEEK_;

        // Fund week1: checkpoint at its start (closes out week0), then again
        // right after it ends (attributes the rewards into week1's bucket).
        vm.warp(week1);
        _fundAndCheckpoint(0);
        vm.warp(week1 + WEEK_ + 1);
        _fundAndCheckpoint(REWARD_AMOUNT);

        // Sanity: the bucket is funded and the lock held (all) power at the
        // week start — by construction it MUST have a claim.
        assertGt(distributor.tokensPerWeek(week1), 0, "sanity: week1 bucket funded");
        assertGt(escrow.votingPowerAt(tokenId, week1), 0, "sanity: lock powered at week1 start");
        assertGt(escrow.totalVotingPowerAt(week1), 0, "sanity: total power at week1 start");

        // THE regression assertion — fails while the first-claim cursor is
        // taken verbatim from writtenTs instead of rounded onto the grid.
        assertGt(
            distributor.claimable(tokenId),
            0,
            "misaligned lock cannot claim a funded, fully elapsed week"
        );

        // And the claim must actually pay out.
        vm.prank(owner);
        distributor.claim(tokenId);
        assertGt(rewardsToken.balanceOf(owner), 0, "claim paid nothing");
    }
}
