// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockERC20} from "../utils/MockTokens.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthConstants as C} from "../../src/libraries/StealthConstants.sol";

/// @notice Regressions for the v2 independent review's findings (see the Stage 1 report), against v3.
contract ReviewRegressionsTest is BaseTest {

    // ---------------------------------------------------------------------
    // H-01 (v2: the token-fee conversion could be sandwiched). v3 has no conversion at all.
    // ---------------------------------------------------------------------

    /// @notice The attack surface is gone: the locker has no collect or conversion entry point, and no token fee
    ///         ever exists to convert.
    function test_H01_noConversionSurface() public {
        address token = _launch(125, 4 ether);
        for (uint256 i; i < 5; ++i) {
            uint256 got = _buy(traders[1], token, 2 ether);
            _sell(traders[1], token, got);
        }
        string[4] memory gone =
            ["collect(address)", "collectMany(address[])", "pendingFees(address)", "pendingTokenFees(address)"];
        for (uint256 i; i < gone.length; ++i) {
            (bool ok,) = address(locker).call(abi.encodeWithSignature(gone[i], token));
            assertFalse(ok, gone[i]);
        }
        assertEq(IERC20(token).balanceOf(address(locker)), 0, "no token pile");
        assertEq(IERC20(token).balanceOf(address(vault)), 0);
        (uint256 g0, uint256 g1) = _dexFeeGrowthGlobals(_poolId(token));
        assertEq(g0 + g1, 0, "no fees in the positions to convert");
    }

    // ---------------------------------------------------------------------
    // L-02
    // ---------------------------------------------------------------------

    /// @notice The admin can't change a launch's terms between signing and execution: the launch reverts.
    function test_L02_adminFrontRun_reverts() public {
        StealthFactory.LaunchParams memory p = _params(325, 4 ether, 0);
        vm.startPrank(admin);
        factory.setLaunchFee(C.MAX_LAUNCH_FEE);
        vm.stopPrank();
        vm.prank(creator);
        vm.expectRevert(StealthFactory.StaleConfig.selector);
        factory.launch{value: 1 ether}(p);
    }

    function test_L02_everySetterBumpsTheVersion() public {
        uint64 v = factory.configVersion();
        assertEq(v, 1);
        vm.startPrank(admin);
        factory.setTargetRange(4 ether, 5 ether, 10 ether);
        assertEq(factory.configVersion(), ++v);
        factory.setLaunchFee(0.01 ether);
        assertEq(factory.configVersion(), ++v);
        factory.setLaunchesPaused(false);
        assertEq(factory.configVersion(), ++v);
        factory.setUnlistedQuotesAllowed(true);
        assertEq(factory.configVersion(), ++v);
        vm.stopPrank();
        MockERC20 q = new MockERC20("Q", "Q", 18);
        vm.startPrank(admin);
        factory.listQuote(address(q), 1e18, 1e18, 2e18);
        assertEq(factory.configVersion(), ++v);
        factory.delistQuote(address(q));
        assertEq(factory.configVersion(), ++v);
        factory.proposeAdmin(creator); // not a launch term
        assertEq(factory.configVersion(), v);
        vm.stopPrank();
        vm.prank(attacker);
        vm.expectRevert(StealthFactory.NotAdmin.selector);
        factory.setLaunchFee(0);
    }

    // ---------------------------------------------------------------------
    // L-01 (accepted): the graduated flag means "the price touched the graduation line"
    // ---------------------------------------------------------------------

    /// @notice A flash round trip can set the flag, but it pays the fee on the whole curve, in the quote, both ways. The
    ///         indexer counts a graduation only if the price is still past the line when the transaction ends.
    function test_L01_flagCanBeTouched_butCostsTheFees() public {
        address t = _launch(125, 4 ether);
        StealthLocker.PoolInfo memory info = locker.getPool(t);
        uint256 budget = info.graduationQuote * 102 / 100; // the curve's ETH, grossed up for the 1.25% fee
        vm.deal(attacker, budget);
        _buy(attacker, t, budget);
        assertTrue(hook.graduated(t), "the line was touched");
        _sell(attacker, t, IERC20(t).balanceOf(attacker));
        (, uint256 raised,,) = locker.progress(t);
        assertLt(raised, 1e9, "the price is back at the start");
        uint256 cost = budget - attacker.balance;
        // The buy's 1.25% on the budget plus the sell's 1.25% on the quote it got back: about 2x fee x target.
        assertGe(cost, _vaultClaims(), "the attacker paid every fee credited");
        assertGt(cost, info.graduationQuote * 237 / 10_000, "about twice fee x target");
    }
}
