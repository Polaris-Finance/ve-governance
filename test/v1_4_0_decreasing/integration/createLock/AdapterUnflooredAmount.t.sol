/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {EscrowBase} from "../../base/EscrowBase.sol";

// Documents a known discrepancy between `LinearDecreasingCurve` and
// `EscrowIVotesAdapterDecreasing` for lock amounts that are not a
// multiple of the linear denominator (104 * 2 weeks):
// - The curve floors the amount (`getFlooredAmount`) so that the
//   voting power of a lock reaches EXACTLY zero at expiry.
// - The adapter's `_getBiasAndSlope` uses the raw, unfloored amount,
//   so the delegatee's checkpointed voting power for the same lock
//   is slightly higher and never decays to exactly zero.
// The difference is bounded by the denominator (104 * 2 weeks of
// token-wei), i.e. it is economically negligible, but the two
// contracts disagree on the voting power of the same lock.
contract TestAdapterUnflooredAmount is EscrowBase {
    address alice = address(1);

    // Not a multiple of the linear denominator, (10^20 is not divisible by 104 * 2 weeks = 125798400).
    uint256 constant AMOUNT = 100e18;

    /*//////////////////////////////////////////////////////////////
                        Helper
    //////////////////////////////////////////////////////////////*/

    // Creates a max-duration lock and delegates it to alice at the effective start.
    function _createMaxDurationLockAndDelegate()
        internal
        returns (uint256, uint256, uint256, uint256)
    {
        // Precondition: the curve must floor this amount to a smaller one.
        uint256 flooredAmount = curve.getFlooredAmount(AMOUNT);
        assertNotEq(flooredAmount, AMOUNT, "precondition: AMOUNT must have a flooring remainder");

        mintAndApproveEscrow(AMOUNT);

        // Max-duration lock: virtual start == effective start.
        uint256 tokenId = escrow.createLock(AMOUNT, MAX_TIME);
        uint256 start = escrow.locked(tokenId).start;
        uint256 end = start + MAX_TIME;

        // Warp to the effective start and delegate the lock to alice.
        vm.warp(start);
        ivotesAdapter.delegate(alice);

        return (tokenId, start, end, flooredAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        Tests
    //////////////////////////////////////////////////////////////*/

    function test_DelegatedVotes_ExceedCurvePower_ByFlooringRemainder() public {
        (uint256 tokenId, uint256 start,, uint256 flooredAmount) = _createMaxDurationLockAndDelegate();

        // The curve's token point is written with the FLOORED amount...
        TokenPoint memory tokenPoint = curve.tokenPointHistory(tokenId, 1);
        assertEq(tokenPoint.writtenTs, start);
        assertEq(tokenPoint.bias, flooredAmount * 1e18, "curve token point uses floored amount");

        // While the adapter's checkpoint for the delegatee is written with
        // the RAW amount (bias and slope both derived from `AMOUNT` directly).
        (int256 adapterBias, int256 adapterSlope, uint256 adapterWrittenTs) =
            ivotesAdapter.pointHistory(alice, ivotesAdapter.latestPointIndex(alice));
        assertEq(adapterWrittenTs, start);
        assertEq(adapterBias, int256(AMOUNT * 1e18), "adapter checkpoint uses raw amount");
        assertEq(adapterSlope, int256(AMOUNT) * 1e18 / linearDenominator, "adapter slope uses raw amount");

        // Consequence: at the same timestamp, the delegatee's voting power
        // exceeds the token's actual voting power by exactly the remainder
        // that the curve floored away.
        assertEq(escrow.votingPower(tokenId), flooredAmount, "curve power is the floored amount");
        assertEq(ivotesAdapter.getVotes(alice), AMOUNT, "delegatee votes are the raw amount");
        // flooredAmount != AMOUNT is checked in _createMaxDurationLockAndDelegate
    }

    function test_ExpiredLock_CurvePowerExactlyZero_AdapterBiasStaysPositive() public {
        (uint256 tokenId,, uint256 end,) = _createMaxDurationLockAndDelegate();

        vm.warp(end);

        // The curve reaches exactly zero at expiry
        assertEq(escrow.votingPower(tokenId), 0, "curve power must be exactly zero at expiry");

        // Advance alice's delegation checkpoint up to `end`
        ivotesAdapter.checkpointTransition(alice, MAX_TIME / checkpointInterval);

        // The adapter's checkpoint never reaches zero: since the raw amount
        // was used, `slope * maxTime` does not fully cancel the initial bias
        // and a rounding-dust bias is left over. The slope is consumed at
        // expiry, so this dust stays in the delegatee's checkpoint forever.
        (int256 biasAtEnd, int256 slopeAtEnd, uint256 writtenTs) =
            ivotesAdapter.pointHistory(alice, ivotesAdapter.latestPointIndex(alice));
        assertEq(writtenTs, end, "checkpoint advanced to expiry");
        assertEq(slopeAtEnd, 0, "slope consumed at expiry");
        assertGt(biasAtEnd, 0, "adapter bias never reaches zero (rounding dust)");

        // The dust is below fixed-point precision, so `getVotes` rounds it
        // down to zero — the discrepancy is invisible at token precision,
        // but it remains in the delegatee's checkpoint state.
        assertEq(ivotesAdapter.getVotes(alice), 0, "dust is invisible in getVotes");
    }
}
