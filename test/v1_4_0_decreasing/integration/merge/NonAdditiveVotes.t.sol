pragma solidity ^0.8.17;

import {EscrowBase} from "../../base/EscrowBase.sol";

import {
    IVotingEscrowDecreasing,
    IEscrowCurveDecreasing,
    IEscrowCurveTokenStorage,
    IEscrowCurveGlobalStorage
} from "../../versions.sol";

/// @notice Regression tests for `mergeDelegateVotes` with the non-additive decreasing curve.
/// @dev `LinearDecreasingCurve` floors every lock's amount independently so that locks reach
///      zero exactly at expiry, which means `vp(a) + vp(b) != vp(a + b)` in general. Merging
///      delegated locks must therefore re-checkpoint the voting power of the surviving lock
///      instead of assuming that the already checkpointed amounts add up.
///      The invariant asserted here is that the delegatee's voting power always equals the sum
///      of the escrow's voting power over the tokens that are delegated to it.
contract TestMerge_NonAdditiveVotes is
    IEscrowCurveTokenStorage,
    IEscrowCurveGlobalStorage,
    EscrowBase
{
    address bob = address(0x456);

    uint256 denominator;

    uint256 amount1;
    uint256 amount2;
    uint256 mergedAmount;

    uint256 tokenId1;
    uint256 tokenId2;

    function setUp() public override {
        super.setUp();

        denominator = uint256(-linearDenominator);

        // Amounts whose remainders add up to more than one `denominator`, so that flooring
        // them individually differs from flooring their sum.
        amount1 = (50e18 / denominator) * denominator + (denominator - 1);
        amount2 = (30e18 / denominator) * denominator + (denominator - 1);
        mergedAmount = amount1 + amount2;

        assertLt(
            getFlooredAmount(amount1) + getFlooredAmount(amount2),
            getFlooredAmount(mergedAmount)
        );

        mintAndApproveEscrow();

        // Start on a checkpoint boundary so that the points written by the escrow and by the
        // adapter are timestamped with the current timestamp rather than a future one.
        vm.warp(4 weeks);

        tokenId1 = escrow.createLock(amount1, MAX_TIME);
        tokenId2 = escrow.createLock(amount2, MAX_TIME);
    }

    /// @notice Both tokens delegated: the delegatee must hold the voting power of the merged
    ///         lock, not the sum of the individually floored amounts.
    function test_Merge_BothDelegated_NonAdditiveVotes() public {
        ivotesAdapter.delegate(bob);

        assertEq(ivotesAdapter.tokenIsDelegated(tokenId1), true);
        assertEq(ivotesAdapter.tokenIsDelegated(tokenId2), true);
        assertEq(ivotesAdapter.numberOfDelegatedTokens(address(this)), 2);

        vm.warp(block.timestamp + 2 weeks);

        uint256 votesBefore = ivotesAdapter.getVotes(bob);
        assertEq(votesBefore, escrow.votingPower(tokenId1) + escrow.votingPower(tokenId2));

        escrow.merge(tokenId1, tokenId2);

        assertEq(ivotesAdapter.tokenIsDelegated(tokenId1), false);
        assertEq(ivotesAdapter.tokenIsDelegated(tokenId2), true);
        assertEq(ivotesAdapter.numberOfDelegatedTokens(address(this)), 1);

        uint256 votesAfter = ivotesAdapter.getVotes(bob);
        assertEq(votesAfter, escrow.votingPower(tokenId2));
        // The scenario is only meaningful if merging actually changed the voting power,
        // which is exactly what the old "both delegated, nothing to checkpoint" path missed.
        assertGt(votesAfter, votesBefore);
    }

    /// @notice `from` delegated, `to` undelegated: `to` survives delegated and must carry the
    ///         voting power of the merged lock.
    function test_Merge_DelegatedFrom_UndelegatedTo_NonAdditiveVotes() public {
        _delegateTokens(tokenId1);

        assertEq(ivotesAdapter.tokenIsDelegated(tokenId1), true);
        assertEq(ivotesAdapter.tokenIsDelegated(tokenId2), false);

        vm.warp(block.timestamp + 2 weeks);

        uint256 votesBefore = ivotesAdapter.getVotes(bob);
        assertEq(votesBefore, escrow.votingPower(tokenId1));

        escrow.merge(tokenId1, tokenId2);

        assertEq(ivotesAdapter.tokenIsDelegated(tokenId1), false);
        assertEq(ivotesAdapter.tokenIsDelegated(tokenId2), true);
        assertEq(ivotesAdapter.numberOfDelegatedTokens(address(this)), 1);

        uint256 votesAfter = ivotesAdapter.getVotes(bob);
        assertEq(votesAfter, escrow.votingPower(tokenId2));
        assertGt(votesAfter, votesBefore);
    }

    /// @notice `from` undelegated, `to` delegated: the delegatee must gain `from`'s voting
    ///         power as measured on the merged lock.
    function test_Merge_UndelegatedFrom_DelegatedTo_NonAdditiveVotes() public {
        _delegateTokens(tokenId2);

        assertEq(ivotesAdapter.tokenIsDelegated(tokenId1), false);
        assertEq(ivotesAdapter.tokenIsDelegated(tokenId2), true);

        vm.warp(block.timestamp + 2 weeks);

        uint256 votesBefore = ivotesAdapter.getVotes(bob);
        assertEq(votesBefore, escrow.votingPower(tokenId2));

        escrow.merge(tokenId1, tokenId2);

        assertEq(ivotesAdapter.tokenIsDelegated(tokenId1), false);
        assertEq(ivotesAdapter.tokenIsDelegated(tokenId2), true);
        assertEq(ivotesAdapter.numberOfDelegatedTokens(address(this)), 1);

        uint256 votesAfter = ivotesAdapter.getVotes(bob);
        assertEq(votesAfter, escrow.votingPower(tokenId2));
        assertGt(votesAfter, votesBefore);
    }

    function _delegateTokens(uint256 _tokenId) internal {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId;

        ivotesAdapter.setDelegateAddress(bob);
        ivotesAdapter.delegate(tokenIds);
    }
}
