/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// token interfaces
import {
    IERC20Upgradeable as IERC20
} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {
    IERC20MetadataUpgradeable as IERC20Metadata
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {IERC721EnumerableMintableBurnable as IERC721EMB} from "@lock/IERC721EMB.sol";

// veGovernance
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {IAddressGaugeVoter} from "@voting/IAddressGaugeVoter.sol";
import {
    IEscrowCurveDecreasing as IEscrowCurve
} from "@curve/IEscrowCurveDecreasing.sol";
import {
    IVotingEscrowDecreasing as IVotingEscrow,
    IMerge,
    ISplit,
    IDelegateMoveVoteCaller
} from "@escrow/IVotingEscrowDecreasing.sol";
import {IClockV1_2_0 as IClock} from "@clock/IClock_v1_2_0.sol";

// libraries
import {
    SafeERC20Upgradeable as SafeERC20
} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {
    SafeCastUpgradeable as SafeCast
} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";

// parents
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable as ReentrancyGuard
} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {
    PausableUpgradeable as Pausable
} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {
    DaoAuthorizableUpgradeable as DaoAuthorizable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {
    IDelegateUpdateVotingPower,
    IEscrowIVotesAdapter,
    IDelegateMoveVoteRecipient
} from "../delegation/IEscrowIVotesAdapter.sol";

contract VotingEscrowDecreasing is
    IVotingEscrow,
    ReentrancyGuard,
    Pausable,
    DaoAuthorizable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Role required to manage the Escrow curve, this typically will be the DAO
    bytes32 public constant ESCROW_ADMIN_ROLE = keccak256("ESCROW_ADMIN");

    /// @notice Role required to pause the contract - can be given to emergency contracts
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER");

    /// @notice Role required to withdraw underlying tokens from the contract
    bytes32 public constant SWEEPER_ROLE = keccak256("SWEEPER");

    /// @dev enables splits without whitelisting
    address public constant SPLIT_WHITELIST_ANY_ADDRESS =
        address(uint160(uint256(keccak256("SPLIT_WHITELIST_ANY_ADDRESS"))));

    /*//////////////////////////////////////////////////////////////
                              NFT Data
    //////////////////////////////////////////////////////////////*/

    /// @notice Decimals of the voting power
    uint8 public constant decimals = 18;

    /// @notice Minimum deposit amount
    uint256 public minDeposit;

    /// @notice Auto-incrementing ID for the most recently created lock, does not decrease on withdrawal
    uint256 public lastLockId;

    /// @notice Total supply of underlying tokens deposited in the contract
    uint256 public totalLocked;

    /// @dev tracks the locked balance of each NFT
    mapping(uint256 => LockedBalance) private _locked;

    /*//////////////////////////////////////////////////////////////
                              Helper Contracts
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of the underying ERC20 token.
    /// @dev Only tokens with 18 decimals and no transfer fees are supported
    address public token;

    /// @notice Address of the gauge voting contract.
    /// @dev We need to ensure votes are not left in this contract before allowing positing changes
    address public voter;

    /// @notice Address of the voting Escrow Curve contract that will calculate the voting power
    address public curve;

    /// @notice Address of the clock contract that manages epoch and voting periods
    address public clock;

    /// @notice Address of the NFT contract that is the lock
    address public lockNFT;

    bool private _lockNFTSet;

    /*//////////////////////////////////////////////////////////////
                            ADDED: in 1.2.0
    //////////////////////////////////////////////////////////////*/

    /// @notice Whitelisted contracts that are allowed to split
    mapping(address => bool) public splitWhitelisted;

    /// @notice Addess of the escrow ivotes adapter where delegations occur.
    address public ivotesAdapter;

    /*//////////////////////////////////////////////////////////////
                              Initialization
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _token,
        address _dao,
        address _clock,
        uint256 _initialMinDeposit
    ) external initializer {
        __ReentrancyGuard_init();
        __Pausable_init();
        __DaoAuthorizableUpgradeable_init(IDAO(_dao));

        if (IERC20Metadata(_token).decimals() != 18) revert MustBe18Decimals();
        token = _token;
        clock = _clock;
        minDeposit = _initialMinDeposit;
        emit MinDepositSet(_initialMinDeposit);
    }

    /// @notice Used to revert if admin tries to change the contract address 2nd time.
    modifier contractAlreadySet(address _contract) {
        if (_contract != address(0)) revert AddressAlreadySet();

        _;
    }

    /*//////////////////////////////////////////////////////////////
                              Admin Setters
    //////////////////////////////////////////////////////////////*/

    /// @notice Added in 1.2.0 to set the ivotes adapter
    function setIVotesAdapter(
        address _ivotesAdapter
    ) external auth(ESCROW_ADMIN_ROLE) contractAlreadySet(ivotesAdapter) {
        ivotesAdapter = _ivotesAdapter;
    }

    /// @notice Sets the curve contract that calculates the voting power
    function setCurve(address _curve) external auth(ESCROW_ADMIN_ROLE) contractAlreadySet(curve) {
        curve = _curve;
    }

    /// @notice Sets the voter contract that tracks votes
    function setVoter(address _voter) external auth(ESCROW_ADMIN_ROLE) {
        voter = _voter;
    }

    /// @notice Sets the clock contract that manages epoch and voting periods
    function setClock(address _clock) external auth(ESCROW_ADMIN_ROLE) contractAlreadySet(clock) {
        clock = _clock;
    }

    /// @notice Sets the NFT contract that is the lock
    /// @dev By default this can only be set once due to the high risk of changing the lock
    /// and having the ability to steal user funds.
    function setLockNFT(address _nft) external auth(ESCROW_ADMIN_ROLE) {
        if (_lockNFTSet) revert LockNFTAlreadySet();
        lockNFT = _nft;
        _lockNFTSet = true;
    }

    function pause() external auth(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external auth(PAUSER_ROLE) {
        _unpause();
    }

    function setMinDeposit(uint256 _minDeposit) external auth(ESCROW_ADMIN_ROLE) {
        minDeposit = _minDeposit;
        emit MinDepositSet(_minDeposit);
    }

    /// @notice Split disabled by default, only whitelisted addresses can split.
    function setEnableSplit(
        address _account,
        bool _isWhitelisted
    ) external auth(ESCROW_ADMIN_ROLE) {
        splitWhitelisted[_account] = _isWhitelisted;
        emit SplitWhitelistSet(_account, _isWhitelisted);
    }

    /// @notice Enable split to any address without whitelisting
    function enableSplit() external auth(ESCROW_ADMIN_ROLE) {
        splitWhitelisted[SPLIT_WHITELIST_ANY_ADDRESS] = true;
        emit SplitWhitelistSet(SPLIT_WHITELIST_ANY_ADDRESS, true);
    }

    /// @notice Return true if any address is whitelisted or an `_account`.
    function canSplit(address _account) public view virtual returns (bool) {
        // Only allow split to whitelisted accounts.
        return splitWhitelisted[SPLIT_WHITELIST_ANY_ADDRESS] || splitWhitelisted[_account];
    }

    /*//////////////////////////////////////////////////////////////
                      Getters: ERC721 Functions
    //////////////////////////////////////////////////////////////*/

    function isApprovedOrOwner(address _spender, uint256 _tokenId) public view returns (bool) {
        return IERC721EMB(lockNFT).isApprovedOrOwner(_spender, _tokenId);
    }

    /// @notice Fetch all NFTs owned by an address by leveraging the ERC721Enumerable interface
    /// @param _owner Address to query
    /// @return tokenIds Array of token IDs owned by the address
    function ownedTokens(address _owner) public view returns (uint256[] memory tokenIds) {
        IERC721EMB enumerable = IERC721EMB(lockNFT);
        uint256 balance = enumerable.balanceOf(_owner);
        uint256[] memory tokens = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) {
            tokens[i] = enumerable.tokenOfOwnerByIndex(_owner, i);
        }
        return tokens;
    }

    /*///////////////////////////////////////////////////////////////
                          Getters: Voting
    //////////////////////////////////////////////////////////////*/

    /// @return The voting power of the NFT at the current block
    function votingPower(uint256 _tokenId) public view returns (uint256) {
        return votingPowerAt(_tokenId, block.timestamp);
    }

    /// @return The voting power of the NFT at a specific timestamp
    function votingPowerAt(uint256 _tokenId, uint256 _t) public view returns (uint256) {
        return IEscrowCurve(curve).votingPowerAt(_tokenId, _t);
    }

    /// @return The total voting power at the current block
    function totalVotingPower() external view returns (uint256) {
        return totalVotingPowerAt(block.timestamp);
    }

    /// @return The total voting power at a specific timestamp
    function totalVotingPowerAt(uint256 _timestamp) public view returns (uint256) {
        return IEscrowCurve(curve).supplyAt(_timestamp);
    }

    /// @return The details of the underlying lock for a given veNFT
    function locked(uint256 _tokenId) public view returns (LockedBalance memory) {
        return _locked[_tokenId];
    }

    /// @return accountVotingPower The voting power of an account at the current block
    /// @dev We cannot do historic voting power at this time because we don't current track
    /// histories of token transfers.
    function votingPowerForAccount(
        address _account
    ) external view returns (uint256 accountVotingPower) {
        uint256[] memory tokens = ownedTokens(_account);

        for (uint256 i = 0; i < tokens.length; i++) {
            accountVotingPower += votingPowerAt(tokens[i], block.timestamp);
        }
    }

    /// @notice Checks if the NFT is currently voting. We require the user to reset their votes if so.
    function isVoting(uint256 _tokenId) public view returns (bool) {
        // If token doesn't exist, it reverts.
        address owner = IERC721EMB(lockNFT).ownerOf(_tokenId);

        // If token is not delegated, delegatee wouldn't exist, so we return false.
        bool isTokenDelegated = IEscrowIVotesAdapter(ivotesAdapter).tokenIsDelegated(_tokenId);
        if (!isTokenDelegated) return false;

        // If token is delegated, it will always have a delegatee.
        address delegatee = IEscrowIVotesAdapter(ivotesAdapter).delegates(owner);

        return IAddressGaugeVoter(voter).isVoting(delegatee);
    }

    /*//////////////////////////////////////////////////////////////
                              ESCROW LOGIC
    //////////////////////////////////////////////////////////////*/

    function createLock(uint256 _value, uint256 _duration) external nonReentrant whenNotPaused returns (uint256) {
        return _createLockFor(_value, _duration, _msgSender());
    }

    /// @notice Creates a lock on behalf of someone else.
    function createLockFor(
        uint256 _value,
        uint256 _duration,
        address _to
    ) external nonReentrant whenNotPaused returns (uint256) {
        return _createLockFor(_value, _duration, _to);
    }

    /// @dev Deposit `_value` tokens for `_to` starting at next deposit interval
    /// @param _value Amount to deposit
    /// @param _duration For how long the tokens are locked in the NFT
    /// @param _to Address to deposit
    function _createLockFor(uint256 _value, uint256 _duration, address _to) internal returns (uint256) {
        if (_value == 0) revert ZeroAmount();
        if (_value < minDeposit) revert AmountTooSmall();
        uint256 maxTime = IEscrowCurve(curve).maxTime();
        if(_duration > maxTime) revert DurationTooLong();

        // query the duration lib to get the next time we can deposit
        uint256 startTime = IClock(clock).epochPrevCheckpointTs();
        // To keep LinearDecreasingCurve simple, we create a virtual timestamp <= current timestamp,
        // so that it seems that all locks were created with max duration
        uint256 virtualStartTime = _getVirtualStartTime(startTime, _duration, maxTime);

        // increment the total locked supply and get the new tokenId
        totalLocked += _value;
        uint256 newTokenId = ++lastLockId;

        // write the lock and checkpoint the voting power
        LockedBalance memory lock = LockedBalance(_value.toUint208(), virtualStartTime.toUint48());
        _locked[newTokenId] = lock;

        // we don't allow edits in this implementation, so only the new lock is used
        _checkpoint(newTokenId, LockedBalance(0, 0), lock);

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // transfer the tokens into the contract
        IERC20(token).safeTransferFrom(_msgSender(), address(this), _value);

        // we currently don't support tokens that adjust balances on transfer
        if (IERC20(token).balanceOf(address(this)) != balanceBefore + _value)
            revert TransferBalanceIncorrect();

        // Update `_to`'s delegate power.
        _moveDelegateVotes(address(0), _to, newTokenId, lock);

        // mint the NFT before and emit the event to complete the lock
        IERC721EMB(lockNFT).mint(_to, newTokenId);

        emit Deposit(_to, newTokenId, startTime, virtualStartTime, _duration, _value, totalLocked);

        return newTokenId;
    }

    function getVirtualStartTime(uint256 _startTime, uint256 _duration) external view returns(uint256) {
        uint256 maxTime = IEscrowCurve(curve).maxTime();
        return _getVirtualStartTime(_startTime, _duration, maxTime);
    }

    function _getVirtualStartTime(uint256 _startTime, uint256 _duration, uint256 _maxTime) internal view returns(uint256) {
        uint256 epochDuration = IClock(clock).epochDuration();
        // To keep LinearDecreasingCurve simple, we create a virtual timestamp <= current timestamp,
        // so that it seems that all locks were created with max duration
        return _startTime - (_maxTime - _duration) / epochDuration * epochDuration;
    }

    // TODO
    function lockPermanent(uint256 _tokenId) external {}
    // TODO
    function unlockPermanent(uint256 _tokenId) external {}
    // TODO
    function increaseAmount(uint256 _tokenId, uint256 _value) external {}
    // TODO
    function increaseUnlockTime(uint256 _tokenId, uint256 _duration) external {}


    /// @inheritdoc IMerge
    function merge(uint256 _from, uint256 _to) public whenNotPaused {
        address sender = _msgSender();

        if (_from == _to) revert SameNFT();

        address ownerFrom = IERC721EMB(lockNFT).ownerOf(_from);
        address ownerTo = IERC721EMB(lockNFT).ownerOf(_to);

        // Both nfts must have the same owner.
        if (ownerFrom != ownerTo) revert NotSameOwner();

        // sender can either be approved or owner.
        if (!isApprovedOrOwner(sender, _from) || !isApprovedOrOwner(sender, _to)) {
            revert NotApprovedOrOwner();
        }

        LockedBalance memory oldLockedFrom = _locked[_from];
        LockedBalance memory oldLockedTo = _locked[_to];

        if (!canMerge(oldLockedFrom, oldLockedTo)) {
            revert CannotMerge(_from, _to);
        }

        // We only allow merge when both tokens have the same owner.
        // After the merge, owner still should have the same voting power
        // as one token gets merged into another. For this reason,
        // We call `_moveDelegateVotes` with empty locked, so it doesn't
        // reduce/increase the same voting power for gas efficiency.
        IEscrowIVotesAdapter(ivotesAdapter).mergeDelegateVotes(
            IDelegateMoveVoteRecipient.TokenLock(ownerFrom, _from, oldLockedFrom),
            IDelegateMoveVoteRecipient.TokenLock(ownerFrom, _to, oldLockedTo)
        );

        // Update for `_from`.
        // Note that on the checkpoint, we still don't
        // remove `start` for historical reasons.
        IERC721EMB(lockNFT).burn(_from);
        _locked[_from] = LockedBalance(0, 0);
        _checkpoint(_from, oldLockedFrom, LockedBalance(0, oldLockedFrom.start));

        // update for `_to`.
        uint208 newLockedAmount = oldLockedFrom.amount + oldLockedTo.amount;
        _checkpoint(_to, oldLockedTo, LockedBalance(newLockedAmount, oldLockedTo.start));
        _locked[_to] = LockedBalance(newLockedAmount, oldLockedTo.start);

        emit Merged(sender, _from, _to, oldLockedFrom.amount, oldLockedTo.amount, newLockedAmount);
    }

    /// @inheritdoc IMerge
    function canMerge(
        LockedBalance memory _fromLocked,
        LockedBalance memory _toLocked
    ) public view returns (bool) {
        uint256 maxTime = IEscrowCurve(curve).maxTime();

        uint256 fromLockedEnd = _fromLocked.start + maxTime;
        uint256 toLockedEnd = _toLocked.start + maxTime;

        // Tokens either must have the same start dates or both must be mature.
        if (
            (_toLocked.start != _fromLocked.start) &&
            (toLockedEnd >= block.timestamp || fromLockedEnd >= block.timestamp)
        ) {
            return false;
        }

        return true;
    }

    /// @inheritdoc ISplit
    function split(uint256 _from, uint256 _value) public whenNotPaused returns (uint256) {
        if (_value == 0) revert ZeroAmount();

        address sender = _msgSender();

        // For some erc721, `ownerOf` reverts and for some,
        // it returns address(0). For safety, if it doesn't revert,
        // we also check if it's not address(0).
        address owner = IERC721EMB(lockNFT).ownerOf(_from);
        if (owner == address(0)) revert NoOwner();

        if (!canSplit(owner)) revert SplitNotWhitelisted();

        // Sender must either be approved or the owner.
        if (!isApprovedOrOwner(sender, _from)) revert NotApprovedOrOwner();

        LockedBalance memory locked_ = _locked[_from];
        if (locked_.amount <= _value) revert SplitAmountTooBig();

        // Ensure that amounts of new tokens will be greater than `minDeposit`.
        uint208 amount1 = locked_.amount - _value.toUint208();
        uint208 amount2 = _value.toUint208();
        if (amount1 < minDeposit || amount2 < minDeposit) {
            revert AmountTooSmall();
        }

        // update for `_from`.
        _checkpoint(_from, locked_, LockedBalance(amount1, locked_.start));
        _locked[_from] = LockedBalance(amount1, locked_.start);

        uint256 newTokenId = ++lastLockId;

        // owner gets minted a new tokenId. Since `split` function
        // just splits the same amount into two tokenIds, there's no need
        // to update voting power on ivotesAdapter, as total doesn't change.
        // We still call `_moveDelegateVotes` with zero LockedBalance to
        // make sure we update delegatee's token count due to newtokenId.
        IEscrowIVotesAdapter(ivotesAdapter).splitDelegateVotes(
            IDelegateMoveVoteRecipient.TokenLock(owner, _from, LockedBalance(0, 0)),
            IDelegateMoveVoteRecipient.TokenLock(owner, newTokenId, LockedBalance(0, 0))
        );

        // update for `newTokenId`.
        locked_.amount = amount2;
        _createSplitNFT(owner, newTokenId, locked_);

        emit Split(_from, newTokenId, sender, amount1, amount2);

        return newTokenId;
    }

    /// @notice creates a new token in checkpoint and mint.
    /// @param _to The address to which new token id will be minted
    /// @param _tokenId The id of the token that will be minted.
    /// @param _newLocked New locked amount / start lock time for the new token
    function _createSplitNFT(
        address _to,
        uint256 _tokenId,
        LockedBalance memory _newLocked
    ) private {
        _locked[_tokenId] = _newLocked;
        _checkpoint(_tokenId, LockedBalance(0, 0), _newLocked);
        IERC721EMB(lockNFT).mint(_to, _tokenId);
    }

    /// @notice Record per-user data to checkpoints. Used by VotingEscrow system.
    /// @param _tokenId NFT token ID.
    /// @dev Old locked balance is unused in the increasing case, at least in this implementation.
    /// @param _fromLocked New locked amount / start lock time for the user
    /// @param _newLocked New locked amount / start lock time for the user
    function _checkpoint(
        uint256 _tokenId,
        LockedBalance memory _fromLocked,
        LockedBalance memory _newLocked
    ) private {
        IEscrowCurve(curve).checkpoint(_tokenId, _fromLocked, _newLocked);
    }

    /*//////////////////////////////////////////////////////////////
                        Exit and Withdraw Logic
    //////////////////////////////////////////////////////////////*/

    // Withdrawal is only possible when lock has expired.
    // Then voting power is zero, so token cannot be voting.

    /// @notice Withdraws tokens from the contract
    function withdraw(uint256 _tokenId) external nonReentrant whenNotPaused {
        address sender = _msgSender();

        // TODO: check it can withdraw

        LockedBalance memory oldLocked = _locked[_tokenId];
        uint256 value = oldLocked.amount;

        // clear out the token data
        _locked[_tokenId] = LockedBalance(0, 0);
        totalLocked -= value;

        // Burn the NFT and transfer the tokens to the user
        IERC721EMB(lockNFT).burn(_tokenId);

        IERC20(token).safeTransfer(sender, value);

        emit Withdraw(sender, _tokenId, value, block.timestamp, totalLocked);
    }

    /// @notice withdraw excess tokens from the contract - possibly by accident
    function sweep() external nonReentrant auth(SWEEPER_ROLE) {
        // if there are extra tokens in the contract
        // balance will be greater than the total locked
        uint balance = IERC20(token).balanceOf(address(this));
        uint excess = balance - totalLocked;

        // if there isn't revert the tx
        if (excess == 0) revert NothingToSweep();

        // if there is, send them to the caller
        IERC20(token).safeTransfer(_msgSender(), excess);
        emit Sweep(_msgSender(), excess);
    }

    /// @notice the sweeper can send NFTs mistakenly sent to the contract to a designated address
    /// @param _tokenId the tokenId to sweep - must be currently in this contract
    /// @param _to the address to send the NFT to - must be a whitelisted address for transfers
    function sweepNFT(uint256 _tokenId, address _to) external nonReentrant auth(SWEEPER_ROLE) {
        // if the token id is not in the contract, revert
        if (IERC721EMB(lockNFT).ownerOf(_tokenId) != address(this)) revert NothingToSweep();

        IERC721EMB(lockNFT).transferFrom(address(this), _to, _tokenId);
        emit SweepNFT(_to, _tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                        Moving Delegation Votes Logic
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDelegateMoveVoteCaller
    function moveDelegateVotes(address _from, address _to, uint256 _tokenId) public whenNotPaused {
        if (msg.sender != lockNFT) revert OnlyLockNFT();
        LockedBalance memory locked_ = _locked[_tokenId];

        _moveDelegateVotes(_from, _to, _tokenId, locked_);
    }

    function _moveDelegateVotes(
        address _from,
        address _to,
        uint256 _tokenId,
        LockedBalance memory _lockedBalance
    ) private {
        IEscrowIVotesAdapter(ivotesAdapter).moveDelegateVotes(_from, _to, _tokenId, _lockedBalance);
    }

    function updateVotingPower(address _from, address _to) public whenNotPaused {
        if (msg.sender != ivotesAdapter) revert OnlyIVotesAdapter();

        IAddressGaugeVoter(voter).updateVotingPower(_from, _to);
    }

    /*///////////////////////////////////////////////////////////////
                            UUPS Upgrade
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the address of the implementation contract in the [proxy storage slot](https://eips.ethereum.org/EIPS/eip-1967) slot the [UUPS proxy](https://eips.ethereum.org/EIPS/eip-1822) is pointing to.
    /// @return The address of the implementation contract.
    function implementation() public view returns (address) {
        return _getImplementation();
    }

    /// @notice Internal method authorizing the upgrade of the contract via the [upgradeability mechanism for UUPS proxies](https://docs.openzeppelin.com/contracts/4.x/api/proxy#UUPSUpgradeable) (see [ERC-1822](https://eips.ethereum.org/EIPS/eip-1822)).
    function _authorizeUpgrade(address) internal virtual override auth(ESCROW_ADMIN_ROLE) {}

    /// @dev Reserved storage space to allow for layout changes in the future.
    ///      Please note that the reserved slot number in previous version(39) was set
    ///      incorrectly as 39 instead of 40. Changing it to 40 now would overwrite existing slot values,
    ///      resulting in the loss of state. Therefore, we will continue using 36 in this version.
    ///      For future versions, any new variables should be added by subtracting from 36.
    uint256[36] private __gap;
}
