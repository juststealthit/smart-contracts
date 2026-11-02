// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthHook} from "../../src/StealthHook.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthConstants as C} from "../../src/libraries/StealthConstants.sol";

/// @notice The five tax tiers: only they launch, the default is the lowest, and a tier never changes.
contract TiersTest is BaseTest {
    uint16[5] internal tiers = [125, 225, 325, 425, 575];

    function _isTier(uint16 bps) internal view returns (bool) {
        for (uint256 i; i < tiers.length; ++i) {
            if (tiers[i] == bps) return true;
        }
        return false;
    }

    function test_tiers_constants() public view {
        assertEq(C.TAX_TIER_1, tiers[0]);
        assertEq(C.TAX_TIER_2, tiers[1]);
        assertEq(C.TAX_TIER_3, tiers[2]);
        assertEq(C.TAX_TIER_4, tiers[3]);
        assertEq(C.TAX_TIER_5, tiers[4]);
        assertEq(C.COIN_TAX_BPS, 7_000, "the coin gets 70% of its tier");
    }

    function test_tiers_everyTierLaunchesAndCharges() public {
        for (uint256 i; i < tiers.length; ++i) {
            address token = _launch(tiers[i], TARGET);
            uint24 rate = uint24(tiers[i]) * 100;
            assertEq(hook.currentFee(token), rate, "the tier after the sniper window");
            assertEq(hook.getConfig(token).taxFee, rate);
            assertEq(locker.getPool(token).taxBps, tiers[i]);
            uint256 before = _vaultClaims();
            _buy(traders[i], token, 1 ether);
            assertEq(_vaultClaims() - before, _feeOnInput(1 ether, rate), "the trade paid the tier");
            vm.warp(block.timestamp); // keep the window closed for the next launch's own check
        }
    }

    function test_tiers_zeroMeansTheDefaultTier() public {
        vm.prank(creator);
        address token = factory.launch(_params(0, TARGET, 0));
        assertEq(hook.getConfig(token).taxFee, 12_500, "default 1.25%");
    }

    function testFuzz_tiers_nothingElseLaunches(uint16 bps) public {
        vm.assume(bps != 0 && !_isTier(bps));
        vm.prank(creator);
        vm.expectRevert(StealthFactory.InvalidTax.selector);
        factory.launch(_params(bps, TARGET, 0));
    }

    function test_tiers_hookRefusesAnythingElse() public {
        vm.prank(address(locker));
        vm.expectRevert(StealthHook.InvalidFee.selector);
        hook.register(makeAddr("t"), _reg(50_000, 1 << 96, 1 << 95));
    }

    /// @notice The tier stays through graduation and any amount of time: there is no schedule and no setter.
    function test_tiers_lockedForLife() public {
        address token = _launch(575, TARGET);
        _graduate(token, traders[0]);
        assertEq(hook.currentFee(token), 57_500, "graduation changes nothing");
        vm.warp(block.timestamp + 3650 days);
        assertEq(hook.currentFee(token), 57_500, "time changes nothing");
    }
}
