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

contract TestModifyLock_Points is IEscrowCurveTokenStorage, IEscrowCurveGlobalStorage, EscrowBase {
    function setUp() public override {
        super.setUp();

        super.mintAndApproveEscrow();
    }

    function test_lockPermanent_updatesTokenAndGlobalPoints() public {
        vm.warp(2 weeks + 1 hours + 1);
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        uint256 createWeekStart = weekStartTs(block.timestamp); // 3 weeks

        vm.warp(block.timestamp + 1 weeks);
        uint256 permanentWeekStart = weekStartTs(block.timestamp); // 4 weeks
        escrow.lockPermanent(tokenId);

        // Token point: permanent lock has max bias (constant coeff), zero slope
        assertTokenPoint(tokenId, 2, biasFP(Lock_1_Amount, 0), 0, permanentWeekStart);

        // Global point: old decaying bias replaced by maxed-out permanent bias
        assertGlobalPoint(2, biasFP(Lock_1_Amount, 0), 0, permanentWeekStart);

        // Slope change at the old end should be removed
        assertEq(slopeChanges(createWeekStart + maxTime), 0);
    }

    function test_unlockPermanent_updatesTokenAndGlobalPoints() public {
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

        // Token point: fresh non-permanent lock starting from unlock time
        assertTokenPoint(
            tokenId,
            3,
            biasFP(Lock_1_Amount, 0),
            slopeFP(Lock_1_Amount),
            unlockWeekStart
        );

        // Global point: bias stayed maxed-out while permanent, slope restored
        assertGlobalPoint(
            3,
            biasFP(Lock_1_Amount, 0),
            slopeFP(Lock_1_Amount),
            unlockWeekStart
        );

        // New slope change scheduled at the new end
        assertEq(slopeChanges(unlockWeekStart + maxTime), slopeFP(Lock_1_Amount));
    }

    function test_increaseAmount_updatesTokenAndGlobalPoints() public {
        vm.warp(2 weeks + 1 hours + 1);
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        uint256 createWeekStart = weekStartTs(block.timestamp); // 3 weeks

        vm.warp(block.timestamp + 1 weeks);
        uint256 increaseWeekStart = weekStartTs(block.timestamp); // 4 weeks
        escrow.increaseAmount(tokenId, Lock_2_Amount);

        uint256 totalAmount = Lock_1_Amount + Lock_2_Amount;

        // Token point: same start, higher amount, 1 week elapsed from start
        assertTokenPoint(
            tokenId,
            2,
            biasFP(totalAmount, 1 weeks),
            slopeFP(totalAmount),
            increaseWeekStart
        );

        // Global point
        assertGlobalPoint(
            2,
            biasFP(totalAmount, 1 weeks),
            slopeFP(totalAmount),
            increaseWeekStart
        );

        // Slope change updated to the new combined amount
        assertEq(slopeChanges(createWeekStart + maxTime), slopeFP(totalAmount));
    }

    function test_increaseUnlockTime_updatesTokenAndGlobalPoints() public {
        vm.warp(2 weeks + 1 hours + 1);
        uint256 shorterDuration = MAX_TIME - 2 weeks;
        uint256 tokenId = escrow.createLock(Lock_1_Amount, shorterDuration);
        uint256 createWeekStart = weekStartTs(block.timestamp); // 3 weeks
        // start = createWeekStart - 2 weeks = 1 week

        vm.warp(block.timestamp + 1 weeks);
        uint256 increaseWeekStart = weekStartTs(block.timestamp); // 4 weeks
        escrow.increaseUnlockTime(tokenId, MAX_TIME);

        // New start = increaseWeekStart + MAX_TIME - MAX_TIME = increaseWeekStart = 4 weeks
        // Token point: reset to full bias at 0 elapsed
        assertTokenPoint(
            tokenId,
            2,
            biasFP(Lock_1_Amount, 0),
            slopeFP(Lock_1_Amount),
            increaseWeekStart
        );

        // Global point: old lock had 3 weeks elapsed (from start=1w to effectiveStart=4w)
        // After extending, global bias resets to max
        assertGlobalPoint(
            2,
            biasFP(Lock_1_Amount, 0),
            slopeFP(Lock_1_Amount),
            increaseWeekStart
        );

        // Old slope change removed, new one added
        assertEq(slopeChanges(createWeekStart - 2 weeks + maxTime), 0);
        assertEq(slopeChanges(increaseWeekStart + maxTime), slopeFP(Lock_1_Amount));
    }
}
