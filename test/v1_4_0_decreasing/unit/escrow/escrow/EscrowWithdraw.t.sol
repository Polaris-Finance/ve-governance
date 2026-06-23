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

        // Cannot withdraw even if it's not active until start of next checkpoint
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId);

        // Create again
        token.approve(address(escrow), 100e18);
        tokenId = escrow.createLock(100e18, MAX_TIME);
        nftLock.approve(address(escrow), tokenId);

        // Not expired
        vm.warp(weekStartTs(block.timestamp));
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId);

        // Not expired
        vm.warp(block.timestamp + 1 weeks);
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId);

        // Finally expired
        vm.warp(block.timestamp + MAX_TIME);
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
}
