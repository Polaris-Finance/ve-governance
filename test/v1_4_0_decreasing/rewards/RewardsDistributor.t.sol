// TODO!
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {
    //Lock,
    //Clock,
    IVotingEscrowDecreasing as IVotingEscrow,
    VotingEscrow,
    IEscrowCurveDecreasing as IEscrowCurve
} from "../versions.sol";
import {RewardsDistributor, IRewardsDistributor} from "../../../src/rewards/RewardsDistributor.sol";

import {MockERC20} from "@mocks/MockERC20.sol";
import {EscrowBase} from "../base/EscrowBase.sol";

import {console2} from "forge-std/console2.sol";

contract RewardsDistributorTest is EscrowBase {
    uint256 constant TOKEN_1 = 1e18;
    uint256 constant TOKEN_1M = 1e24; // 1e6 = 1M tokens with 18 decimals
    uint256 constant TOKEN_10M = 1e25; // 1e7 = 10M tokens with 18 decimals
    uint256 constant REWARD_AMOUNT = 12e18;
    uint256 constant WEEK = 1 weeks;
    /// @dev Use same value as in voting escrow
    uint256 constant MAXTIME = 208 weeks;

    RewardsDistributor public distributor;
    MockERC20 rewardsToken;
    address rewardsSender;

    address owner;
    address owner2;
    address owner3;

    uint256 setupTokenId;

    event Claimed(uint256 indexed tokenId, uint256 indexed epochStart, uint256 indexed epochEnd, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public override {
        super.setUp();
        mintAndApproveEscrow();
        rewardsToken = new MockERC20();

        rewardsSender = makeAddr("Rewards Sender");
        owner = makeAddr("Owner");
        owner2 = makeAddr("Owner 2");
        owner3 = makeAddr("Owner 3");
        mintAndApproveEscrow(owner, 10000000e18);
        mintAndApproveEscrow(owner2, 10000000e18);
        mintAndApproveEscrow(owner3, 10000000e18);

        vm.warp(604800);

        // Setup voter and distributor
        distributor = new RewardsDistributor(address(escrow), address(rewardsToken), rewardsSender);

        vm.label(address(distributor), "Distributor");

        // timestamp: 604801
        setupTokenId = escrow.createLock(TOKEN_1, MAXTIME);
        skip(1);
    }

    function testInitialize() public view {
        assertEq(distributor.START_WEEK_TIME(), 604800);
        assertEq(distributor.lastTokenWeekTime(), 604800);
        assertEq(distributor.token(), address(rewardsToken));
        assertEq(address(distributor.ve()), address(escrow));
    }

    function testClaim() public {
        skipToNextEpoch(1 days);
        uint256 startTime = weekStartTs(block.timestamp);

        vm.startPrank(address(owner));
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        IVotingEscrow.LockedBalance memory locked = escrow.locked(tokenId);
        assertEq(convert(locked.amount), TOKEN_1M);
        assertEq(uint256(locked.start), startTime);
        assertEq(escrow.isPermanent(tokenId), false);

        assertEq(curve.tokenPointLatestIndex(tokenId), 1);
        IEscrowCurve.TokenPoint memory userPoint = curve.tokenPointHistory(tokenId, 1);
        assertEq(convertSlope(userPoint.slope), TOKEN_1M / MAXTIME); // TOKEN_1M / MAXTIME
        assertEq(userPoint.bias, getFlooredAmount(TOKEN_1M) * 1e18);
        assertEq(userPoint.writtenTs, startTime);

        vm.startPrank(address(owner2));
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        locked = escrow.locked(tokenId2);
        assertEq(convert(locked.amount), TOKEN_1M);
        assertEq(uint256(locked.start), startTime);
        assertEq(escrow.isPermanent(tokenId2), false);

        assertEq(curve.tokenPointLatestIndex(tokenId2), 1);
        userPoint = curve.tokenPointHistory(tokenId2, 1);
        assertEq(convertSlope(userPoint.slope), TOKEN_1M / MAXTIME); // TOKEN_1M / MAXTIME
        assertEq(userPoint.bias, getFlooredAmount(TOKEN_1M) * 1e18);
        assertEq(userPoint.writtenTs, startTime);
        // Let's move to next epoch so that locks are eligible for rewards
        vm.warp(block.timestamp + 1 weeks);

        // epoch 3
        triggerRewardsAndSkipToNextEpoch(0);
        // The first epoch is claimable only by the setup lock
        // The setup lock is only 1 vs 1M the next 2, so its share is almost negligible
        uint256 expectedRewards = 2999998514423812611; // Approx: REWARD_AMOUNT / 2 / 2.
        assertEq(distributor.claimable(tokenId), expectedRewards);
        assertEq(distributor.claimable(tokenId2), expectedRewards);
        assertEq(distributor.claimable(setupTokenId), 6000002971152374777); // Approx REWARD_AMOUNT / 2

        // epoch 4
        triggerRewardsAndSkipToNextEpoch(0);
        // Approx: Each new epoch, we add approx REWARD_AMOUNT / 2 ~= 6 tokens
        // Setup lock barely increases the rewards, as its dwarfed by the other 2 tokens
        expectedRewards = 8999995543410791095;
        assertEq(distributor.claimable(tokenId), expectedRewards);
        assertEq(distributor.claimable(tokenId2), expectedRewards);
        assertEq(distributor.claimable(setupTokenId), 6000008913178417807);

        // epoch 5
        triggerRewardsAndSkipToNextEpoch(0);
        expectedRewards = 14999992572538475786;
        assertEq(distributor.claimable(tokenId), expectedRewards);
        assertEq(distributor.claimable(tokenId2), expectedRewards);
        assertEq(distributor.claimable(setupTokenId), 6000014854923048424);

        // epoch 6
        triggerRewardsAndSkipToNextEpoch(0);
        expectedRewards = 20999989601808239427;
        assertEq(distributor.claimable(tokenId), expectedRewards);
        assertEq(distributor.claimable(tokenId2), expectedRewards);
        assertEq(distributor.claimable(setupTokenId), 6000020796383521141);

        //vm.expectEmit(true, true, true, true, address(distributor));
        //emit Claimed(tokenId, 1209600, 3628800, 8723818542033905018192152);
        vm.prank(owner);
        distributor.claim(tokenId);
        uint256 postClaimedBalance = rewardsToken.balanceOf(owner);
        assertEq(postClaimedBalance, expectedRewards);
    }

    function testClaimWithPermanentLocks() public {
        triggerRewardsAndSkipToNextEpoch(1 days); // epoch 1, ts: 1296000, next checkpoint: 1814400

        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        escrow.lockPermanent(tokenId);

        IVotingEscrow.LockedBalance memory locked = escrow.locked(tokenId);
        assertEq(convert(locked.amount), TOKEN_1M);
        assertEq(uint256(locked.start), 0);
        assertEq(escrow.isPermanent(tokenId), true);

        assertEq(curve.tokenPointLatestIndex(tokenId), 1);
        IEscrowCurve.TokenPoint memory userPoint = curve.tokenPointHistory(tokenId, 1);
        assertEq(convertSlope(userPoint.slope), 0);
        assertEq(userPoint.bias, TOKEN_1M * 1e18);
        assertEq(userPoint.writtenTs, 1814400);

        vm.startPrank(address(owner2));
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);
        escrow.lockPermanent(tokenId2);
        vm.stopPrank();

        locked = escrow.locked(tokenId2);
        assertEq(convert(locked.amount), TOKEN_1M);
        assertEq(uint256(locked.start), 0);
        assertEq(escrow.isPermanent(tokenId2), true);

        assertEq(curve.tokenPointLatestIndex(tokenId2), 1);
        userPoint = curve.tokenPointHistory(tokenId2, 1);
        assertEq(convertSlope(userPoint.slope), 0);
        assertEq(userPoint.bias, TOKEN_1M * 1e18);
        assertEq(userPoint.writtenTs, 1814400);

        // epoch 3 - no rewards, locks were not active yet
        triggerRewardsAndSkipToNextEpoch(0);
        assertEq(distributor.claimable(tokenId), 0);
        assertEq(distributor.claimable(tokenId2), 0);

        // epoch 4
        triggerRewardsAndSkipToNextEpoch(0);
        assertEq(distributor.claimable(tokenId), 5999997028847625222); // ~half of REWARD_AMOUNT
        assertEq(distributor.claimable(tokenId2), 5999997028847625222);

        // epoch 5
        triggerRewardsAndSkipToNextEpoch(0);
        assertEq(distributor.claimable(tokenId), 11999994072118313117); // ~half of REWARD_AMOUNT * 2
        assertEq(distributor.claimable(tokenId2), 11999994072118313117);

        // epoch 6
        triggerRewardsAndSkipToNextEpoch(0);
        uint256 expectedRewards = 17999991129812063754; // ~half of REWARD_AMOUNT * 3
        assertEq(distributor.claimable(tokenId), expectedRewards);
        assertEq(distributor.claimable(tokenId2), expectedRewards);

        uint256 pre = rewardsToken.balanceOf(address(this));

        vm.expectEmit(true, true, true, true, address(rewardsToken));
        emit Transfer(address(distributor), address(this), expectedRewards);
        //vm.expectEmit(true, true, true, true, address(distributor));
        //emit Claimed(tokenId, 1209600, 3628800, expectedRewards);
        distributor.claim(tokenId);

        uint256 post = rewardsToken.balanceOf(address(this));
        assertEq(post - pre, expectedRewards);
        IVotingEscrow.LockedBalance memory postLocked = escrow.locked(tokenId);
        assertEq(uint256(postLocked.start), 0);
        assertEq(escrow.isPermanent(tokenId), true);
    }

    function testClaimWithBothLocks() public {
        triggerRewardsAndSkipToNextEpoch(1 days); // epoch 1, ts: 1296000, next checkpoint: 1814400

        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        escrow.lockPermanent(tokenId);

        vm.startPrank(address(owner2));
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        // expect permanent lock to earn more rewards
        // epoch 3 - no rewards, locks were not active yet
        triggerRewardsAndSkipToNextEpoch(0); // distribute epoch 1's rewards
        assertEq(distributor.claimable(tokenId), 0);
        assertEq(distributor.claimable(tokenId2), 0);

        // epoch 4
        triggerRewardsAndSkipToNextEpoch(0); // distribute epoch 2's rewards
        assertEq(distributor.claimable(tokenId), 5999997028847625308);
        assertEq(distributor.claimable(tokenId2), 5999997028847625137);

        // epoch 5
        triggerRewardsAndSkipToNextEpoch(0); // distribute epoch 3's rewards
        assertEq(distributor.claimable(tokenId), 12014451889177152303);
        assertEq(distributor.claimable(tokenId2), 11985536240810183081);

        // epoch 6
        triggerRewardsAndSkipToNextEpoch(0); // distribute epoch 4's rewards
        assertEq(distributor.claimable(tokenId), 18043434425620540312);
        assertEq(distributor.claimable(tokenId2), 17956547791326230651);

        uint256 pre = rewardsToken.balanceOf(address(this));

        //vm.expectEmit(true, true, true, true, address(distributor));
        //emit Claimed(tokenId, 1209600, 3628800, 8790443106370251794057763);
        distributor.claim(tokenId);

        uint256 post = rewardsToken.balanceOf(address(this));
        assertEq(post - pre, 18043434425620540312);
    }

    function testClaimWithLockCreatedMoreThan50EpochsLater() public {
        for (uint256 i = 0; i < 55; i++) {
            triggerRewardsAndSkipToNextEpoch(0);
        }
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);

        triggerRewardsAndSkipToNextEpoch(0);
        assertEq(distributor.tokenLastBalance(), 672e18); // 56 times rewards
        assertEq(distributor.claimable(tokenId), 5999997793270042441); // ~half of REWARD_AMOUNT
        assertEq(distributor.claimable(tokenId2), 5999997793270042441);

        triggerRewardsAndSkipToNextEpoch(0);
        uint256 expectedRewards = 11999995590372300572; // ~half of 2 * REWARD_AMOUNT
        assertEq(distributor.claimable(tokenId), expectedRewards);
        assertEq(distributor.claimable(tokenId2), expectedRewards);

        //vm.expectEmit(true, true, true, true, address(distributor));
        //emit Claimed(tokenId, 33868800, 35078400, expectedRewards);
        distributor.claim(tokenId);
        uint256 postClaimedBalance = rewardsToken.balanceOf(address(this));

        assertEq(postClaimedBalance, expectedRewards);
    }

    function testClaimWithIncreaseAmountOnEpochFlip() public {
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);
        skipToNextEpoch(0); // So that tokens above capture rewards

        triggerRewardsAndSkipToNextEpoch(0);
        assertEq(distributor.claimable(tokenId), 5999997014424562619);
        assertEq(distributor.claimable(tokenId2), 5999997014424562619);

        triggerRewardsAndSkipToNextEpoch(0);
        uint256 expectedRewards = 11999994028918801868;
        assertEq(distributor.claimable(tokenId), expectedRewards);
        assertEq(distributor.claimable(tokenId2), expectedRewards);
        // making lock larger on flip should not impact claimable
        escrow.increaseAmount(tokenId, TOKEN_1M);
        triggerRewards();
        assertEq(distributor.claimable(tokenId), expectedRewards);
        assertEq(distributor.claimable(tokenId2), expectedRewards);
    }

    function testClaimWithExpiredNFT() public {
        vm.warp(block.timestamp + MAXTIME); // To allow for virtual start time
        triggerRewardsAndSkipToNextEpoch(0); // this will dilute during the last 4 years
        // test reward claims to expired NFTs are distributed as unlocked rewardsToken
        uint256 tokenId = escrow.createLock(TOKEN_1M, WEEK * 4);

        triggerRewardsAndSkipToNextEpoch(1);
        // accrued rewards, error coming from previous weeks rounding
        assertEq(distributor.claimable(tokenId), REWARD_AMOUNT + 64);

        for (uint256 i = 0; i < 4; i++) {
            triggerRewardsAndSkipToNextEpoch(1);
        }

        // accrued rewards, error coming from previous weeks rounding
        assertEq(distributor.claimable(tokenId), 4 * REWARD_AMOUNT + 64);

        IVotingEscrow.LockedBalance memory locked = escrow.locked(tokenId);
        assertGt(block.timestamp, uint256(locked.start) + MAX_TIME); // lock expired

        uint256 reward = distributor.claimable(tokenId);
        uint256 pre = rewardsToken.balanceOf(address(this));
        //vm.expectEmit(true, true, true, true, address(distributor));
        //emit Claimed(tokenId, 604800, 3628800, 15491459054552564388715110);
        distributor.claim(tokenId);
        uint256 post = rewardsToken.balanceOf(address(this));

        locked = escrow.locked(tokenId); // update locked value post claim
        assertEq(post - pre, reward); // expired reward distributed as unlocked rewardsToken
        assertEq(uint256(uint128(locked.amount)), TOKEN_1M); // expired nft locked balance unchanged
    }

    function testClaimManyWithExpiredNFT() public {
        vm.warp(block.timestamp + MAXTIME); // To allow for virtual start time
        triggerRewardsAndSkipToNextEpoch(0); // this will dilute during the last 4 years
        // test claim many with one expired nft and one normal nft
        uint256 tokenId = escrow.createLock(TOKEN_1M, WEEK * 4);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);

        triggerRewardsAndSkipToNextEpoch(1);
        assertEq(distributor.claimable(tokenId), 226415094339622642);
        // error coming from previous weeks rounding
        assertApproxEqAbs(distributor.claimable(tokenId2), REWARD_AMOUNT - 226415094339622642, 63);

        for (uint256 i = 0; i < 4; i++) {
            triggerRewardsAndSkipToNextEpoch(1);
        }

        assertGt(distributor.claimable(tokenId), 0); // accrued rewards
        assertGt(distributor.claimable(tokenId2), 0);

        IVotingEscrow.LockedBalance memory locked = escrow.locked(tokenId);
        assertGt(block.timestamp, uint256(locked.start) + MAX_TIME); // lock expired

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId;
        tokenIds[1] = tokenId2;

        uint256 reward = distributor.claimable(tokenId);
        uint256 reward2 = distributor.claimable(tokenId2);

        uint256 pre = rewardsToken.balanceOf(address(this));
        assertTrue(distributor.claimMany(tokenIds));
        uint256 post = rewardsToken.balanceOf(address(this));

        locked = escrow.locked(tokenId); // update locked value post claim
        assertEq(post - pre, reward + reward2);
        assertEq(uint256(uint128(locked.amount)), TOKEN_1M); // expired nft locked balance unchanged
    }

    function testCanClaimDuringFirstHour() public {
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M * 8, MAXTIME);
        skipToNextEpoch(0); // So that tokens above capture rewards

        triggerRewardsAndSkipToNextEpoch(2 hours); // epoch 1

        assertEq(distributor.claimable(tokenId), 1333333185897452186); // REWARD_AMOUNT / 9
        assertEq(distributor.claimable(tokenId2), 10666665487179617655); // REWARD_AMOUNT * 8 / 9

        triggerRewardsAndSkipToNextEpoch(1 hours); // epoch 3
        distributor.claim(tokenId);

        skipAndRoll(1 hours);

        // Nothing else to claim
        uint256 pre = rewardsToken.balanceOf(address(this));
        distributor.claim(tokenId);
        uint256 post = rewardsToken.balanceOf(address(this));
        assertEq(post, pre);
    }

    function testCannotCheckpointTokenIfNotRewardsSender() public {
        vm.expectRevert(IRewardsDistributor.NotRewardsSender.selector);
        vm.prank(address(owner2));
        distributor.checkpointToken();
    }

    function testClaimBeforeLockedEnd() public {
        vm.warp(block.timestamp + MAXTIME); // To allow for virtual start time
        triggerRewardsAndSkipToNextEpoch(0); // this will dilute during the last 4 years

        uint256 duration = WEEK * 12;
        vm.prank(address(owner));
        uint256 tokenId = escrow.createLock(TOKEN_1M, duration);

        triggerRewardsAndSkipToNextEpoch(1);
        assertGt(distributor.claimable(tokenId), 0);

        IVotingEscrow.LockedBalance memory locked = escrow.locked(tokenId);
        vm.warp(uint256(locked.start) + MAX_TIME - 1);
        assertEq(block.timestamp, uint256(locked.start) + MAX_TIME - 1);

        uint256 balanceBefore = rewardsToken.balanceOf(address(owner));
        vm.prank(address(owner));
        distributor.claim(tokenId);
        assertGt(rewardsToken.balanceOf(address(owner)), balanceBefore);
    }

    function testClaimOnLockedEnd() public {
        vm.warp(block.timestamp + MAXTIME); // To allow for virtual start time
        triggerRewardsAndSkipToNextEpoch(0); // this will dilute during the last 4 years

        uint256 duration = WEEK * 12;
        vm.prank(address(owner));
        uint256 tokenId = escrow.createLock(TOKEN_1M, duration);

        triggerRewardsAndSkipToNextEpoch(1);
        assertGt(distributor.claimable(tokenId), 0);

        IVotingEscrow.LockedBalance memory locked = escrow.locked(tokenId);
        vm.warp(uint256(locked.start) + MAX_TIME);
        assertEq(block.timestamp, uint256(locked.start) + MAX_TIME);

        uint256 balanceBefore = rewardsToken.balanceOf(address(owner));
        vm.prank(address(owner));
        distributor.claim(tokenId);
        assertGt(rewardsToken.balanceOf(address(owner)), balanceBefore);
    }

    function testClaimAfterMerge() public {
        vm.prank(address(owner));
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAX_TIME);
        vm.prank(address(owner));
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAX_TIME);

        // First rewards before effective start of tokens
        triggerRewardsAndSkipToNextEpoch(0);
        uint256 claimable1 = distributor.claimable(tokenId);
        uint256 claimable2 = distributor.claimable(tokenId2);
        assertEq(claimable1, 0);
        assertEq(claimable2, 0);
        assertEq(claimable1, claimable2);

        // Both tokens accrue some rewards
        triggerRewardsAndSkipToNextEpoch(0);
        claimable1 = distributor.claimable(tokenId);
        claimable2 = distributor.claimable(tokenId2);
        assertGt(claimable1, 0);
        assertGt(claimable2, 0);
        assertEq(claimable1, claimable2);

        // Merge
        vm.prank(owner);
        escrow.merge(tokenId, tokenId2);
        vm.warp(block.timestamp + 1 weeks); // Make the merge effective

        // TODO: It fails from here on
        /*
        claimable1 = distributor.claimable(tokenId);
        claimable2 = distributor.claimable(tokenId2);
        assertGt(claimable1, 0);
        assertGt(claimable2, 0);
        assertEq(claimable1, claimable2);

        // Trigger rewards after merge, now "to" token has more rewards
        triggerRewardsAndSkipToNextEpoch(0);
        claimable1 = distributor.claimable(tokenId);
        claimable2 = distributor.claimable(tokenId2);
        assertGt(claimable1, 0);
        assertGt(claimable2, 0);
        assertLt(claimable1, claimable2);

        // Claim "from" token
        uint256 balanceBefore = rewardsToken.balanceOf(address(owner));
        vm.prank(address(owner));
        distributor.claim(tokenId);
        assertGt(rewardsToken.balanceOf(address(owner)), balanceBefore + claimable1);

        // Claim "to" token
        balanceBefore = rewardsToken.balanceOf(address(owner));
        vm.prank(address(owner));
        distributor.claim(tokenId2);
        assertGt(rewardsToken.balanceOf(address(owner)), balanceBefore + claimable2);
        */
    }

    function testCheckpointAfterMoreThanFourYears() public {
        skipToNextEpoch(0);

        vm.prank(address(owner));
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAX_TIME);

        vm.warp(block.timestamp + 2 weeks);

        vm.prank(address(owner2));
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAX_TIME - 2 weeks);
        vm.warp(block.timestamp + 1 weeks);

        vm.warp(block.timestamp + MAXTIME);

        triggerRewardsAndSkipToNextEpoch(0); // this will dilute during the last 4 years

        // As the claim is capped at 1 year, we need to call it several times to make sure we claim everything
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(address(owner));
            distributor.claim(tokenId);
            vm.prank(address(owner2));
            distributor.claim(tokenId2);
        }

        // Even if token 1 was older, they get the same rewards, as the rewards spread over the last 4 years, but not beyond
        assertEq(rewardsToken.balanceOf(owner), rewardsToken.balanceOf(owner2));
    }

    function testRewardsNotLostIfArrivedAfterClaim() public {
        skipToNextEpoch(0);

        vm.prank(address(owner));
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAX_TIME);

        // Wait until lock is effective
        vm.warp(block.timestamp + 1 weeks);

        triggerRewardsAndSkipToNextEpoch(1 days);

        uint256 initialBalance = rewardsToken.balanceOf(owner);

        vm.prank(address(owner));
        distributor.claim(tokenId);

        // Rewards received
        assertGt(rewardsToken.balanceOf(owner), initialBalance, "Owner should have received rewards");
        // As just claimed, there is nothing else to claim
        assertEq(distributor.claimable(tokenId), 0, "There should be nothing to claim");

        // New rewards arrive immediately after
        triggerRewardsAndSkipToNextEpoch(0);

        // Last rewards can be claimed
        assertGt(distributor.claimable(tokenId), 0, "There should be rewards to be claimed");
    }


    // Helper functions

    function triggerRewards() internal {
        triggerRewards(REWARD_AMOUNT);
    }

    function triggerRewards(uint256 _amount) internal {
        rewardsToken.mint(address(distributor), _amount);
        vm.prank(rewardsSender);
        distributor.checkpointToken();
    }

    /// @dev Helper utility to forward time to next week
    ///      note epoch requires at least one second to have
    ///      passed into the new epoch
    function skipToNextEpoch(uint256 offset) public {
        uint256 ts = block.timestamp;
        uint256 nextEpoch = ts - (ts % (1 weeks)) + (1 weeks);
        vm.warp(nextEpoch + offset);
        vm.roll(block.number + 1);
    }

    function triggerRewardsAndSkipToNextEpoch(uint256 offset) internal {
        triggerRewards(REWARD_AMOUNT);
        skipToNextEpoch(offset);
    }

    function skipAndRoll(uint256 timeOffset) public {
        skip(timeOffset);
        vm.roll(block.number + 1);
    }

    /// @dev Used to convert IVotingEscrow int128s to uint256
    ///      These values are always positive
    function convert(uint208 _amount) internal pure returns (uint256) {
        return uint256(uint128(_amount));
    }

    function convertSlope(int256 _slope) internal pure returns (uint256) {
        return uint256(-_slope) / 1e18;
    }
}
