pragma solidity ^0.8.17;

import {EscrowBase} from "../../base/EscrowBase.sol";

import {console2 as console} from "forge-std/console2.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {Multisig, MultisigSetup} from "@aragon/multisig/src/MultisigSetup.sol";
import {MockERC20} from "@mocks/MockERC20.sol";

import {ProxyLib} from "@libs/ProxyLib.sol";

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
    IEscrowCurveGlobalStorage
} from "../../versions.sol";

contract TestSplit_Points is IEscrowCurveTokenStorage, IEscrowCurveGlobalStorage, EscrowBase {
    function setUp() public override {
        super.setUp();

        super.mintAndApproveEscrow();

        escrow.setEnableSplit(address(this), true);
    }

    function test_Split_TokenNotMature() public {
        // 1. the tokenId's point must become 0
        // 2. we should have one new tokenIds with `value` and `Lock_1_Amount - value` with old token with their according bias and slope.
        // 3. bias and slope on the latest global point must include the same slope and bias as it was originally before splitting.
        // 4. slope changes must still include the original token's slope at the same original end.
        uint256 value = 20e18;
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        uint256 weekStartTs1 = weekStartTs(block.timestamp);
        uint256 endTs = weekStartTs1 + maxTime;

        // Still warp just to ensure that we changed the current timestamp
        // but not wrap after the end.
        uint256 weekStartTs2 = weekStartTs(block.timestamp + checkpointInterval);
        vm.warp(block.timestamp + checkpointInterval);
    
        escrow.split(tokenId, value);

        int256 slope1 = slopeFP(Lock_1_Amount - value);
        int256 slope2 = slopeFP(value);

        uint256 elapsed = weekStartTs2 - weekStartTs1;

        // 1
        assertTokenPoint(
            tokenId,
            2,
            biasFP(Lock_1_Amount - value, elapsed),
            slope1,
            weekStartTs2
        );

        // 2
        assertTokenPoint(2, 1, biasFP(value, elapsed), slope2, weekStartTs2);

        // 3
        assertGlobalPoint(
            2,
            biasFP(Lock_1_Amount, elapsed),
            slopeFP(Lock_1_Amount),
            weekStartTs2
        );

        // 4
        assertEq(slopeChanges(endTs), slope1 + slope2);
    }

    function test_Split_TokenAlreadyMature() public {
        // 1. the tokenId's point must become 0
        // 2. we should have one new tokenId with `value` and current token with `Lock_1_Amount - value` with their according bias and slope.
        // 3. slope on the last global point must be 0 as it was stored after both tokens were mature. bias must be maxed out.
        // 4. slope changes must still include the original token's slope at the same original end.
        uint256 value = 20e18;
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        uint256 weekStartTs1 = weekStartTs(block.timestamp);
        uint256 endTs = weekStartTs1 + maxTime;

        // warp after the token end so it's mature.
        vm.warp(endTs + 1 hours);

        escrow.split(tokenId, value);
        uint256 elapsed = endTs - weekStartTs1;

        // 1
        assertTokenPoint(
            tokenId,
            2,
            biasFPCapped(Lock_1_Amount - value, elapsed),
            0,
            endTs
        );

        // 2
        assertTokenPoint(2, 1, biasFPCapped(value, elapsed), 0, endTs);

        // 3
        uint256 lastIndex = (block.timestamp - Lock_1_start) / checkpointInterval + 1;
        assertGlobalPoint(lastIndex, biasFPCapped(Lock_1_Amount, elapsed), 0, endTs);

        // 4
        assertEq(slopeChanges(endTs), slopeFP(Lock_1_Amount));
    }

    function testFuzz_Split(
        uint184 _lock1Amount,
        uint184 _splitValue,
        uint48 _fromLockTime,
        uint184 _splitTime
    ) public {
        (_fromLockTime, _splitTime) = boundLockCreationFuzzTimes(_fromLockTime, _splitTime);

        // Split requirements to work with.
        vm.assume(_lock1Amount > 0 && _splitValue > 0);
        vm.assume(_splitValue < _lock1Amount);
        uint256 minDeposit = escrow.minDeposit();
        vm.assume(_splitValue >= minDeposit && _lock1Amount - _splitValue >= minDeposit);

        mintAndApproveEscrow(uint256(_lock1Amount));

        // Create 2 locks on fuzzed times and
        // merge them on fuzzed time as well.
        vm.warp(_fromLockTime);
        uint256 from = escrow.createLock(_lock1Amount, MAX_TIME);
        vm.warp(_splitTime);
        escrow.split(from, _splitValue);

        uint256 fromLockWeekTs = weekStartTs(_fromLockTime);
        uint256 fromLockEnd = fromLockWeekTs + maxTime;
        uint256 splitWeekTs = weekStartTs(_splitTime);

        {
            int256 bias1;
            int256 slope1;
            int256 bias2;
            int256 slope2;
            if (_splitTime >= fromLockEnd) {
                bias1 = biasFPCapped(_lock1Amount - _splitValue, maxTime);
                bias2 = biasFPCapped(_splitValue, maxTime);
            } else {
                bias1 = biasFPCapped(_lock1Amount - _splitValue, splitWeekTs - fromLockWeekTs);
                bias2 = biasFPCapped(_splitValue, splitWeekTs - fromLockWeekTs);
                slope1 = slopeFP(_lock1Amount - _splitValue);
                slope2 = slopeFP(_splitValue);
            }

            assertTokenPoint(
                from,
                // If the dates match, it should use
                // a single block/record for gas efficiency,
                // otherwise 2.
                splitWeekTs == fromLockWeekTs ? 1 : 2,
                bias1,
                slope1,
                splitWeekTs
            );

            assertTokenPoint(2, 1, bias2, slope2, splitWeekTs);
        }

        {
            int256 bias;
            int256 slope;
            if (_splitTime >= fromLockEnd) {
                bias = biasFPCapped(_lock1Amount, maxTime);
            } else {
                bias = biasFPCapped(_lock1Amount, splitWeekTs - fromLockWeekTs);
                slope = slopeFP(_lock1Amount);
            }

            assertGlobalPoint(
                expectedIndex(_fromLockTime, _splitTime, _splitTime),
                bias,
                slope,
                splitWeekTs
            );
        }

        assertEq(slopeChanges(fromLockEnd), slopeFP(_lock1Amount));
    }
}
