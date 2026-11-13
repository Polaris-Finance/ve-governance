/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC721EnumerableMintableBurnable as IERC721EMB} from "@lock/IERC721EMB.sol";

import {RewardsDistributor} from "../../../src/rewards/RewardsDistributor.sol";
import {RewardsClaimAggregator} from "../../../src/rewards/RewardsClaimAggregator.sol";

import {MockERC20} from "@mocks/MockERC20.sol";

import {Test} from "forge-std/Test.sol";

contract RewardsBase is Test {
    RewardsClaimAggregator public aggregator;
    RewardsDistributor public distributor1;
    RewardsDistributor public distributor2;
    RewardsDistributor public distributor3;
    MockERC20 public rewardsToken1;
    MockERC20 public rewardsToken2;
    MockERC20 public rewardsToken3;
    address public rewardsSender;
    RewardsDistributor[3] public rewardsDistributors;
    MockERC20[3] public rewardsTokens;

    function deployRewardsDistributors(address _escrowAddress) public {
        rewardsSender = makeAddr("Rewards Sender");

        rewardsToken1 = new MockERC20();
        rewardsToken2 = new MockERC20();
        rewardsToken3 = new MockERC20();

        aggregator = new RewardsClaimAggregator(_escrowAddress);
        distributor1 = new RewardsDistributor(_escrowAddress, address(rewardsToken1), rewardsSender);
        distributor2 = new RewardsDistributor(_escrowAddress, address(rewardsToken2), rewardsSender);
        distributor3 = new RewardsDistributor(_escrowAddress, address(rewardsToken3), rewardsSender);
        vm.label(address(distributor1), "Distributor1");
        vm.label(address(distributor2), "Distributor2");
        vm.label(address(distributor3), "Distributor3");

        rewardsDistributors = [distributor1, distributor2, distributor3];
        rewardsTokens = [rewardsToken1, rewardsToken2, rewardsToken3];
    }

    function approveAggregator(IERC721EMB _lockNFT, address _account) public {
        vm.prank(_account);
        _lockNFT.setApprovalForAll(address(aggregator), true);
    }
}
