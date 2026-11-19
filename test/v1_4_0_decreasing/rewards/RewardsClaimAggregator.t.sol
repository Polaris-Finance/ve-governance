// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {IERC721EnumerableMintableBurnable as IERC721EMB} from "@lock/IERC721EMB.sol";

import {IVotingEscrowDecreasing as IVotingEscrow} from "../../../src/escrow/IVotingEscrowDecreasing.sol";
import {IRewardsDistributor} from "../../../src/rewards/IRewardsDistributor.sol";
import {RewardsClaimAggregator} from "../../../src/rewards/RewardsClaimAggregator.sol";

import {MockERC20} from "@mocks/MockERC20.sol";
import {EscrowBase} from "../base/EscrowBase.sol";
import {RewardsBase} from "../base/RewardsBase.sol";

contract RewardsClaimAggregatorTest is EscrowBase, RewardsBase {
    /// @dev Use same value as in voting escrow
    uint256 constant MAXTIME = 208 weeks;
    uint256 constant TOKEN_1M = 1e24; // 1e6 = 1M tokens with 18 decimals
    uint256 constant REWARD_AMOUNT = 12e18;

    address owner1;
    address owner2;

    IERC721EMB public lockNFT;

    function setUp() public override {
        super.setUp();
        owner1 = makeAddr("Owner1");
        owner2 = makeAddr("Owner2");
        mintAndApproveEscrow(owner1, 10000000e18);
        mintAndApproveEscrow(owner2, 10000000e18);

        vm.warp(604800);

        deployRewardsDistributors(address(escrow));

        // Approve aggregator so it can claim
        lockNFT = IERC721EMB(escrow.lockNFT());
        approveAggregator(lockNFT, owner1);
        approveAggregator(lockNFT, owner2);
    }

    function testInitialize() public view {
        assertEq(address(aggregator.ve()), address(escrow));
    }

    /*//////////////////////////////////////////////////////////////
                              CLAIM
    //////////////////////////////////////////////////////////////*/

    function testClaimSingleDistributor() public {
        IRewardsDistributor[] memory distributors = new IRewardsDistributor[](1);
        distributors[0] = distributor1;

        uint256 maxWeeks = 2;

        vm.startPrank(address(owner1));
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        // Let's move to next epoch so that locks are eligible for rewards
        vm.warp(block.timestamp + 1 weeks);

        _triggerRewardsAndSkipToNextEpoch(0);
        assertEq(distributor1.claimable(tokenId), REWARD_AMOUNT);

        _triggerRewardsAndSkipToNextEpoch(0);
        assertEq(distributor1.claimable(tokenId), 2 * REWARD_AMOUNT);

        // Claim in 2 calls (by using a small number of weeks)
        vm.prank(owner1);
        aggregator.claim(distributors, tokenId, maxWeeks);
        assertEq(rewardsToken1.balanceOf(owner1), REWARD_AMOUNT);
        assertEq(rewardsToken2.balanceOf(owner1), 0);
        assertEq(rewardsToken3.balanceOf(owner1), 0);

        vm.prank(owner1);
        aggregator.claim(distributors, tokenId, maxWeeks);
        assertEq(rewardsToken1.balanceOf(owner1), 2 * REWARD_AMOUNT);
        assertEq(rewardsToken2.balanceOf(owner1), 0);
        assertEq(rewardsToken3.balanceOf(owner1), 0);
    }

    function testClaimMultipleDistributors() public {
        IRewardsDistributor[] memory distributors = new IRewardsDistributor[](3);
        distributors[0] = distributor1;
        distributors[1] = distributor2;
        distributors[2] = distributor3;

        uint256 maxWeeks = 10;

        vm.startPrank(address(owner1));
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        // Let's move to next epoch so that locks are eligible for rewards
        vm.warp(block.timestamp + 1 weeks);

        _triggerRewardsAndSkipToNextEpoch(0);

        assertEq(distributor1.claimable(tokenId), REWARD_AMOUNT);
        assertEq(distributor2.claimable(tokenId), REWARD_AMOUNT);
        assertEq(distributor3.claimable(tokenId), REWARD_AMOUNT);

        vm.prank(owner1);
        aggregator.claim(distributors, tokenId, maxWeeks);
        assertEq(rewardsToken1.balanceOf(owner1), REWARD_AMOUNT);
        assertEq(rewardsToken2.balanceOf(owner1), REWARD_AMOUNT);
        assertEq(rewardsToken3.balanceOf(owner1), REWARD_AMOUNT);
    }

    function testClaimFromApprovedAccount() public {
        IRewardsDistributor[] memory distributors = new IRewardsDistributor[](3);
        distributors[0] = distributor1;
        distributors[1] = distributor2;
        distributors[2] = distributor3;

        uint256 maxWeeks = 10;

        vm.startPrank(address(owner1));
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        lockNFT.approve(owner2, tokenId);
        vm.stopPrank();

        // Let's move to next epoch so that locks are eligible for rewards
        vm.warp(block.timestamp + 1 weeks);

        _triggerRewardsAndSkipToNextEpoch(0);

        assertEq(distributor1.claimable(tokenId), REWARD_AMOUNT);
        assertEq(distributor2.claimable(tokenId), REWARD_AMOUNT);
        assertEq(distributor3.claimable(tokenId), REWARD_AMOUNT);

        vm.prank(owner2);
        aggregator.claim(distributors, tokenId, maxWeeks);
        assertEq(rewardsToken1.balanceOf(owner1), 0);
        assertEq(rewardsToken2.balanceOf(owner1), 0);
        assertEq(rewardsToken3.balanceOf(owner1), 0);
        assertEq(rewardsToken1.balanceOf(owner2), REWARD_AMOUNT);
        assertEq(rewardsToken2.balanceOf(owner2), REWARD_AMOUNT);
        assertEq(rewardsToken3.balanceOf(owner2), REWARD_AMOUNT);
    }

    function testThirdPartyCannotClaim() public {
        IRewardsDistributor[] memory distributors = new IRewardsDistributor[](3);
        distributors[0] = distributor1;
        distributors[1] = distributor2;
        distributors[2] = distributor3;

        uint256 maxWeeks = 10;

        vm.startPrank(address(owner1));
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        // Let's move to next epoch so that locks are eligible for rewards
        vm.warp(block.timestamp + 1 weeks);

        _triggerRewardsAndSkipToNextEpoch(0);

        assertEq(distributor1.claimable(tokenId), REWARD_AMOUNT);
        assertEq(distributor2.claimable(tokenId), REWARD_AMOUNT);
        assertEq(distributor3.claimable(tokenId), REWARD_AMOUNT);

        vm.prank(owner2);
        vm.expectRevert(NotApprovedOrOwner.selector);
        aggregator.claim(distributors, tokenId, maxWeeks);
        assertEq(rewardsToken1.balanceOf(owner1), 0);
        assertEq(rewardsToken2.balanceOf(owner1), 0);
        assertEq(rewardsToken3.balanceOf(owner1), 0);
        assertEq(rewardsToken1.balanceOf(owner2), 0);
        assertEq(rewardsToken2.balanceOf(owner2), 0);
        assertEq(rewardsToken3.balanceOf(owner2), 0);
    }

    function testClaimEmptyDistributors() public {
        IRewardsDistributor[] memory distributors = new IRewardsDistributor[](0);

        vm.startPrank(address(owner1));
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        // Let's move to next epoch so that locks are eligible for rewards
        vm.warp(block.timestamp + 1 weeks);

        _triggerRewardsAndSkipToNextEpoch(0);

        vm.prank(owner1);
        vm.expectRevert(RewardsClaimAggregator.EmptyList.selector);
        aggregator.claim(distributors, tokenId, 1);
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM MANY
    //////////////////////////////////////////////////////////////*/

    function testClaimManySingleDistributor() public {
        IRewardsDistributor[] memory distributors = new IRewardsDistributor[](1);
        distributors[0] = distributor1;

        uint256 maxWeeks = 2;

        vm.startPrank(address(owner1));
        uint256 tokenId1 = escrow.createLock(TOKEN_1M, MAXTIME);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;

        // Let's move to next epoch so that locks are eligible for rewards
        vm.warp(block.timestamp + 1 weeks);

        _triggerRewardsAndSkipToNextEpoch(0);
        assertEq(distributor1.claimable(tokenId1), REWARD_AMOUNT / 2);
        assertEq(distributor1.claimable(tokenId2), REWARD_AMOUNT / 2);
        assertEq(distributor2.claimable(tokenId1), REWARD_AMOUNT / 2);
        assertEq(distributor2.claimable(tokenId2), REWARD_AMOUNT / 2);

        _triggerRewardsAndSkipToNextEpoch(0);
        assertEq(distributor1.claimable(tokenId1), REWARD_AMOUNT);
        assertEq(distributor1.claimable(tokenId2), REWARD_AMOUNT);
        assertEq(distributor2.claimable(tokenId1), REWARD_AMOUNT);
        assertEq(distributor2.claimable(tokenId2), REWARD_AMOUNT);

        // Claim in 2 calls (by using a small number of weeks)
        vm.prank(owner1);
        aggregator.claimMany(distributors, tokenIds, maxWeeks);

        assertEq(rewardsToken1.balanceOf(owner1), REWARD_AMOUNT);
        assertEq(rewardsToken2.balanceOf(owner1), 0);
        assertEq(rewardsToken3.balanceOf(owner1), 0);

        vm.prank(owner1);
        aggregator.claimMany(distributors, tokenIds, maxWeeks);

        assertEq(rewardsToken1.balanceOf(owner1), 2 * REWARD_AMOUNT);
        assertEq(rewardsToken2.balanceOf(owner1), 0);
        assertEq(rewardsToken3.balanceOf(owner1), 0);
    }

    function testClaimManyMultipleDistributors() public {
        IRewardsDistributor[] memory distributors = new IRewardsDistributor[](2);
        distributors[0] = distributor1;
        distributors[1] = distributor2;

        uint256 maxWeeks = 2;

        vm.startPrank(address(owner1));
        uint256 tokenId1 = escrow.createLock(TOKEN_1M, MAXTIME);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;

        // Let's move to next epoch so that locks are eligible for rewards
        vm.warp(block.timestamp + 1 weeks);

        _triggerRewardsAndSkipToNextEpoch(0);
        assertEq(distributor1.claimable(tokenId1), REWARD_AMOUNT / 2);
        assertEq(distributor1.claimable(tokenId2), REWARD_AMOUNT / 2);
        assertEq(distributor2.claimable(tokenId1), REWARD_AMOUNT / 2);
        assertEq(distributor2.claimable(tokenId2), REWARD_AMOUNT / 2);

        _triggerRewardsAndSkipToNextEpoch(0);
        assertEq(distributor1.claimable(tokenId1), REWARD_AMOUNT);
        assertEq(distributor1.claimable(tokenId2), REWARD_AMOUNT);
        assertEq(distributor2.claimable(tokenId1), REWARD_AMOUNT);
        assertEq(distributor2.claimable(tokenId2), REWARD_AMOUNT);

        // Claim in 2 calls (by using a small number of weeks)

        vm.prank(owner1);
        aggregator.claimMany(distributors, tokenIds, maxWeeks);

        assertEq(rewardsToken1.balanceOf(owner1), REWARD_AMOUNT);
        assertEq(rewardsToken2.balanceOf(owner1), REWARD_AMOUNT);
        assertEq(rewardsToken3.balanceOf(owner1), 0);

        vm.prank(owner1);
        aggregator.claimMany(distributors, tokenIds, maxWeeks);

        assertEq(rewardsToken1.balanceOf(owner1), 2 * REWARD_AMOUNT);
        assertEq(rewardsToken2.balanceOf(owner1), 2 * REWARD_AMOUNT);
        assertEq(rewardsToken3.balanceOf(owner1), 0);
    }

    function testClaimManyFromApprovedAccount() public {
        IRewardsDistributor[] memory distributors = new IRewardsDistributor[](2);
        distributors[0] = distributor1;
        distributors[1] = distributor2;

        uint256 maxWeeks = 3;

        vm.startPrank(address(owner1));
        uint256 tokenId1 = escrow.createLock(TOKEN_1M, MAXTIME);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);
        lockNFT.setApprovalForAll(owner2, true);
        vm.stopPrank();
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;

        // Let's move to next epoch so that locks are eligible for rewards
        vm.warp(block.timestamp + 1 weeks);

        _triggerRewardsAndSkipToNextEpoch(0);

        vm.prank(owner2);
        aggregator.claimMany(distributors, tokenIds, maxWeeks);

        assertEq(rewardsToken1.balanceOf(owner1), 0);
        assertEq(rewardsToken2.balanceOf(owner1), 0);
        assertEq(rewardsToken3.balanceOf(owner1), 0);
        assertEq(rewardsToken1.balanceOf(owner2), REWARD_AMOUNT);
        assertEq(rewardsToken2.balanceOf(owner2), REWARD_AMOUNT);
        assertEq(rewardsToken3.balanceOf(owner2), 0);
    }

    function testThirdPartyCannotClaimMany() public {
        IRewardsDistributor[] memory distributors = new IRewardsDistributor[](2);
        distributors[0] = distributor1;
        distributors[1] = distributor2;

        uint256 maxWeeks = 3;

        vm.startPrank(address(owner1));
        uint256 tokenId1 = escrow.createLock(TOKEN_1M, MAXTIME);
        uint256 tokenId2 = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;

        // Let's move to next epoch so that locks are eligible for rewards
        vm.warp(block.timestamp + 1 weeks);

        _triggerRewardsAndSkipToNextEpoch(0);

        vm.prank(owner2);
        vm.expectRevert(NotApprovedOrOwner.selector);
        aggregator.claimMany(distributors, tokenIds, maxWeeks);

        assertEq(rewardsToken1.balanceOf(owner1), 0);
        assertEq(rewardsToken2.balanceOf(owner1), 0);
        assertEq(rewardsToken3.balanceOf(owner1), 0);
        assertEq(rewardsToken1.balanceOf(owner2), 0);
        assertEq(rewardsToken2.balanceOf(owner2), 0);
        assertEq(rewardsToken3.balanceOf(owner2), 0);
    }

    function testClaimManyEmptyDistributors() public {
        IRewardsDistributor[] memory distributors = new IRewardsDistributor[](0);

        vm.startPrank(address(owner1));
        uint256 tokenId = escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        vm.prank(owner1);
        vm.expectRevert(RewardsClaimAggregator.EmptyList.selector);
        aggregator.claimMany(distributors, tokenIds, 1);
    }

    function testClaimManyEmptyTokenIds() public {
        IRewardsDistributor[] memory distributors = new IRewardsDistributor[](1);
        distributors[0] = distributor1;

        vm.startPrank(address(owner1));
        escrow.createLock(TOKEN_1M, MAXTIME);
        vm.stopPrank();

        // Let's move to next epoch so that locks are eligible for rewards
        vm.warp(block.timestamp + 1 weeks);

        _triggerRewardsAndSkipToNextEpoch(0);

        uint256[] memory tokenIds = new uint256[](0);
        vm.prank(owner1);
        vm.expectRevert(RewardsClaimAggregator.EmptyList.selector);
        aggregator.claimMany(distributors, tokenIds, 1);
    }

    // Helpers

    function _skipToNextEpoch(uint256 offset) internal {
        uint256 ts = block.timestamp;
        uint256 nextEpoch = ts - (ts % (1 weeks)) + (1 weeks);
        vm.warp(nextEpoch + offset);
    }

    function _triggerRewards(MockERC20 _rewardsToken, IRewardsDistributor _distributor, uint256 _amount) internal {
        _rewardsToken.mint(address(_distributor), _amount);
        vm.prank(rewardsSender);
        _distributor.checkpointToken();
    }

    function _triggerRewards() internal {
        _triggerRewards(rewardsToken1, distributor1, REWARD_AMOUNT);
        _triggerRewards(rewardsToken2, distributor2, REWARD_AMOUNT);
        _triggerRewards(rewardsToken3, distributor3, REWARD_AMOUNT);
    }

    function _triggerRewardsAndSkipToNextEpoch(uint256 offset) internal {
        _triggerRewards();
        _skipToNextEpoch(offset);
    }
}
