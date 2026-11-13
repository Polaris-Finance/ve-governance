pragma solidity ^0.8.17;

import {EscrowBase} from "../../../base/EscrowBase.sol";

import {console2 as console} from "forge-std/console2.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {Multisig, MultisigSetup} from "@aragon/multisig/src/MultisigSetup.sol";

import {ProxyLib} from "@libs/ProxyLib.sol";

import {
    Lock,
    Clock,
    VotingEscrow,
    SimpleGaugeVoter,
    SimpleGaugeVoterSetup,
    IEscrowCurveTokenStorage,
    IGaugeVote
} from "../../../versions.sol";

contract TestSweep is IEscrowCurveTokenStorage, IGaugeVote, EscrowBase {
    /// @dev Deposits are floored to a multiple of the curve's linear denominator.
    uint256 internal depositAmount;

    function setUp() public override {
        super.setUp();

        depositAmount = getFlooredAmount(1000 ether);

        // grant the sweeper role to this contract
        dao.grant({
            _who: address(this),
            _where: address(escrow),
            _permissionId: escrow.SWEEPER_ROLE()
        });
    }

    function testCanSweepExcessTokens() public {
        token.mint(address(escrow), 1000);

        assertEq(token.balanceOf(address(escrow)), 1000);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(escrow.totalLocked(), 0);

        vm.expectEmit(true, false, false, true);
        emit Sweep(address(this), 1000);
        escrow.sweep();

        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(address(this)), 1000);
    }

    function testCannotSweepFromLocked() public {
        address user = address(1);
        token.mint(address(user), depositAmount);

        vm.startPrank(user);
        {
            token.approve(address(escrow), depositAmount);
            escrow.createLock(depositAmount, MAX_TIME);
        }
        vm.stopPrank();

        assertEq(token.balanceOf(address(escrow)), depositAmount);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(escrow.totalLocked(), depositAmount);

        // first try with no excess tokens
        vm.expectRevert(NothingToSweep.selector);
        escrow.sweep();

        // check that nothing changed
        assertEq(token.balanceOf(address(escrow)), depositAmount);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(escrow.totalLocked(), depositAmount);

        // now try with excess tokens
        token.mint(address(escrow), depositAmount);

        assertEq(token.balanceOf(address(escrow)), 2 * depositAmount);

        escrow.sweep();

        assertEq(token.balanceOf(address(escrow)), depositAmount);
        assertEq(token.balanceOf(address(this)), depositAmount);
        assertEq(escrow.totalLocked(), depositAmount);
    }

    function testOnlySweeperRole() public {
        address notThis = address(1);

        bytes memory err = _authErr(notThis, address(escrow), escrow.SWEEPER_ROLE());

        vm.prank(notThis);
        vm.expectRevert(err);
        escrow.sweep();

        vm.prank(notThis);
        vm.expectRevert(err);
        escrow.sweepNFT(1, address(this));
    }

    function testCannotSweepNFTIfNotInContract() public {
        // create a lock
        token.mint(address(this), depositAmount);
        token.approve(address(escrow), depositAmount);
        uint tokenId = escrow.createLock(depositAmount, MAX_TIME);

        // try to sweep the NFT -- should fail as it's not in the contract
        vm.expectRevert(NothingToSweep.selector);
        escrow.sweepNFT(tokenId, address(this));
    }

    function testCanSweepNFT() public {
        // create, transfer, whitelis, sweep
        token.mint(address(this), depositAmount);
        token.approve(address(escrow), depositAmount);
        uint tokenId = escrow.createLock(depositAmount, MAX_TIME);
        nftLock.transferFrom(address(this), address(escrow), tokenId);
        nftLock.setWhitelisted(address(this), true);

        assertEq(nftLock.balanceOf(address(this)), 0);
        assertEq(nftLock.balanceOf(address(escrow)), 1);

        vm.expectEmit(true, false, false, true);
        emit SweepNFT(address(this), tokenId);
        escrow.sweepNFT(tokenId, address(this));

        assertEq(nftLock.balanceOf(address(this)), 1);
        assertEq(nftLock.balanceOf(address(escrow)), 0);
    }
}
