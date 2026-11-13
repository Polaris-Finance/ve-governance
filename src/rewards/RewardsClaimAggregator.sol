// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.17;

import {IVotingEscrowDecreasing as IVotingEscrow} from "@escrow/IVotingEscrowDecreasing.sol";
import {IRewardsDistributor} from "./IRewardsDistributor.sol";

// @dev This contract needs to be previously set as approved for the VE NFT tokens that are going to be claimed
contract RewardsClaimAggregator {
    IVotingEscrow public immutable ve;

    error NotApprovedOrOwner();
    error EmptyList();

    constructor(address _ve) {
        ve = IVotingEscrow(_ve);
    }

    function claim(IRewardsDistributor[] calldata _rewardDistributors, uint256 _tokenId, uint256 _maxWeeks) public {
        _requireApprovedOrOwner(_tokenId);
        uint256 rewardDistributorsLength = _rewardDistributors.length;
        _requireNonEmptyList(rewardDistributorsLength);

        for (uint256 i = 0; i < rewardDistributorsLength; i++) {
            _rewardDistributors[i].claim(_tokenId, msg.sender, _maxWeeks);
        }
    }

    function claimMany(
        IRewardsDistributor[] calldata _rewardDistributors,
        uint256[] calldata _tokenIds,
        uint256 _maxWeeks
    ) public {
        uint256 tokenIdsLength = _tokenIds.length;
        _requireNonEmptyList(tokenIdsLength);
        for (uint256 i = 0; i < tokenIdsLength; i++) {
            _requireApprovedOrOwner(_tokenIds[i]);
        }
        uint256 rewardDistributorsLength = _rewardDistributors.length;
        _requireNonEmptyList(rewardDistributorsLength);

        for (uint256 i = 0; i < rewardDistributorsLength; i++) {
            _rewardDistributors[i].claimMany(_tokenIds, msg.sender, _maxWeeks);
        }
    }

    function _requireApprovedOrOwner(uint256 _tokenId) internal view {
        if (!ve.isApprovedOrOwner(msg.sender, _tokenId)) revert NotApprovedOrOwner();
    }

    function _requireNonEmptyList(uint256 _len) internal pure {
        if (_len == 0) revert EmptyList();
    }
}
