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

contract TestModifyLock_Supply is IEscrowCurveTokenStorage, IEscrowCurveGlobalStorage, EscrowBase {
    function setUp() public override {
        super.setUp();

        super.mintAndApproveEscrow();
    }

    function test_lockPermanent_updatesTotalSupply() public {
        vm.warp(2 weeks + 1 hours + 1);
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        uint256 createWeekStart = weekStartTs(block.timestamp); // 3 weeks

        // Move 1 week forward and lock permanent
        vm.warp(block.timestamp + 1 weeks);
        uint256 permanentWeekStart = weekStartTs(block.timestamp); // 4 weeks
        escrow.lockPermanent(tokenId);

        // Supply immediately after locking permanent should be maxed out
        assertTotalSupply(permanentWeekStart, biasFP(Lock_1_Amount, 0));

        // Supply should not decrease after permanent lock
        vm.warp(permanentWeekStart + 1 weeks);
        assertTotalSupply(block.timestamp, biasFP(Lock_1_Amount, 0));

        // Supply at old end should now be maxed out instead of zero
        assertTotalSupply(createWeekStart + maxTime, biasFP(Lock_1_Amount, 0));
    }

    function test_unlockPermanent_updatesTotalSupply() public {
        vm.warp(2 weeks + 1 hours + 1);
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        uint256 createWeekStart = weekStartTs(block.timestamp); // 3 weeks

        // Make permanent
        vm.warp(block.timestamp + 1 weeks);
        escrow.lockPermanent(tokenId);

        // Unlock permanent
        vm.warp(block.timestamp + 1 weeks);
        uint256 unlockWeekStart = weekStartTs(block.timestamp); // 5 weeks
        escrow.unlockPermanent(tokenId);

        // Supply should start decreasing again from max bias
        assertTotalSupply(unlockWeekStart, biasFP(Lock_1_Amount, 0));

        // After some time, supply should have decreased
        vm.warp(unlockWeekStart + 1 weeks);
        assertTotalSupply(block.timestamp, biasFP(Lock_1_Amount, 1 weeks));

        // At new end, supply should be zero
        assertTotalSupply(unlockWeekStart + maxTime, 0);
    }

    function test_increaseAmount_updatesTotalSupply() public {
        vm.warp(2 weeks + 1 hours + 1);
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        uint256 createWeekStart = weekStartTs(block.timestamp); // 3 weeks

        vm.warp(block.timestamp + 1 weeks);
        uint256 increaseWeekStart = weekStartTs(block.timestamp); // 4 weeks
        escrow.increaseAmount(tokenId, Lock_2_Amount);

        uint256 totalAmount = Lock_1_Amount + Lock_2_Amount;

        // At increase time, supply should reflect 1 week elapsed on increased amount
        assertTotalSupply(increaseWeekStart, biasFP(totalAmount, 1 weeks));

        // After another week
        vm.warp(increaseWeekStart + 1 weeks);
        assertTotalSupply(block.timestamp, biasFP(totalAmount, 2 weeks));

        // At end, supply should be zero
        assertTotalSupply(createWeekStart + maxTime, 0);
    }

    function test_increaseUnlockTime_updatesTotalSupply() public {
        vm.warp(2 weeks + 1 hours + 1);
        uint256 shorterDuration = MAX_TIME - 2 weeks;
        uint256 tokenId = escrow.createLock(Lock_1_Amount, shorterDuration);
        uint256 createWeekStart = weekStartTs(block.timestamp); // 3 weeks
        // start = createWeekStart - 2 weeks = 1 week

        vm.warp(block.timestamp + 1 weeks);
        uint256 increaseWeekStart = weekStartTs(block.timestamp); // 4 weeks
        escrow.increaseUnlockTime(tokenId, MAX_TIME);

        // New start = increaseWeekStart = 4 weeks

        // At increase time, supply should be max bias (reset to full duration)
        assertTotalSupply(increaseWeekStart, biasFP(Lock_1_Amount, 0));

        // After some time
        vm.warp(increaseWeekStart + 1 weeks);
        assertTotalSupply(block.timestamp, biasFP(Lock_1_Amount, 1 weeks));

        // At new end, supply should be zero
        assertTotalSupply(increaseWeekStart + maxTime, 0);

        // At old end, supply should still be non-zero since end was extended
        // Old end = 1 week + maxTime. At that time the new lock still has 3 weeks left.
        assertTotalSupply(
            createWeekStart - 2 weeks + maxTime,
            biasFP(Lock_1_Amount, maxTime - 3 weeks)
        );
    }
}
