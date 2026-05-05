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

contract TestCreateLock_Supply is IEscrowCurveTokenStorage, IEscrowCurveGlobalStorage, EscrowBase {
    function setUp() public override {
        super.setUp();

        super.mintAndApproveEscrow();
    }

    function test_whenCreatingNewLock_no_existing_lock() public {
        // Avoid stating at zero
        vm.warp(block.timestamp + 2 * checkpointInterval);

        // Given: no prior locks existing
        // 1. total bias at block.timestamp must be amount + slope * (block.timestamp - weekStart)
        // 2. total bias at t must be amount + slope * (t - weekStart)
        // 3. total bias must be the same at end and end + `t` (i.e stops increasing)
        // 4. votingPower is correct.

        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);

        uint256 weekStartTs = weekStartTs(block.timestamp);
        uint256 endTs = getEndTimestamp(weekStartTs, weekStartTs);

        // 1, 2, 3
        assertTotalSupply(weekStartTs, biasFP(Lock_1_Amount, 0));
        assertTotalSupply(weekStartTs - 1, 0);
        int256 biasFp = biasFP(Lock_1_Amount, endTs - weekStartTs);
        if (biasFp < 0) biasFp = 0;
        assertTotalSupply(endTs, biasFp);
        assertTotalSupply(endTs + 10, biasFp);

        // 4
        assertVotingPower(tokenId, biasFP(Lock_1_Amount, block.timestamp - weekStartTs));
    }

    function test_whenCreatingNewLock_existingLock_at_same_timestamp() public {
        // Avoid stating at zero
        vm.warp(block.timestamp + 2 * checkpointInterval);

        _givenExistingLock();

        // Given: prior locks exists at the same timestamp
        // 1. total supply at block.timestamp must be both lock's bias till this point summed up.
        // 2. total supply before block.timestamp must be 0.
        // 3. total supply must be the same at end and end + `t` (i.e stops increasing)
        escrow.createLock(Lock_2_Amount, MAX_TIME);

        uint256 totalLockAmount = Lock_1_Amount + Lock_2_Amount;

        uint256 weekStartTs = weekStartTs(block.timestamp);
        uint256 endTs = getEndTimestamp(weekStartTs, block.timestamp, 0);

        // 1, 2, 3
        assertTotalSupply(weekStartTs, biasFP(totalLockAmount, 0));
        assertTotalSupply(weekStartTs - 1, 0);
        int256 biasFp = biasFP(totalLockAmount, endTs - weekStartTs);
        if (biasFp < 0) biasFp = 0;
        assertTotalSupply(endTs, biasFp);
        assertTotalSupply(endTs + 10, biasFp);
    }

    function test_whenCreatingNewLock_existingLock_at_previous_week() public {
        _givenExistingLock();

        // Given: prior locks exists in the previous week.
        // 1. total supply at block.timestamp must be both lock's bias till this point summed up.
        // 2. total supply before block.timestamp must only include first lock's bias till this moment.
        // 3. total supply shouldn't include the increase of first lock's bias after first lock's end.
        // 4. total supply shouldn't include the increase of second lock's bias after its end.
        vm.warp(block.timestamp + checkpointInterval);

        escrow.createLock(Lock_2_Amount, MAX_TIME);

        uint256 weekStartTs = weekStartTs(block.timestamp);

        int256 currentTotalBiasFP = biasFP(Lock_1_Amount, weekStartTs - Lock_1_start) +
            biasFP(Lock_2_Amount, 0);

        // 1, 2
        assertTotalSupply(weekStartTs, currentTotalBiasFP);
        assertTotalSupply(weekStartTs - 1, biasFP(Lock_1_Amount, weekStartTs - 1 - Lock_1_start));

        uint256 Lock_1_end = getEndTimestamp(Lock_1_start, Lock_1_ts);
        uint256 Lock_2_end = getEndTimestamp(weekStartTs, weekStartTs);

        int256 Lock_1_min = biasFP(Lock_1_Amount, Lock_1_end - Lock_1_start - 1);
        int256 Lock_2_min = biasFP(Lock_2_Amount, Lock_2_end - weekStartTs - 1);

        // 3
        assertTotalSupply(
            Lock_1_end - 1,
            Lock_1_min + biasFP(Lock_2_Amount, Lock_1_end - 1 - weekStartTs)
        );
        assertTotalSupply(
            Lock_1_end,
            biasFPCapped(Lock_2_Amount, Lock_1_end - weekStartTs)
        );
        assertTotalSupply(
            Lock_1_end + 10,
            biasFPCapped(Lock_2_Amount, Lock_1_end + 10 - weekStartTs)
        );

        // 4
        assertTotalSupply(Lock_2_end - 1, Lock_2_min);
        assertTotalSupply(Lock_2_end, 0);
        assertTotalSupply(Lock_2_end + 10, 0);
    }

    function test_whenCreatingNewLock_existingLock_ended() public {
        _givenExistingLock();

        // Given: prior locks exists and current timestamp is after its end date.
        // 1. total supply before currentTime must only include first lock's maxed out bias.
        // 2. total supply at block.timestamp must be both locked summed up, such that first lock's bias is constant reached max value.
        // 3. total supply must only include first lock's bias at first lock's end timestamp and shouldn't increase.
        // 4. total supply shouldn't include the increase of second lock's bias after its end.
        uint256 currentTime = block.timestamp + maxTime + 2 hours;
        vm.warp(currentTime);

        escrow.createLock(Lock_2_Amount, MAX_TIME);

        uint256 weekStartTs = weekStartTs(block.timestamp);
        uint256 currentTs = block.timestamp;

        uint256 Lock_1_end = getEndTimestamp(Lock_1_start, Lock_1_ts);
        uint256 Lock_2_end = getEndTimestamp(weekStartTs, currentTs);

        int256 Lock_1_min = biasFP(Lock_1_Amount, Lock_1_end - Lock_1_start - 1);
        int256 Lock_2_min = biasFP(Lock_2_Amount, Lock_2_end - weekStartTs - 1);

        int256 currentTotalBiasFP = biasFP(Lock_1_Amount, Lock_1_end - Lock_1_start) +
            biasFP(Lock_2_Amount, currentTs - weekStartTs);

        // 1, 2
        assertTotalSupply(currentTs, currentTotalBiasFP);
        assertTotalSupply(currentTs - 1, Lock_1_min);

        // 3
        assertTotalSupply(Lock_1_end - 1, Lock_1_min);
        assertTotalSupply(Lock_1_end + 10, Lock_1_min);

        // 4
        assertTotalSupply(Lock_2_end, Lock_2_min);
        assertTotalSupply(Lock_2_end, 0);
        assertTotalSupply(Lock_2_end + 10, 0);
    }
}
