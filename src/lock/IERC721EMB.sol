// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    IERC721EnumerableUpgradeable as IERC721Enumerable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/IERC721EnumerableUpgradeable.sol";

interface IERC721EnumerableMintableBurnable is IERC721Enumerable {
    function mint(address to, uint256 tokenId) external;

    function burn(uint256 tokenId) external;

    function isApprovedOrOwner(address spender, uint256 tokenId) external view returns (bool);
}
