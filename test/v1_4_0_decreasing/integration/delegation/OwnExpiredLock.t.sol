// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {EscrowBase} from "../../base/EscrowBase.sol";

/// No attacker involved: a holder whose own lock has expired and who has not withdrawn it yet.
contract TestOwnExpiredLock is EscrowBase {
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public override {
        super.setUp();
        vm.warp(block.timestamp + MAX_TIME + 1 weeks);
    }

    function test_ownExpiredLockDoesNotBlockChangingDelegate() public {
        mintAndApproveEscrow(alice, 100e18);

        vm.prank(alice);
        uint256 tokenId = escrow.createLock(100e18, 4 weeks);

        vm.warp(block.timestamp + 6 weeks);
        assertTrue(escrow.isLockCurrentlyExpired(tokenId), "her own lock has expired");

        vm.prank(alice);
        ivotesAdapter.delegate(bob);

        assertEq(ivotesAdapter.delegates(alice), bob);
    }
}
