pragma solidity ^0.8.17;

import {EscrowBase} from "../../../base/EscrowBase.sol";

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
    ISplitEventsAndErrors
} from "../../../versions.sol";

contract TestEscrowSplit is EscrowBase {
    function setUp() public override {
        super.setUp();

        super.mintAndApproveEscrow();

        escrow.setEnableSplit(address(this), true);
    }

    function test_shouldRevertIfEscrowPaused() public {
        uint256 from = escrow.createLock(Lock_1_Amount, MAX_TIME);
        
        escrow.pause();
        
        vm.expectRevert("Pausable: paused");
        escrow.split(from, 10);
    }

    function test_shouldRevert_ifNotWhitelisted() public {
        // owner is address(this)
        uint256 from = escrow.createLock(Lock_1_Amount, MAX_TIME);

        escrow.setEnableSplit(address(this), false);
        
        // approve so address(123) can also call split
        // It still should fail as owner itself is not whitelisted.
        nftLock.approve(address(123), from);

        vm.expectRevert(SplitNotWhitelisted.selector);
        vm.prank(address(123));
        escrow.split(from, 10);
    }

    function test_shouldRevert_IfSenderIsNotApprovedOrOwner() public {
        uint256 from = escrow.createLock(Lock_1_Amount, MAX_TIME);

        address sender = address(999);
        escrow.setEnableSplit(sender, true);

        vm.startPrank(sender);
        vm.expectRevert(IVotingEscrowCoreErrors.NotApprovedOrOwner.selector);
        escrow.split(from, 10);
    }

    function test_shouldRevert_IfTokenHasNoOwner() public {
        vm.expectRevert("ERC721: invalid token ID");
        escrow.split(15, 10);
    }

    function test_shouldRevert_IfNewAmountsLessThanMinDeposit() public {
        escrow.setMinDeposit(50);
        uint256 from = escrow.createLock(70, MAX_TIME);

        vm.expectRevert(IVotingEscrowCoreErrors.AmountTooSmall.selector);
        escrow.split(from, 40);
    }

    function test_shouldRevert_ifAmountZero() public {
        uint256 from = escrow.createLock(Lock_1_Amount, MAX_TIME);

        vm.expectRevert(IVotingEscrowCoreErrors.ZeroAmount.selector);
        escrow.split(from, 0);
    }

    function test_shouldRevert_ifAmountTooBig() public {
        uint256 from = escrow.createLock(Lock_1_Amount, MAX_TIME);

        vm.expectRevert(SplitAmountTooBig.selector);
        escrow.split(from, Lock_1_Amount);
    }

    function test_shouldSucceed_IfAnyAddrWhitelisted() public {
        escrow.setEnableSplit(address(this), false);

        escrow.enableSplit();

        uint256 from = escrow.createLock(Lock_1_Amount, MAX_TIME);
        escrow.split(from, Lock_1_Amount - 10);
    }

    function test_fromTokenIsRetainedWithCorrectValue() public {
        vm.warp(checkpointInterval + 1 hours);

        uint256 from = escrow.createLock(Lock_1_Amount, MAX_TIME);

        escrow.split(from, 10e18);

        LockedBalance memory lockedFrom = escrow.locked(from);

        assertEq(lockedFrom.start, weekStartTs(block.timestamp));
        assertEq(lockedFrom.amount, Lock_1_Amount - 10e18);

        assertEq(nftLock.ownerOf(from), address(this));
    }

    function test_CreatesNewTokenWithSameStartDate() public {
        vm.warp(checkpointInterval + 1 hours);

        uint256 originalTokenStartTs = weekStartTs(block.timestamp);

        uint256 splitVal = 1200;

        uint256 token1Value = Lock_1_Amount - splitVal;
        uint256 token2Value = splitVal;

        uint256 from = escrow.createLock(Lock_1_Amount, MAX_TIME);

        // warp so even though the start should give different week,
        // the new tokens stills should use original token's start.
        vm.warp(block.timestamp + checkpointInterval + 1 hours);
        escrow.split(from, splitVal);

        LockedBalance memory token1 = escrow.locked(from);
        LockedBalance memory token2 = escrow.locked(from + 1);

        assertEq(token1.amount, token1Value);
        assertEq(token1.start, originalTokenStartTs);

        assertEq(token2.amount, token2Value);
        assertEq(token2.start, originalTokenStartTs);
    }

    function test_SplitEventIsEmitted() public {
        uint256 splitVal = 20;
        uint256 from = escrow.createLock(Lock_1_Amount, MAX_TIME);
        vm.expectEmit();
        emit Split(
            from,
            from + 1,
            address(this),
            uint208(Lock_1_Amount - splitVal),
            uint208(splitVal)
        );
        escrow.split(from, splitVal);
    }

    function test_splitPermanentLock_bothResultingLocksArePermanent() public {
        escrow.enableSplit();

        uint256 tokenId = escrow.createLock(Lock_1_Amount, MAX_TIME);
        escrow.lockPermanent(tokenId);
        assertTrue(escrow.isPermanent(tokenId));

        uint256 splitValue = getFlooredAmount(Lock_1_Amount / 2);
        escrow.split(tokenId, splitValue);

        assertTrue(escrow.isPermanent(tokenId));
        assertTrue(escrow.isPermanent(tokenId + 1));

        vm.warp(block.timestamp + 1 weeks);

        assertTrue(escrow.isPermanent(tokenId));
        assertTrue(escrow.isPermanent(tokenId + 1));
    }
}
