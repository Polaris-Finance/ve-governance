pragma solidity ^0.8.17;

import {TestHelpers} from "@helpers/TestHelpers.sol";

import {DAO} from "@mocks/MockDAO.sol";
import {
    Clock,
    CurveConstantLib,
    Curve,
    ILockedBalanceDecreasing,
    IVotingEscrowDecreasing as IVotingEscrow,
    IEscrowCurveDecreasing as IEscrowCurve
} from "../../../versions.sol";

import {ProxyLib} from "@libs/ProxyLib.sol";
import {FixedPointBase} from "../../../base/FixedPointBase.sol";

contract MockEscrow {
    address public token;
    Curve public curve;
    mapping(uint => IVotingEscrow.LockedBalanceDecreasing) locked_;

    function setCurve(Curve _curve) external {
        curve = _curve;
    }

    function setLocked(uint256 _tokenId, IVotingEscrow.LockedBalanceDecreasing memory _locked) external {
        locked_[_tokenId] = _locked;
    }

    function checkpoint(
        uint256 _tokenId,
        IVotingEscrow.LockedBalanceDecreasing memory _oldLocked,
        IVotingEscrow.LockedBalanceDecreasing memory _newLocked
    ) external {
        locked_[_tokenId] = _newLocked;
        return curve.checkpoint(_tokenId, _oldLocked, _newLocked);
    }

    function locked(uint256 _tokenId) external view returns (IVotingEscrow.LockedBalanceDecreasing memory) {
        return locked_[_tokenId];
    }
}

contract CurveBase is TestHelpers, FixedPointBase, ILockedBalanceDecreasing {
    using ProxyLib for address;
    Curve internal curve;
    MockEscrow internal escrow;
    Clock internal clock;

    function setUp() public virtual override {
        super.setUp();
        escrow = new MockEscrow();

        address clockImpl = address(new Clock());
        bytes memory initClockCalldata = abi.encodeWithSelector(Clock.initialize.selector, dao);
        clock = Clock(clockImpl.deployUUPSProxy(initClockCalldata));

        (int256 constantCoefficient, int256 linearDenominator, uint256 maxEpochs) = CurveConstantLib.getParams();
        address impl = address(new Curve(constantCoefficient, linearDenominator, maxEpochs));

        bytes memory initCalldata = abi.encodeCall(
            Curve.initialize,
            (address(escrow), address(dao), address(clock))
        );

        curve = Curve(impl.deployUUPSProxy(initCalldata));

        // grant this address admin privileges
        DAO(payable(address(dao))).grant({
            _who: address(this),
            _where: address(curve),
            _permissionId: curve.CURVE_ADMIN_ROLE()
        });

        DAO(payable(address(dao))).grant({
            _who: address(this),
            _where: address(clock),
            _permissionId: clock.CLOCK_ADMIN_ROLE()
        });

        escrow.setCurve(curve);
        FixedPointBase.initialize(curve.maxTime(), clock.checkpointInterval(), linearDenominator);
    }

    function _getEmptyLockedBalance() internal pure returns (LockedBalanceDecreasing memory) {}
    function _lockedBalanceToDecreasing(LockedBalance memory _b) internal returns (LockedBalanceDecreasing memory) {
        return LockedBalanceDecreasing(_b, _b.start);
    }
    function _lockedBalanceToDecreasing(uint208 _amount, uint48 _start) internal returns (LockedBalanceDecreasing memory) {
        return LockedBalanceDecreasing(LockedBalance(_amount, _start), uint256(_start));
    }
}
