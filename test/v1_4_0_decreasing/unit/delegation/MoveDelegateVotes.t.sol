pragma solidity ^0.8.17;

import {Base, ILockedBalanceIncreasing, VotingEscrow} from "./Base.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";

contract TestMoveDelegateVotes is Base {
    function setUp() public override {
        super.setUp();
    }

    function test_shouldRevertIfPaused() public {
        dg.pause();

        vm.expectRevert("Pausable: paused");
        dg.moveDelegateVotes(alice, bob, 1, ILockedBalanceIncreasing.LockedBalance(0, 0));
    }

    function testRevert_IfNotCalledByEscrow() public {
        vm.expectRevert(OnlyEscrow.selector);
        dg.moveDelegateVotes(alice, bob, 1, ILockedBalanceIncreasing.LockedBalance(0, 0));
    }

    function test_OnlyUpdatesFromDelegateeWhenToIsNotSet() public {
        address tokenOwner = address(567);
        uint256 start = weekStartTs(block.timestamp);

        uint256 amount1 = getFlooredAmount(10e18);
        uint256 amount2 = getFlooredAmount(15e18);
        {
            // make Alice delegate with tokenId = 1 and 2
            vm.startPrank(tokenOwner);
            uint256[] memory ids = getIds(1, 2);
            _mockOwnedTokens(tokenOwner, ids);
            _mockLocked(ids[0], amount1, start);
            _mockLocked(ids[1], amount2, start);
            dg.delegate(alice);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + 1 weeks);

        uint256 token1Bias = bias(amount1, block.timestamp - start);
        uint256 token2Bias = bias(amount2, block.timestamp - start);
        uint256 total = token1Bias + token2Bias;

        assertEq(dg.getVotes(alice), total);
        assertEq(dg.getVotes(bob), 0);

        vm.startPrank(address(escrow));
        {
            uint256[] memory tokenIds = new uint256[](1);
            tokenIds[0] = 1;
            vm.expectEmit();
            emit TokensUndelegated(tokenOwner, alice, tokenIds);
            dg.moveDelegateVotes(tokenOwner, bob, 1, VotingEscrow(address(escrow)).locked(1));
        }
        vm.stopPrank();
        vm.warp(block.timestamp + 1 weeks);

        token2Bias = bias(amount2, block.timestamp - start);
        assertEq(dg.getVotes(alice), token2Bias);
        assertEq(dg.getVotes(bob), 0);
    }

    function test_OnlyUpdatesToDelegateeWhenFromIsNotSet() public {
        address tokenReceiver = address(567);

        vm.startPrank(tokenReceiver);
        dg.setAutoDelegationDisabled(true);
        dg.setDelegateAddress(bob);
        vm.stopPrank();

        uint256 amount = getFlooredAmount(10e18);
        _mockLocked(1, amount, weekStartTs((block.timestamp)));

        assertEq(dg.getVotes(bob), 0);

        vm.startPrank(address(escrow));
        {
            uint256[] memory tokenIds = new uint256[](1);
            tokenIds[0] = 1;
            vm.expectEmit();
            emit TokensDelegated(tokenReceiver, bob, tokenIds);
            dg.moveDelegateVotes(sender, tokenReceiver, 1, VotingEscrow(address(escrow)).locked(1));
        }
        vm.stopPrank();
        vm.warp(block.timestamp + 1 weeks);

        assertEq(dg.getVotes(bob), bias(amount, block.timestamp - previousCheckpointTs(block.timestamp)));
    }

    function test_UpdateBothDelegates() public {
        address tokenOwner = address(567);
        address tokenReceiver = address(678);

        uint256 amount1 = getFlooredAmount(10e18);
        uint256 amount2 = getFlooredAmount(15e18);
        uint256 start = weekStartTs((block.timestamp));
        _mockLocked(1, amount1, start);
        _mockLocked(2, amount2, start);

        {
            // make Alice delegatee with tokenId = 1 and 2
            vm.startPrank(tokenOwner);
            uint256[] memory ids = getIds(1, 2);
            _mockOwnedTokens(tokenOwner, ids);
            _mockLocked(ids[0], amount1, start);
            _mockLocked(ids[1], amount2, start);
            dg.delegate(alice);
            vm.stopPrank();
        }

        {
            // make Bob delegatee
            vm.startPrank(tokenReceiver);
            dg.setAutoDelegationDisabled(true);
            dg.setDelegateAddress(bob);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + 1 weeks);

        uint256 token1Bias = bias(amount1, block.timestamp - start);
        uint256 token2Bias = bias(amount2, block.timestamp - start);
        uint256 total = token1Bias + token2Bias;

        assertEq(dg.getVotes(alice), total);
        assertEq(dg.getVotes(bob), 0);

        vm.startPrank(address(escrow));
        {
            uint256[] memory tokenIds = new uint256[](1);
            tokenIds[0] = 1;
            vm.expectEmit();
            emit TokensUndelegated(tokenOwner, alice, tokenIds);
            vm.expectEmit();
            emit TokensDelegated(tokenReceiver, bob, tokenIds);
            dg.moveDelegateVotes(
                tokenOwner,
                tokenReceiver,
                1,
                VotingEscrow(address(escrow)).locked(1)
            );
        }
        vm.stopPrank();
        vm.warp(block.timestamp + 1 weeks);
        token1Bias = bias(amount1, block.timestamp - start);
        token2Bias = bias(amount2, block.timestamp - start);

        assertEq(dg.getVotes(alice), token2Bias);
        assertEq(dg.getVotes(bob), token1Bias);
    }
}
