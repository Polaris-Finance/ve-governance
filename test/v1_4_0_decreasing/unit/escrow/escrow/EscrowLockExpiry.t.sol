pragma solidity ^0.8.17;

import {EscrowBase} from "../../../base/EscrowBase.sol";

import {VotingEscrow} from "../../../versions.sol";

contract TestLockExpiry is EscrowBase {
    /// A token id that is never minted by any test.
    uint256 internal constant NON_EXISTENT_TOKEN_ID = type(uint256).max;

    function setUp() public override {
        super.setUp();

        mintAndApproveEscrow();
    }

    // Non-existent locks
    function test_isLockCurrentlyExpired_returnsTrueForNonExistentLock() public {
        // No lock was ever created for this token id, so `_locked` is zeroed.
        assertTrue(escrow.isLockCurrentlyExpired(NON_EXISTENT_TOKEN_ID));
    }

    function test_isLockExpiredAtNextCheckpoint_returnsTrueForNonExistentLock() public {
        assertTrue(escrow.isLockExpiredAtNextCheckpoint(NON_EXISTENT_TOKEN_ID));
    }

    // Burnt locks

    /// Creates a lock, lets it fully expire, and withdraws (burns) it. After
    /// `withdraw`, the `_locked` entry is cleared to zeros.
    function _createAndBurnLock() internal returns (uint256 tokenId) {
        uint256 deposit = getFlooredAmount(100e18);

        token.mint(address(this), deposit);
        token.approve(address(escrow), deposit);

        tokenId = escrow.createLock(deposit, MAX_TIME);

        // Warp past the lock's end so it is expired and can be withdrawn.
        uint256 lockStart = weekStartTs(block.timestamp);
        vm.warp(lockStart + MAX_TIME + 1);

        nftLock.approve(address(escrow), tokenId);
        escrow.withdraw(tokenId);

        // Sanity: the NFT has been burnt.
        assertEq(nftLock.balanceOf(address(this)), 0);
    }

    function test_isLockCurrentlyExpired_returnsTrueForBurntLock() public {
        uint256 tokenId = _createAndBurnLock();

        // The lock entry was cleared to zeros during `withdraw`.
        assertTrue(escrow.isLockCurrentlyExpired(tokenId));
    }

    function test_isLockExpiredAtNextCheckpoint_returnsTrueForBurntLock() public {
        uint256 tokenId = _createAndBurnLock();

        assertTrue(escrow.isLockExpiredAtNextCheckpoint(tokenId));
    }
}
