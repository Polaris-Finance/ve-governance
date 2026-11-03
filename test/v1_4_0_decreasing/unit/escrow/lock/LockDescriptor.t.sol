pragma solidity ^0.8.17;

import {EscrowBase} from "../../../base/EscrowBase.sol";

import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ILockNFTDescriptor} from "@lock/Lock_v1_2_0.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {
    Lock,
    Clock,
    VotingEscrow,
    SimpleGaugeVoter,
    SimpleGaugeVoterSetup,
    IEscrowCurveTokenStorage,
    IGaugeVote,
    ILock,
    IDelegateMoveVoteCaller
} from "../../../versions.sol";

/// @dev Tests for the `setDescriptor` and `tokenURI` functions added in `Lock_v1_2_0`.
contract TestLockDescriptor is EscrowBase {
    /// @dev Mirrors the event declared on `LockV1_2_0` so `vm.expectEmit` can match it.
    event DescriptorSet(address indexed descriptor);

    MockNFTDescriptor mockDescriptor;
    uint256 tokenId;

    function setUp() public override {
        super.setUp();

        // Grant this contract the role required to update the NFT art descriptor.
        dao.grant({_who: address(this), _where: address(nftLock), _permissionId: nftLock.LOCK_NFT_ART_UPDATE_ROLE()});

        mockDescriptor = new MockNFTDescriptor();

        // Create a lock so there is a minted token to query `tokenURI` against.
        mintAndApproveEscrow(100e18);
        tokenId = escrow.createLock(100e18, MAX_TIME);
    }

    /*//////////////////////////////////////////////////////////////
                              setDescriptor
    //////////////////////////////////////////////////////////////*/

    function testSetDescriptor() public {
        assertEq(nftLock.descriptor(), address(0));

        vm.expectEmit(true, false, false, false);
        emit DescriptorSet(address(mockDescriptor));

        nftLock.setDescriptor(address(mockDescriptor));

        assertEq(nftLock.descriptor(), address(mockDescriptor));
    }

    function testSetDescriptorUpdatesExisting() public {
        // Set an initial descriptor.
        nftLock.setDescriptor(address(mockDescriptor));
        assertEq(nftLock.descriptor(), address(mockDescriptor));

        // Update to a brand-new descriptor.
        MockNFTDescriptor newDescriptor = new MockNFTDescriptor();

        vm.expectEmit(true, false, false, false);
        emit DescriptorSet(address(newDescriptor));

        nftLock.setDescriptor(address(newDescriptor));

        assertEq(nftLock.descriptor(), address(newDescriptor));
    }

    function testSetDescriptorToZeroAddress() public {
        // Set a non-zero descriptor first.
        nftLock.setDescriptor(address(mockDescriptor));
        assertEq(nftLock.descriptor(), address(mockDescriptor));

        // Clear it by setting back to the zero address.
        vm.expectEmit(true, false, false, false);
        emit DescriptorSet(address(0));

        nftLock.setDescriptor(address(0));

        assertEq(nftLock.descriptor(), address(0));
    }

    function testSetDescriptorUnauthorized() public {
        address caller = makeAddr("unauthorized");

        vm.expectRevert(_authErr(caller, address(nftLock), nftLock.LOCK_NFT_ART_UPDATE_ROLE()));

        vm.prank(caller);
        nftLock.setDescriptor(address(mockDescriptor));
    }

    /*//////////////////////////////////////////////////////////////
                              tokenURI
    //////////////////////////////////////////////////////////////*/

    function testTokenURIReturnsEmptyWhenNoDescriptor() public view {
        assertEq(nftLock.descriptor(), address(0));

        assertEq(nftLock.tokenURI(tokenId), "");
    }

    function testTokenURIRevertsForNonExistentToken() public {
        vm.expectRevert("ERC721: invalid token ID");
        nftLock.tokenURI(999);
    }

    function testTokenURIRevertsForNonExistentTokenWithDescriptor() public {
        nftLock.setDescriptor(address(mockDescriptor));

        vm.expectRevert("ERC721: invalid token ID");
        nftLock.tokenURI(999);
    }

    function testTokenURIReturnsRenderedURI() public {
        nftLock.setDescriptor(address(mockDescriptor));

        uint256 amount = escrow.locked(tokenId).amount;
        uint256 votingPower = escrow.votingPower(tokenId);

        assertEq(nftLock.tokenURI(tokenId), mockDescriptor.renderLock(tokenId, amount, votingPower));
    }

    function testFuzz_TokenURIWithDescriptor(uint256 _amount) public {
        // Bound to a sensible deposit range (min deposit is 1).
        _amount = bound(_amount, 1, 1_000_000_000e18);

        nftLock.setDescriptor(address(mockDescriptor));

        mintAndApproveEscrow(_amount);
        uint256 newTokenId = escrow.createLock(_amount, MAX_TIME);

        uint256 amount = escrow.locked(newTokenId).amount;
        uint256 votingPower = escrow.votingPower(newTokenId);

        assertEq(nftLock.tokenURI(newTokenId), mockDescriptor.renderLock(newTokenId, amount, votingPower));
    }
}

/// @dev Minimal mock that implements `ILockNFTDescriptor` so `tokenURI` can be exercised.
///      Encodes the tokenId, amount and votingPower into a deterministic string.
contract MockNFTDescriptor is ILockNFTDescriptor {
    using Strings for uint256;

    function renderLock(uint256 _tokenId, uint256 _amount, uint256 _votingPower) external pure returns (string memory) {
        return
            string(
                abi.encodePacked("lock#", _tokenId.toString(), "-", _amount.toString(), "-", _votingPower.toString())
            );
    }
}
