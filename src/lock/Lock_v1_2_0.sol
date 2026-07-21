/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ILock} from "./ILock.sol";
import {
    ERC721EnumerableUpgradeable as ERC721Enumerable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable as ReentrancyGuard
} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    DaoAuthorizableUpgradeable as DaoAuthorizable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {
    IVotingEscrowIncreasingV1_2_0 as IVotingEscrow
} from "@escrow/IVotingEscrowIncreasing_v1_2_0.sol";

/// @dev Minimal, swappable on-chain metadata renderer (implemented by Polaris' PolarisNFTDescriptor).
interface ILockNFTDescriptor {
    function renderLock(uint256 tokenId, uint256 amount, uint256 votingPower)
        external
        view
        returns (string memory);
}

/// @title NFT representation of an escrow locking mechanism
contract LockV1_2_0 is ILock, ERC721Enumerable, UUPSUpgradeable, DaoAuthorizable, ReentrancyGuard {
    /// @dev enables transfers without whitelisting
    address public constant WHITELIST_ANY_ADDRESS =
        address(uint160(uint256(keccak256("WHITELIST_ANY_ADDRESS"))));

    /// @notice role to upgrade this contract
    bytes32 public constant LOCK_ADMIN_ROLE = keccak256("LOCK_ADMIN");

    /// @notice Address of the escrow contract that holds underyling assets
    address public escrow;

    /// @notice Whitelisted contracts that are allowed to transfer
    mapping(address => bool) public whitelisted;

    /// @notice Governance-swappable on-chain metadata renderer. While unset, `tokenURI` returns "".
    address public descriptor;

    event DescriptorSet(address indexed descriptor);

    /*//////////////////////////////////////////////////////////////
                              Modifiers
    //////////////////////////////////////////////////////////////*/

    modifier onlyEscrow() {
        if (msg.sender != escrow) revert OnlyEscrow();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                ERC165
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(
        bytes4 _interfaceId
    ) public view override(ERC721Enumerable) returns (bool) {
        return super.supportsInterface(_interfaceId) || _interfaceId == type(ILock).interfaceId;
    }

    /*//////////////////////////////////////////////////////////////
                              Initializer
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _escrow,
        string memory _name,
        string memory _symbol,
        address _dao
    ) external initializer {
        __ERC721_init(_name, _symbol);
        __DaoAuthorizableUpgradeable_init(IDAO(_dao));
        __ReentrancyGuard_init();
        escrow = _escrow;

        // allow sending nfts to the escrow
        whitelisted[escrow] = true;
        emit WhitelistSet(address(escrow), true);
    }

    /// @notice Point the veNFT at a new on-chain metadata renderer. Governance only.
    function setDescriptor(address _descriptor) external auth(LOCK_ADMIN_ROLE) {
        descriptor = _descriptor;
        emit DescriptorSet(_descriptor);
    }

    /// @notice Fully on-chain, dynamically-rendered token URI. Reads live lock state from the escrow
    ///         and delegates to the swappable descriptor.
    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        _requireMinted(_tokenId);
        if (descriptor == address(0)) return "";
        IVotingEscrow e = IVotingEscrow(escrow);
        return
            ILockNFTDescriptor(descriptor).renderLock(_tokenId, e.locked(_tokenId).amount, e.votingPower(_tokenId));
    }

    /*//////////////////////////////////////////////////////////////
                              Transfers
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfers disabled by default, whitelisted addresses are allowed to be involved in transfers
    function setWhitelisted(address _account, bool _isWhitelisted) external auth(LOCK_ADMIN_ROLE) {
        if (_account == escrow) revert ForbiddenWhitelistAddress();
        whitelisted[_account] = _isWhitelisted;
        emit WhitelistSet(_account, _isWhitelisted);
    }

    /// @notice Enable transfers to any address without whitelisting
    function enableTransfers() external auth(LOCK_ADMIN_ROLE) {
        whitelisted[WHITELIST_ANY_ADDRESS] = true;
        emit WhitelistSet(WHITELIST_ANY_ADDRESS, true);
    }

    /// @dev Override the transfer to check if the recipient is whitelisted
    /// This avoids needing to check for mint/burn but is less idomatic than beforeTokenTransfer
    function _transfer(address _from, address _to, uint256 _tokenId) internal override {
        if (whitelisted[WHITELIST_ANY_ADDRESS] || whitelisted[_to] || whitelisted[_from]) {
            super._transfer(_from, _to, _tokenId);
        } else {
            revert NotWhitelisted();
        }
        
        if(_from != _to) {
            IVotingEscrow(escrow).moveDelegateVotes(_from, _to, _tokenId);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              NFT Functions
    //////////////////////////////////////////////////////////////*/

    function isApprovedOrOwner(address _spender, uint256 _tokenId) external view returns (bool) {
        return _isApprovedOrOwner(_spender, _tokenId);
    }

    /// @notice Minting and burning functions that can only be called by the escrow contract
    /// @dev Safe mint ensures contract addresses are ERC721 Receiver contracts
    function mint(address _to, uint256 _tokenId) external onlyEscrow nonReentrant {
        _safeMint(_to, _tokenId);
    }

    /// @notice Minting and burning functions that can only be called by the escrow contract
    function burn(uint256 _tokenId) external onlyEscrow nonReentrant {
        _burn(_tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                              UUPS Upgrade
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the address of the implementation contract in the [proxy storage slot](https://eips.ethereum.org/EIPS/eip-1967) slot the [UUPS proxy](https://eips.ethereum.org/EIPS/eip-1822) is pointing to.
    /// @return The address of the implementation contract.
    function implementation() public view returns (address) {
        return _getImplementation();
    }

    /// @notice Internal method authorizing the upgrade of the contract via the [upgradeability mechanism for UUPS proxies](https://docs.openzeppelin.com/contracts/4.x/api/proxy#UUPSUpgradeable) (see [ERC-1822](https://eips.ethereum.org/EIPS/eip-1822)).
    function _authorizeUpgrade(address) internal virtual override auth(LOCK_ADMIN_ROLE) {}

    /// @dev Reserved storage space to allow for layout changes in the future.
    /// @dev Reduced from 48 -> 47 when `descriptor` was added (upgrade-safe: new var takes a gap slot).
    uint256[47] private __gap;
}
