// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Dex, FullMath} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MathHarness} from "../utils/Harnesses.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {PoolGeometry} from "../../src/libraries/PoolGeometry.sol";
import {StealthConstants as C} from "../../src/libraries/StealthConstants.sol";
import {StealthDeploy} from "../../script/lib/StealthDeploy.sol";

/// @notice The rarely taken branches, each on purpose.
contract EdgePathsTest is BaseTest {
    /// @dev A 1-wei exact-in buy: the fee rounds up to the whole wei, so nothing is swapped and nothing is free.
    function test_dustBuy_feeTakesTheWholeWei() public {
        address token = _launch(125, 4 ether);
        uint256 c0 = _vaultClaims();
        uint256 got = _buy(traders[0], token, 1);
        assertEq(got, 0);
        assertEq(_vaultClaims() - c0, 1, "the wei went to the vault as the fee");
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE));
    }

    /// @dev A sell too small to pay out any quote pays no fee and gets nothing.
    function test_dustSell_noQuoteNoFee() public {
        address token = _launch(125, 4 ether);
        _buy(traders[0], token, 1 ether);
        uint256 c0 = _vaultClaims();
        uint256 got = _sell(traders[0], token, 1);
        assertEq(got, 0);
        assertEq(_vaultClaims(), c0);
    }

    function test_currentFee_unknownTokenIsZero() public view {
        assertEq(hook.currentFee(address(0xdead)), 0);
        assertEq(hook.sniperWindowEnd(address(0xdead)), 0);
    }

    /// @dev The geometry refuses a curve that would run off the bottom of the tick range. Only reachable with an
    ///      absurd target (~7e64 wei), far past the factory's target ceilings, but the check is live.
    function test_revert_geometry_ticksCollapsed() public {
        MathHarness h = new MathHarness();
        // Graduation price = poolSupply / target (token per quote unit); put it a few ticks above the minimum tick.
        uint256 s = Dex.sqrtAtTick(-887_265);
        uint256 target = FullMath.mulDiv(C.POOL_SUPPLY, 1 << 192, s * s);
        vm.expectRevert(PoolGeometry.TicksCollapsed.selector);
        h.geometry(target);
    }

    function test_revert_factoryConstructor_launchFee() public {
        StealthFactory.Config memory cfg = StealthDeploy.config(4 ether, 4 ether, 10 ether);
        cfg.launchFee = uint96(C.MAX_LAUNCH_FEE + 1);
        _mockWiringForNextFactory();
        vm.expectRevert(StealthFactory.OutOfRange.selector);
        _newFactory(cfg);

        // With a valid config the mocked wiring is accepted, so the revert above came from the config.
        _mockWiringForNextFactory();
        assertEq(_newFactory(StealthDeploy.config(4 ether, 4 ether, 10 ether)).admin(), admin);
        vm.clearMockedCalls();
    }

    /// @dev A failed CREATE still uses a nonce, so the address is predicted again before every attempt.
    function _mockWiringForNextFactory() internal {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.mockCall(address(locker), abi.encodeWithSignature("factory()"), abi.encode(next));
        vm.mockCall(address(vault), abi.encodeWithSignature("factory()"), abi.encode(next));
        vm.mockCall(address(tokenDeployer), abi.encodeWithSignature("factory()"), abi.encode(next));
    }

    function _newFactory(StealthFactory.Config memory cfg) internal returns (StealthFactory) {
        return new StealthFactory(admin, address(locker), address(vault), address(tokenDeployer), 4 ether, 10 ether, cfg);
    }
}
