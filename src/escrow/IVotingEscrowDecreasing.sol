/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IEscrowIVotesAdapter, IDelegateUpdateVotingPower} from "@delegation/IEscrowIVotesAdapter.sol";

/*///////////////////////////////////////////////////////////////
                        CORE FUNCTIONALITY
//////////////////////////////////////////////////////////////*/
import {ILockedBalanceIncreasing} from "@escrow/IVotingEscrowIncreasing.sol";

interface ILockedBalanceDecreasing is ILockedBalanceIncreasing {
    struct LockedBalanceDecreasing {
        LockedBalance lockedBalance;
        uint256 effectiveStart;
    }
}


interface IVotingEscrowCoreErrors {
    error NoLockFound();
    error NotOwner();
    error NoOwner();
    error NotSameOwner();
    error NonExistentToken();
    error NotApprovedOrOwner();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroBalance();
    error SameAddress();
    error LockNFTAlreadySet();
    error MustBe18Decimals();
    error TransferBalanceIncorrect();
    error AmountTooSmall();
    error DurationTooLong();
    error DurationTooShort();
    error DurationNotMultipleOfInterval();
    error OnlyLockNFT();
    error OnlyIVotesAdapter();
    error AddressAlreadySet();
    error CannotExit();
    error CannotWithdrawUntilExpiry();
    error LockExpired();
    error PermanentLock();
    error NotPermanentLock();
    error DurationNotIncreased();
}

interface IVotingEscrowCoreEvents {
    event MinDepositSet(uint256 minDeposit);

    event Deposit(
        address indexed depositor,
        uint256 indexed tokenId,
        uint256 indexed startTs,
        uint256 virtualStartTs,
        uint256 duration,
        uint256 value,
        uint256 newTotalLocked
    );
    event Withdraw(
        address indexed depositor,
        uint256 indexed tokenId,
        uint256 value,
        uint256 ts,
        uint256 newTotalLocked
    );

    event LockPermanent(address indexed depositor, uint256 indexed tokenId, uint256 amount, uint256 timestamp);
    event UnlockPermanent(address indexed depositor, uint256 indexed tokenId, uint256 amount, uint256 timestamp);
}

interface IVotingEscrowCore is
    ILockedBalanceDecreasing,
    IVotingEscrowCoreErrors,
    IVotingEscrowCoreEvents
{
    /// @notice Address of the underying ERC20 token.
    function token() external view returns (address);

    /// @notice Address of the lock receipt NFT.
    function lockNFT() external view returns (address);

    /// @notice Total underlying tokens deposited in the contract
    function totalLocked() external view returns (uint256);

    /// @notice Get the raw locked balance for `_tokenId`
    function locked(uint256 _tokenId) external view returns (LockedBalance memory);

    function ownerOf(uint256 _tokenId) external view returns (address);

    /// @notice Deposit `_value` tokens for `msg.sender`
    /// @param _value Amount to deposit
    /// @param _duration For how long the tokens are locked in the NFT
    /// @return TokenId of created veNFT
    function createLock(uint256 _value, uint256 _duration) external returns (uint256);

    /// @notice Deposit `_value` tokens for `_to`
    /// @param _value Amount to deposit
    /// @param _duration For how long the tokens are locked in the NFT
    /// @param _to Address to deposit
    /// @return TokenId of created veNFT
    function createLockFor(uint256 _value, uint256 _duration, address _to) external returns (uint256);

    /// @param _start Timestamp when the lock is created
    /// @param _duration For how long the tokens are locked in the NFT
    /// @return Timestamp in the past that would make a max time (4 years) lock equivalent to one created on `_start` for `_duration`
    function getVirtualStart(uint256 _start, uint256 _duration) external view returns(uint256);

    function isLockExpired(uint256 _tokenId) external view returns (bool);

    function lockPermanent(uint256 _tokenId) external;
    function unlockPermanent(uint256 _tokenId) external;
    function increaseAmount(uint256 _tokenId, uint256 _value) external;
    function increaseUnlockTime(uint256 _tokenId, uint256 _duration) external;
    function isPermanent(uint256 _tokenId) external view returns (bool);

    /// @notice Withdraw all tokens for `_tokenId`
    function withdraw(uint256 _tokenId) external;

    /// @notice helper utility for NFT checks
    function isApprovedOrOwner(address spender, uint256 tokenId) external view returns (bool);
}

/*///////////////////////////////////////////////////////////////
                        SWEEPER
//////////////////////////////////////////////////////////////*/

interface ISweeperEvents {
    event Sweep(address indexed to, uint256 amount);
    event SweepNFT(address indexed to, uint256 tokenId);
}

interface ISweeperErrors {
    error NothingToSweep();
}

interface ISweeper is ISweeperEvents, ISweeperErrors {
    /// @notice sweeps excess tokens from the contract to a designated address
    function sweep() external;

    function sweepNFT(uint256 _tokenId, address _to) external;
}

/*///////////////////////////////////////////////////////////////
                        DYNAMIC VOTER
//////////////////////////////////////////////////////////////*/

interface IDynamicVoterErrors {
    error NotVoter();
    error OwnershipChange();
    error AlreadyVoted();
}

interface IDynamicVoter is IDynamicVoterErrors {
    /// @notice Address of the voting contract.
    /// @dev We need to ensure votes are not left in this contract before allowing positing changes
    function voter() external view returns (address);

    /// @notice Address of the voting Escrow Curve contract that will calculate the voting power
    function curve() external view returns (address);

    /// @notice Get the voting power for _tokenId at the current timestamp
    /// @dev Returns 0 if called in the same block as a transfer.
    /// @param _tokenId .
    /// @return Voting power
    function votingPower(uint256 _tokenId) external view returns (uint256);

    /// @notice Get the voting power for _tokenId at a given timestamp
    /// @param _tokenId .
    /// @param _t Timestamp to query voting power
    /// @return Voting power
    function votingPowerAt(uint256 _tokenId, uint256 _t) external view returns (uint256);

    /// @notice Get the voting power for _account at the current timestamp
    /// Aggregtes all voting power for all tokens owned by the account
    /// @dev This cannot be used historically without token snapshots
    function votingPowerForAccount(address _account) external view returns (uint256);

    /// @notice Calculate total voting power at current timestamp
    /// @return Total voting power at current timestamp
    function totalVotingPower() external view returns (uint256);

    /// @notice Calculate total voting power at a given timestamp
    /// @param _t Timestamp to query total voting power
    /// @return Total voting power at given timestamp
    function totalVotingPowerAt(uint256 _t) external view returns (uint256);

    /// @notice See if a queried _tokenId has actively voted
    /// @return True if voted, else false
    function isVoting(uint256 _tokenId) external view returns (bool);

    /// @notice Set the global state voter
    function setVoter(address _voter) external;
}

/*///////////////////////////////////////////////////////////////
                        INCREASED ESCROW
//////////////////////////////////////////////////////////////*/

/// @dev useful for testing
interface IVotingEscrowEventsStorageErrorsEvents is
    IVotingEscrowCoreErrors,
    IVotingEscrowCoreEvents,
    ILockedBalanceIncreasing,
    ISweeperEvents,
    ISweeperErrors
{}

// From v1_2_0

interface IMergeEventsAndErrors {
    event Merged(
        address indexed _sender,
        uint256 indexed _from,
        uint256 indexed _to,
        uint208 _amountFrom,
        uint208 _amountTo,
        uint208 _amountFinal
    );

    error CannotMerge(uint256 _from, uint256 _to);
    error SameNFT();
}

interface IMerge is ILockedBalanceIncreasing, IMergeEventsAndErrors {
    /// @notice Merge two tokens - i.e  `from` into `_to`.
    /// @param _from The token id from which merge is occuring
    /// @param _to The token id to which `_from` is merging
    function merge(uint256 _from, uint256 _to) external;

    /// @notice Whether 2 tokens can be merged.
    /// @param _from The token id from which merge should occur.
    /// @param _to The token id to which `_from` should merge.
    function canMerge(
        LockedBalance memory _from,
        LockedBalance memory _to
    ) external pure returns (bool);
}

interface ISplitEventsAndErrors {
    event Split(
        uint256 indexed _from,
        uint256 indexed newTokenId,
        address _sender,
        uint208 _splitAmount1,
        uint208 _splitAmount2
    );

    event SplitWhitelistSet(address indexed account, bool status);

    error SplitNotWhitelisted();
    error SplitAmountTooBig();
}

interface ISplit is ISplitEventsAndErrors {
    /// @notice Split token into two new, separate tokens.
    /// @param _from The token id that should be split
    /// @param _value The amount that determines how token is split
    /// @return _newTokenId The new token id after split.
    function split(
        uint256 _from,
        uint256 _value
    ) external returns (uint256 _newTokenId);
}

interface IDelegateMoveVoteCaller {
    /// @notice After a token transfer, decreases `_from`'s voting power and increases `_to`'s voting power.
    /// @dev Called upon a token transfer.
    /// @param _from The current delegatee of `_tokenId`.
    /// @param _to The new delegatee of `_tokenId`
    /// @param _tokenId The token id that is being transferred.
    function moveDelegateVotes(
        address _from,
        address _to,
        uint256 _tokenId
    ) external;
}

interface IVotingEscrowDecreasing is
    IVotingEscrowCore,
    IDynamicVoter,
    ISweeper,
    IMerge,
    ISplit,
    IDelegateUpdateVotingPower,
    IDelegateMoveVoteCaller
{}
