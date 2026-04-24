pragma solidity ^0.8.17;

// imports file allows for copying test suite independently for different modules of ve
// import files here in your tests instead of from src

// params
import {CurveConstantLib} from "@libs/CurveConstantLibDecreasing.sol";

// contracts
import {
    Clock,
    Lock,
    Curve,
    VotingEscrow,
    EscrowIVotesAdapter,
    GaugeVoter,
    GaugeVoterSetupDecreasing as GaugeVoterSetup
} from "@setup/GaugeVoterSetupDecreasing.sol";
import {
    GaugesDaoFactoryDecreasing as GaugesDaoFactory,
    Deployment,
    DeploymentParameters,
    TokenParameters,
    GaugePluginSet
} from "@factory/GaugesDaoFactoryDecreasing.sol";

// interfaces
import {IClockV1_2_0 as IClock} from "@clock/IClock_v1_2_0.sol";
import {IGaugeVoterSetupParams} from "@setup/GaugeVoterSetupDecreasing.sol";
import {
    IEscrowCurveGlobalStorage,
    IEscrowCurveDecreasing,
    IEscrowCurveTokenStorage,
    IDeprecated
} from "@curve/IEscrowCurveDecreasing.sol";
import {ILock, IWhitelistErrors, IWhitelistEvents} from "@lock/ILock.sol";
import {
    IMerge,
    ISplit,
    IVotingEscrowDecreasing,
    ILockedBalanceIncreasing,
    IVotingEscrowEventsStorageErrorsEvents,
    IVotingEscrowCoreErrors,
    IMergeEventsAndErrors,
    ISplitEventsAndErrors,
    IVotingEscrowCore,
    IDelegateMoveVoteCaller
} from "@escrow/IVotingEscrowDecreasing.sol";

import {
    IAddressGaugeVote as IGaugeVote,
    IAddressGaugeVoterStorageEventsErrors as IGaugeVoterStorageEventsErrors
} from "@voting/IAddressGaugeVoter.sol";
import {
    IEscrowIVotesAdapterStorage,
    IEscrowIVotesAdapterErrorsAndEvents,
    IEscrowIVotesAdapter
} from "@delegation/IEscrowIVotesAdapter.sol";

// other
import {DeployGaugesV1_4_0 as DeployGauges} from "script/deploy/DeployGauges_v1_4_0.s.sol";

// deprecated but to avoid rewriting all tests
// housekeeping: remove these as we go
import {
    GaugeVoter as SimpleGaugeVoter,
    GaugeVoterSetupDecreasing as SimpleGaugeVoterSetup,
    IGaugeVoterSetupParams as ISimpleGaugeVoterSetupParams
} from "@setup/GaugeVoterSetupDecreasing.sol";

import {
    IAddressGaugeVoterStorageEventsErrors as ISimpleGaugeVoterStorageEventsErrors
} from "@voting/IAddressGaugeVoter.sol";
