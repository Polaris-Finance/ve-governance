pragma solidity ^0.8.17;

import {EscrowBase} from "../../base/EscrowBase.sol";

/// @notice Locks are floored to a multiple of the curve's linear denominator on
///         deposit, which makes the decreasing curve exactly additive:
///         `vp(a) + vp(b) == vp(a + b)`. The delegation checkpoints rely on that,
///         so merging two delegated tokens must not change the delegatee's votes.
contract TestMerge_Additivity is EscrowBase {
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    /// @dev The curve's flooring step.
    uint256 step;

    function setUp() public override {
        super.setUp();
        step = uint256(-linearDenominator);
    }

    function _setupTwoFlooredLocksAndDelegateThem(address delegator, address delegatee)
        internal
        returns (uint256 lock1, uint256 lock2)
    {
        // Two deposits that are deliberately *not* multiples of the flooring step.
        // With unfloored amounts the curve would not be additive here:
        // floor(1.5d + 1.5d) == 3d > floor(1.5d) + floor(1.5d) == 2d.
        uint256 requested = step + step / 2;

        token.mint(delegator, 2 * requested);

        vm.startPrank(delegator);
        {
            token.approve(address(escrow), 2 * requested);
            lock1 = escrow.createLock(requested, MAX_TIME);
            lock2 = escrow.createLock(requested, MAX_TIME);
        }
        vm.stopPrank();

        // Move past the token checkpoint so the locks are active.
        vm.warp(block.timestamp + 2 weeks);

        vm.prank(delegator);
        ivotesAdapter.delegate(delegatee);

        // Move past the delegation checkpoint.
        vm.warp(block.timestamp + 2 weeks);
    }

    // Verify the assumptions that the other tests rely on
    function test_SetUp() public {
        (uint256 lock1, uint256 lock2) = _setupTwoFlooredLocksAndDelegateThem({delegator: alice, delegatee: bob});

        // Only the aligned part gets locked, the remainder stays in the wallet.
        assertEq(uint256(escrow.locked(lock1).amount), step, "lock1 should be floored");
        assertEq(uint256(escrow.locked(lock2).amount), step, "lock2 should be floored");

        // Each of the 2 locks should have left a remainder of step / 2
        assertEq(token.balanceOf(alice), step, "remainders should have stayed in the wallet");

        assertTrue(ivotesAdapter.tokenIsDelegated(lock1), "lock1 should be delegated");
        assertTrue(ivotesAdapter.tokenIsDelegated(lock2), "lock2 should be delegated");
        assertEq(ivotesAdapter.numberOfDelegatedTokens(alice), 2, "alice should have 2 delegated locks");
    }

    function test_DecreasingCurveIsAdditiveAcrossLocks() public {
        (uint256 lock1, uint256 lock2) = _setupTwoFlooredLocksAndDelegateThem({delegator: alice, delegatee: bob});

        assertEq(
            ivotesAdapter.getVotes(bob),
            escrow.votingPower(lock1) + escrow.votingPower(lock2),
            "delegatee votes are the sum of the tokens' voting power"
        );
    }

    function test_Merge_OfBothDelegatedTokens_KeepsVotesInSync() public {
        (uint256 from, uint256 to) = _setupTwoFlooredLocksAndDelegateThem({delegator: alice, delegatee: bob});

        vm.prank(alice);
        escrow.merge(from, to);

        // The surviving token carries the sum of two aligned amounts, so the
        // delegatee's votes have to stay in sync with it.
        assertEq(uint256(escrow.locked(to).amount), 2 * step, "merged amount is aligned");

        // Move past the checkpoint written by the merge.
        vm.warp(block.timestamp + 2 weeks);

        // Both the curve and the delegation checkpoints must describe the merged
        // lock. With unaligned amounts the delegatee would be stuck at
        // floor(a) + floor(b) while the lock holds a + b (here 2d vs 3d).
        uint256 expected = bias(2 * step, block.timestamp - escrow.locked(to).start);
        assertEq(escrow.votingPower(to), expected, "curve power of the merged lock");
        assertEq(ivotesAdapter.getVotes(bob), expected, "delegatee votes of the merged lock");
    }
}
