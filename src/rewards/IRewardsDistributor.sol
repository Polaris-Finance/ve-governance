// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVotingEscrowDecreasing as IVotingEscrow} from "../escrow/IVotingEscrowDecreasing.sol";

interface IRewardsDistributor {
    event CheckpointToken(uint256 time, uint256 tokens);
    event Claimed(uint256 indexed tokenId, uint256 indexed epochStart, uint256 indexed epochEnd, uint256 amount);

    error NotRewardsSender();
    error NotApprovedOrOwner();

    /// @notice 7 days in seconds
    function WEEK() external view returns (uint256);

    /// @notice Timestamp of the start of the week of contract creation
    function START_WEEK_TIME() external view returns (uint256);

    /// @notice Timestamp of most recent claim of tokenId
    function timeCursorOf(uint256 tokenId) external view returns (uint256);

    /// @notice The last week RewardsSender has called checkpointToken()
    function lastTokenWeekTime() external view returns (uint256);

    /// @notice Interface of VotingEscrow.sol
    function ve() external view returns (IVotingEscrow);

    /// @notice Address of token used for distributions (AERO)
    function token() external view returns (address);

    /// @notice Address of RewardsSender
    ///         Authorized caller of checkpointToken()
    function rewardsSender() external view returns (address);

    /// @notice Amount of token in contract when checkpointToken() was last called
    function tokenLastBalance() external view returns (uint256);

    /// @notice Called by RewardsSender to notify Distributor of rewards
    function checkpointToken() external;

    /// @notice Returns the amount of rebases claimable for a given token ID
    /// @dev Allows claiming of rebases up to 50 epochs old
    /// @param tokenId The token ID to check
    /// @return The amount of rebases claimable for the given token ID
    function claimable(uint256 tokenId) external view returns (uint256);

    /// @notice Claims rebases for a given token ID
    /// @dev Allows claiming of rebases up to 50 epochs old
    /// @param tokenId The token ID to claim for
    /// @return The amount of rebases claimed
    function claim(uint256 tokenId) external returns (uint256);

    /// @notice Claims rebases for a list of token IDs
    /// @param tokenIds The token IDs to claim for
    /// @return Whether or not the claim succeeded
    function claimMany(uint256[] calldata tokenIds) external returns (bool);
}
