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

contract TestVotingPower is IEscrowCurveTokenStorage, IEscrowCurveGlobalStorage, EscrowBase {
    function setUp() public override {
        super.setUp();

        super.mintAndApproveEscrow();

        vm.warp(1);
    }

    function test_whenOnlyOneTokenPoint() public {
        // Given: no prior locks existing
        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        uint256 weekStartTs = weekStartTs(block.timestamp);
        uint256 endTs = getEndTimestamp(weekStartTs, block.timestamp);

        // 1
        assertVotingPower(tokenId, biasFP(Lock_1_Amount, block.timestamp - weekStartTs));

        // 2
        int256 minVotingPower = biasFP(Lock_1_Amount, maxTime);
        assertVotingPower(tokenId, endTs, minVotingPower, "At end");
        assertVotingPower(tokenId, endTs + 10, 0, "At end + 10");
    }

    function test_whenMultipleTokenPoints_NotMature() public {
        uint256 weekStartTs = weekStartTs(block.timestamp);

        uint256 tokenId1 = escrow.createLock(Lock_1_Amount, MAX_TIME);
        uint256 tokenId2 = escrow.createLock(Lock_2_Amount, MAX_TIME);

        vm.warp(block.timestamp + 10);

        escrow.merge(tokenId1, tokenId2);
        uint256 endTs = getEndTimestamp(weekStartTs, block.timestamp);

        assertVotingPower(
            tokenId2,
            biasFP(Lock_1_Amount, block.timestamp - weekStartTs) +
            biasFP(Lock_2_Amount, block.timestamp - weekStartTs),
            "At t+10"
        );

        int256 minVotingPower = biasFP(Lock_1_Amount, maxTime) + biasFP(Lock_2_Amount, maxTime);

        assertVotingPower(tokenId2, endTs, minVotingPower, "At end");
        assertVotingPower(tokenId2, endTs + 10, 0, "At end + 10");
    }

    function test_whenMultipleTokenPoints_Mature() public {
        uint256 weekStartTs = weekStartTs(block.timestamp);
        uint256 endTs = getEndTimestamp(weekStartTs, block.timestamp);

        uint256 tokenId1 = escrow.createLock(Lock_1_Amount, MAX_TIME);
        uint256 tokenId2 = escrow.createLock(Lock_2_Amount, MAX_TIME);

        vm.warp(endTs + 1);

        escrow.merge(tokenId1, tokenId2);

        assertVotingPower(tokenId2, endTs, biasFP(Lock_2_Amount, maxTime), "At end");
        assertVotingPower(tokenId2, endTs + 1, 0, "At end + 1");
        assertVotingPower(tokenId2, endTs + 10, 0, "At end + 10");
        assertVotingPower(tokenId2, endTs + 20, 0, "At end + 20");
    }
}
