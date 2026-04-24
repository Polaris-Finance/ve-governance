pragma solidity ^0.8.17;

import {EscrowBase, IAddressGaugeVote} from "../../base/EscrowBase.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {
    Clock,
    IClock,
    Lock,
    VotingEscrow,
    IVotingEscrowDecreasing,
    IEscrowCurveDecreasing,
    IVotingEscrowDecreasing,
    IVotingEscrowCoreErrors,
    IMerge,
    ISplit,
    ILockedBalanceIncreasing,
    IEscrowCurveGlobalStorage,
    IEscrowCurveTokenStorage,
    IEscrowCurveGlobalStorage,
    EscrowIVotesAdapter,
    IEscrowIVotesAdapterErrorsAndEvents,
    IGaugeVote
} from "../../versions.sol";

import {console2} from "forge-std/console2.sol";

contract ERC721ReceiverMock is IERC721Receiver {
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract TestWithdrawal is IEscrowCurveTokenStorage, IEscrowCurveGlobalStorage, EscrowBase {
    address gauge = address(0x777);

    function setUp() public override {
        super.setUp();

        vm.warp(2 weeks + 1 hours + 1);
        voter.createGauge(gauge, "metadata");
        escrow.enableSplit();
    }

    struct User {
        address user;
        uint96 amount;
        bool withdraws;
        bool delegateToOther;
        address delegatee;
    }

    function slopeChanges(uint256 _tokenId) internal view override returns (int256) {
        return super.slopeChanges(weekStartTs(escrow.locked(_tokenId).start) + maxTime);
    }

    function slopeOfToken(uint256 _tokenId) internal view returns (int256) {
        return slopeFP(escrow.locked(_tokenId).amount);
    }

    function testRevert_IfWithdrawSameBlockWithTwoTokens() public {
        super.mintAndApproveEscrow();

        vm.warp(1);
        uint256 tokenId1 = escrow.createLock(10e18, MAX_TIME);

        vm.warp(2);
        uint256 tokenId2 = escrow.createLock(15e18, MAX_TIME);

        escrow.merge(tokenId2, tokenId1);
        nftLock.approve(address(escrow), tokenId1);

        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId1);
    }

    function testRevert_IfWithdrawSameBlockWithThreeTokens() public {
        super.mintAndApproveEscrow();

        vm.warp(1);
        uint256 tokenId1 = escrow.createLock(10e18, MAX_TIME);
        uint256 tokenId2 = escrow.createLock(10e18, MAX_TIME);

        vm.warp(2);
        uint256 tokenId3 = escrow.createLock(15e18, MAX_TIME);

        escrow.merge(tokenId3, tokenId2);
        escrow.merge(tokenId2, tokenId1);

        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId1);
    }

    function testRevert_WithdrawIfLockWasCreatedInPreviousBlock() public {
        super.mintAndApproveEscrow();

        vm.warp(1);
        uint256 tokenId1 = escrow.createLock(10e18, MAX_TIME);
        uint256 tokenId2 = escrow.createLock(10e18, MAX_TIME);
        uint256 tokenId3 = escrow.createLock(15e18, MAX_TIME);

        vm.warp(2);

        escrow.merge(tokenId3, tokenId2);
        escrow.merge(tokenId2, tokenId1);

        nftLock.approve(address(escrow), tokenId1);

        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId1);
    }

    /*//////////////////////////////////////////////////////////////
                        ATOMIC WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     *  | createLock | merge | split | withdraw | allowed |
     *  | ---------- | ----- | ----- | -------- | ------- |
     *  | ✅         | ❌    | ❌    | ✅       | ❌      |
     *  | ✅         | ✅    | ❌    | ✅       | ❌      |
     *  | ✅         | ❌    | ✅    | ✅       | ❌      |
     *  | ✅         | ✅    | ✅    | ✅       | ❌      |
     *  | ❌         | ✅    | ❌    | ✅       | ❌      |
     *  | ❌         | ❌    | ✅    | ✅       | ❌      |
     *  | ❌         | ✅    | ✅    | ✅       | ❌      |
     *
     *  These are allowed but we are only checking withdrawals
     *
     *  | ✅         | ✅    | ❌    | ❌       | ✅      |
     *  | ✅         | ❌    | ✅    | ❌       | ✅      |
     *  | ✅         | ✅    | ✅    | ❌       | ✅      |
     **/

    // Row 1: createLock ✅, merge ❌, split ❌, withdraw ✅ => Should revert
    function testRevert_AtomicWithdrawal_CreateLockOnly() public {
        super.mintAndApproveEscrow();

        uint256 tokenId = escrow.createLock(10e18, MAX_TIME);
        nftLock.approve(address(escrow), tokenId);

        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId);
    }

    // Row 2: createLock ✅, merge ✅, split ❌, withdraw ✅ => Should revert
    function testRevert_AtomicWithdrawal_CreateLockAndMerge() public {
        super.mintAndApproveEscrow();

        // Create first token in previous block
        vm.warp(1);
        uint256 existingTokenId = escrow.createLock(5e18, MAX_TIME);

        // Create and merge in current block
        vm.warp(2);
        uint256 newTokenId = escrow.createLock(10e18, MAX_TIME);
        escrow.merge(newTokenId, existingTokenId);
        nftLock.approve(address(escrow), existingTokenId);

        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(existingTokenId);
    }

    // Row 3: createLock ✅, merge ❌, split ✅, withdraw ✅ => Should revert
    function testRevert_AtomicWithdrawal_CreateLockAndSplit() public {
        super.mintAndApproveEscrow();

        uint256 tokenId = escrow.createLock(20e18, MAX_TIME);
        uint256 splitTokenId = escrow.split(tokenId, 10e18);
        nftLock.approve(address(escrow), tokenId);

        // Try to withdraw the original token
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId);

        // Also try to withdraw the split token
        nftLock.approve(address(escrow), splitTokenId);
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(splitTokenId);
    }

    // Row 4: createLock ✅, merge ✅, split ✅, withdraw ✅ => Should revert
    function testRevert_AtomicWithdrawal_CreateLockMergeAndSplit() public {
        super.mintAndApproveEscrow();

        // Create first token in previous block
        vm.warp(1);
        uint256 existingTokenId = escrow.createLock(5e18, MAX_TIME);

        // Create, merge and split in current block
        vm.warp(2);
        uint256 newTokenId = escrow.createLock(20e18, MAX_TIME);
        escrow.merge(newTokenId, existingTokenId);
        uint256 splitTokenId = escrow.split(existingTokenId, 10e18);

        // Try to withdraw any of the tokens
        nftLock.approve(address(escrow), existingTokenId);
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(existingTokenId);

        nftLock.approve(address(escrow), splitTokenId);
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(splitTokenId);

        vm.expectRevert("ERC721: invalid token ID");
        nftLock.approve(address(escrow), newTokenId);
        vm.expectRevert("ERC721: invalid token ID");
        escrow.withdraw(newTokenId);
    }

    // Row 5: createLock ❌, merge ✅, split ❌, withdraw ✅ => Should revert
    function test_AtomicWithdrawal_MergeOnly() public {
        super.mintAndApproveEscrow();

        // Create tokens in previous block
        vm.warp(1);
        uint256 tokenId1 = escrow.createLock(10e18, MAX_TIME);
        uint256 tokenId2 = escrow.createLock(5e18, MAX_TIME);

        // Merge and withdraw in current block
        vm.warp(2);
        escrow.merge(tokenId2, tokenId1);
        nftLock.approve(address(escrow), tokenId1);

        // Should revert - not expired yet
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId1);
        assertGt(escrow.votingPower(tokenId1), 0);
    }

    // Row 6: createLock ❌, merge ❌, split ✅, withdraw ✅ => Should revert
    function test_AtomicWithdrawal_SplitOnly() public {
        super.mintAndApproveEscrow();

        // Create token in previous block
        vm.warp(1);
        uint256 tokenId = escrow.createLock(20e18, MAX_TIME);

        // Split and withdraw in current block
        vm.warp(2);
        uint256 splitTokenId = escrow.split(tokenId, 10e18);

        // Should revert - not expired yet
        nftLock.approve(address(escrow), tokenId);
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId);
        assertGt(escrow.votingPower(tokenId), 0);

        // Also test withdrawing the split token
        nftLock.approve(address(escrow), splitTokenId);
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(splitTokenId);
        assertGt(escrow.votingPower(splitTokenId), 0);
    }

    // Row 7: createLock ❌, merge ✅, split ✅, withdraw ✅ => Should revert
    function test_AtomicWithdrawal_MergeAndSplit() public {
        super.mintAndApproveEscrow();

        // Create tokens in previous block
        vm.warp(1);
        uint256 tokenId1 = escrow.createLock(15e18, MAX_TIME);
        uint256 tokenId2 = escrow.createLock(5e18, MAX_TIME);

        // Merge, split and withdraw in current block
        vm.warp(2);
        escrow.merge(tokenId2, tokenId1);
        uint256 splitTokenId = escrow.split(tokenId1, 10e18);

        nftLock.approve(address(escrow), tokenId1);

        // Should revert - not expired yet
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(tokenId1);
        assertGt(escrow.votingPower(tokenId1), 0);

        // Also test withdrawing the split token
        nftLock.approve(address(escrow), splitTokenId);
        vm.expectRevert(CannotWithdrawUntilExpiry.selector);
        escrow.withdraw(splitTokenId);
        assertGt(escrow.votingPower(splitTokenId), 0);

        // Also test that the merged tokenId2 cannot be withdrawn
        vm.expectRevert("ERC721: invalid token ID");
        nftLock.approve(address(escrow), tokenId2);
        vm.expectRevert("ERC721: invalid token ID");
        escrow.withdraw(tokenId2);
    }
}
