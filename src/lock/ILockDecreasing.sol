// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ILock} from "./ILock.sol";
import {IERC721EnumerableMintableBurnable} from "./IERC721EMB.sol";

interface ILockDecreasing is ILock, IERC721EnumerableMintableBurnable {
    function isApprovedOrOwnerOrWasOwner(address _spender, uint256 _tokenId) external view returns (bool);
    function lastOwnerOf(uint256 tokenId) external view returns (address);
}
