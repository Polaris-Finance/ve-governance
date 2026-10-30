/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {EscrowBase} from "../../base/EscrowBase.sol";

// Makes sure that EscrowIVotesAdapterDecreasing is consistent with LinearDecreasingCurve
// and also uses floored amount for bias and slope
contract TestAdapterFlooredAmount is EscrowBase {
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

        // The curve's token point is written with the floored amount
        TokenPoint memory tokenPoint = curve.tokenPointHistory(tokenId, 1);
        assertEq(tokenPoint.writtenTs, start);
        assertEq(tokenPoint.bias, flooredAmount * 1e18, "curve token point uses floored amount");

        // The adapter's checkpoint for the delegatee is also written with
        // the RAW amount (bias and slope both derived from `AMOUNT` directly).
        (int256 adapterBias, int256 adapterSlope, uint256 adapterWrittenTs) =
            ivotesAdapter.pointHistory(alice, ivotesAdapter.latestPointIndex(alice));
        assertEq(adapterWrittenTs, start);
        assertEq(adapterBias, int256(flooredAmount * 1e18), "adapter checkpoint uses floored amount");
        assertEq(adapterSlope, int256(flooredAmount) * 1e18 / linearDenominator, "adapter slope uses raw amount");

        // Consequence: at the same timestamp, the delegatee's voting power
        // equals the token's actual voting power
        assertEq(escrow.votingPower(tokenId), flooredAmount, "curve power is the floored amount");
        assertEq(ivotesAdapter.getVotes(alice), flooredAmount, "delegatee votes are the raw amount");
        // flooredAmount != AMOUNT is checked in _createMaxDurationLockAndDelegate
    }

    function test_ExpiredLock_CurvePowerExactlyZero_AdapterBiasStaysPositive() public {
        (uint256 tokenId,, uint256 end,) = _createMaxDurationLockAndDelegate();

        vm.warp(end);

        // The curve reaches exactly zero at expiry
        assertEq(escrow.votingPower(tokenId), 0, "curve power must be exactly zero at expiry");

        // Advance alice's delegation checkpoint up to `end`
        ivotesAdapter.checkpointTransition(alice, MAX_TIME / checkpointInterval);

        // The adapter's checkpoint also reaches zero
        (int256 biasAtEnd, int256 slopeAtEnd, uint256 writtenTs) =
            ivotesAdapter.pointHistory(alice, ivotesAdapter.latestPointIndex(alice));
        assertEq(writtenTs, end, "checkpoint advanced to expiry");
        assertEq(slopeAtEnd, 0, "slope consumed at expiry");
        assertEq(biasAtEnd, 0, "adapter bias reaches zero at expiry");

        // `getVotes` is zero too
        assertEq(ivotesAdapter.getVotes(alice), 0, "getVotes is zero");
    }
}
