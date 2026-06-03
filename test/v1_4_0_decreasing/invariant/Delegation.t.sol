pragma solidity ^0.8.17;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {FactoryBase} from "../base/FactoryBase.sol";

import {console2 as console} from "forge-std/console2.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {Multisig, MultisigSetup} from "@aragon/multisig/src/MultisigSetup.sol";
import {MockERC20} from "@mocks/MockERC20.sol";
import {ILockedBalanceIncreasing} from "@escrow/IVotingEscrowDecreasing.sol";

import {ProxyLib} from "@libs/ProxyLib.sol";
import {Test} from "forge-std/Test.sol";

import {
    Lock,
    Clock,
    VotingEscrow,
    SimpleGaugeVoter,
    SimpleGaugeVoterSetup,
    IEscrowCurveDecreasing,
    IEscrowCurveTokenStorage,
    EscrowIVotesAdapter,
    VotingEscrow
} from "../versions.sol";
import {IERC721EnumerableMintableBurnable as IERC721EMB} from "@lock/IERC721EMB.sol";

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {DelegationHandler} from "./handlers/DelegationHandler.sol";

contract TestDelegationInvariant is IEscrowCurveTokenStorage, FactoryBase {
    DelegationHandler internal h;

    function setUp() public override {
        super.setUp();

        h = new DelegationHandler(
            DelegationHandler.Contracts({
                escrow: address(escrow),
                curve: address(curve),
                clock: address(clock),
                lockNft: address(nftLock),
                ivotesAdapter: address(ivotesAdapter),
                voter: address(voter)
            }),
            address(dao),
            maxTime,
            checkpointInterval
        );

        targetContract(address(h));

        {
            bytes4[] memory selectors = new bytes4[](16);
            selectors[0] = DelegationHandler.createLock.selector;
            selectors[1] = DelegationHandler.merge.selector;
            selectors[2] = DelegationHandler.split.selector;
            selectors[3] = DelegationHandler.setDelegateAddress.selector;
            selectors[4] = DelegationHandler.delegate.selector;
            selectors[5] = DelegationHandler.delegateSpecificTokens.selector;
            selectors[6] = DelegationHandler.undelegate.selector;
            selectors[7] = DelegationHandler.withdraw.selector;
            selectors[8] = DelegationHandler.vote.selector;
            selectors[9] = DelegationHandler.transfer.selector;
            selectors[10] = DelegationHandler.checkpointTransition.selector;
            selectors[11] = DelegationHandler.reset.selector;
            selectors[12] = DelegationHandler.lockPermanent.selector;
            selectors[13] = DelegationHandler.unlockPermanent.selector;
            selectors[14] = DelegationHandler.increaseAmount.selector;
            selectors[15] = DelegationHandler.increaseUnlockTime.selector;
            FuzzSelector memory a = FuzzSelector(address(h), selectors);

            targetSelector(a);
        }
    }

    function invariant_TotalLockedCorrect() public view {
        assertEq(h.totalLocked(), escrow.totalLocked());
    }

    function invariant_TokenBalanceEqualsTotalLocked() public view {
        assertEq(MockERC20(escrow.token()).balanceOf(address(escrow)), escrow.totalLocked());
    }

    function invariant_SumOfNftsAmountsEqualTotalLocked() public {
        uint256 amountSum = 0;
        uint256 vpSum = 0;

        // Let's make sure all checkpoints are effective
        vm.warp(block.timestamp + checkpointInterval);

        uint256[] memory ids = h.getActiveTokenIds();
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 tokenId = ids[i];

            uint256 vp = escrow.votingPower(tokenId);
            uint256 amount = escrow.locked(tokenId).amount;

            amountSum += amount;
            vpSum += vp;
        }

        assertEq(amountSum, escrow.totalLocked(), "Sum of NFT Amoutns != totalLocked");
        assertApproxEqAbs(
            vpSum,
            escrow.totalVotingPower(),
            ids.length,
            "Sum of vps individually != total vp"
        );
    }

    function invariant_UserHasCorrectPastVotes() public {
        address[] memory actors = h.getActors();

        // Let's make sure all delegations are effective
        vm.warp(block.timestamp + checkpointInterval);

        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];

            uint256[] memory userIncomingTokens = h.getIncomingTokens(actor);
            uint256[] memory userOutgoingTokens = h.getOutgoingTokens(actor);

            assertEq(userOutgoingTokens.length, ivotesAdapter.numberOfDelegatedTokens(actor));

            uint256 userVp = 0;
            for (uint256 j = 0; j < userIncomingTokens.length; j++) {
                assertTrue(ivotesAdapter.tokenIsDelegated(userIncomingTokens[j]));
                userVp += escrow.votingPower(userIncomingTokens[j]);
            }

            assertApproxEqAbs(
                userVp,
                ivotesAdapter.getPastVotes(actor, block.timestamp),
                userIncomingTokens.length
            );
        }
    }

    function invariant_UserCannotHaveMoreVotesOnGaugeVoterThanIVotesAdapter() public view {
        address[] memory actors = h.getActors();

        uint256 totalPastVotes = 0;
        uint256 delta = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];

            uint256 pastVotes = ivotesAdapter.getVotes(actor);
            totalPastVotes += pastVotes;

            delta += h.getIncomingTokens(actor).length;
        }

        uint256 totalOnGaugeVoter = voter.totalVotingPowerCast();
        if (totalOnGaugeVoter > totalPastVotes) {
            // TODO
            //assertApproxEqAbs(totalOnGaugeVoter, totalPastVotes, delta);
        }
    }

    function invariant_TotalVotingPowerDoesNotExceedTotalLocked() public view {
        assertLe(escrow.totalVotingPower(), bias(h.totalLocked(), 0));
    }

    function invariant_CheckpointsAtStartOfWeek() public view {
        uint256[] memory ids = h.getActiveTokenIds();
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 tokenId = ids[i];

            // Adapter
            address delegatee = ivotesAdapter.delegates(nftLock.ownerOf(tokenId));
            uint256 latestPointIndex = ivotesAdapter.latestPointIndex(delegatee);
            (, , uint256 writtenTs) = ivotesAdapter.pointHistory(delegatee, latestPointIndex);
            assertEq(writtenTs, (writtenTs / checkpointInterval) * checkpointInterval, "Wrong Adapter checkpoint timestamp");
            // Escrow
            uint256 start = escrow.locked(tokenId).start;
            assertEq(start, (start / checkpointInterval) * checkpointInterval, "Wrong Escrow checkpoint timestamp");
            // Curve token
            latestPointIndex = curve.tokenPointLatestIndex(tokenId);
            writtenTs = curve.tokenPointHistory(tokenId, latestPointIndex).writtenTs;
            assertEq(writtenTs, (writtenTs / checkpointInterval) * checkpointInterval, "Wrong Curve checkpoint timestamp");
            // Curve global
            uint256 latestGlobalPointIndex = curve.globalPointLatestIndex();
            writtenTs = curve.globalPointHistory(latestGlobalPointIndex).writtenTs;
            assertEq(writtenTs, (writtenTs / checkpointInterval) * checkpointInterval, "Wrong Curve global checkpoint timestamp");
        }
    }

    function invariant_PermanentLocksProperties() public view {
        uint256[] memory ids = h.getActiveTokenIds();
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 tokenId = ids[i];

            uint256 start = escrow.locked(tokenId).start;
            uint256 amount = escrow.locked(tokenId).amount;
            uint256 latestPointIndex = curve.tokenPointLatestIndex(tokenId);
            int256 slope = curve.tokenPointHistory(tokenId, latestPointIndex).slope;
            if (h.isPermanentLock(tokenId)) {
                assertEq(slope, 0, "Permanent locks should have slope zero");
                assertEq(start, 0, "Permanent locks should have start zero");
                assertGt(amount, 0, "Permanent locks should have non zero amount");
            } else {
                // Only in case of not expired locks
                if (!escrow.isLockExpired(tokenId)) {
                    assertLt(slope, 0, "Non permanent locks should have negative slope");
                }
                assertGt(start, 0, "Non permanent locks should have non zero start");
            }
        }
    }
}
