// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Dex, SqrtPriceMath} from "@dex/Dex.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PoolGeometry} from "../../src/libraries/PoolGeometry.sol";
import {StealthConstants as C} from "../../src/libraries/StealthConstants.sol";
import {MathHarness} from "../utils/Harnesses.sol";

/// @notice The curve maths, and the two liquidity positions it becomes.
contract GeometryTest is Test {
    MathHarness internal h;

    function setUp() public {
        h = new MathHarness();
    }

    // ---------------------------------------------------------------------
    // CurveMath
    // ---------------------------------------------------------------------

    function test_supplySplitIsValid() public pure {
        assertEq(C.CURVE_SUPPLY + C.POOL_SUPPLY, C.TOTAL_SUPPLY, "curve + tail = supply");
        assertGt(C.CURVE_SUPPLY, C.POOL_SUPPLY, "T must exceed L");
        assertEq(C.LAUNCH_ALLOWANCE * 20, C.TOTAL_SUPPLY, "first buy cap is 5%");
        assertEq(C.COIN_TAX_BPS, 7_000, "the coin gets 70% of its tier");
        assertEq(uint256(C.TAX_TIER_1) * C.PIPS_PER_BPS, 12_500, "1.25% in pips");
        assertEq(uint256(C.TAX_TIER_5) * C.PIPS_PER_BPS, 57_500, "5.75% in pips");
        assertEq(C.SNIPER_START_FEE, 900_000, "90% in pips");
        assertEq(C.SNIPER_WINDOW, 15);
    }

    function test_virtualReserves_4eth() public pure {
        (uint256 vEth, uint256 vToken) = CurveMath.virtualReserves(4 ether);
        assertEq(vEth, 1_333_333_333_333_333_333, "virtualEth = E/3");
        assertApproxEqRel(vToken, 1_066_666_666.666e18, 1e12);
    }

    function test_revert_curveMath() public {
        vm.expectRevert(CurveMath.CurveSplitInvalid.selector);
        h.virtualReserves(1 ether, 100, 100);
        vm.expectRevert(CurveMath.TargetZero.selector);
        h.virtualReserves(0, C.CURVE_SUPPLY, C.POOL_SUPPLY);
        vm.expectRevert(CurveMath.ReserveZero.selector);
        h.sqrtPriceX96(0, 1);
        vm.expectRevert(CurveMath.ReserveZero.selector);
        h.sqrtPriceX96(1, 0);
    }

    function test_sqrtPrice_knownValues() public pure {
        assertEq(CurveMath.sqrtPriceX96(1 ether, 1 ether), 1 << 96, "price 1");
        assertEq(CurveMath.sqrtPriceX96(1 ether, 4 ether), 2 << 96, "price 4 -> sqrt 2");
        assertEq(CurveMath.sqrtPriceX96(4 ether, 1 ether), 1 << 95, "price 1/4 -> sqrt 1/2");
    }

    function test_floorToSpacing() public pure {
        assertEq(PoolGeometry.floorToSpacing(0), 0);
        assertEq(PoolGeometry.floorToSpacing(19), 10);
        assertEq(PoolGeometry.floorToSpacing(20), 20);
        assertEq(PoolGeometry.floorToSpacing(-1), -10);
        assertEq(PoolGeometry.floorToSpacing(-10), -10);
        assertEq(PoolGeometry.floorToSpacing(-11), -20);
    }

    // ---------------------------------------------------------------------
    // PoolGeometry
    // ---------------------------------------------------------------------

    function _checkGeometry(uint256 target) internal pure {
        PoolGeometry.Geometry memory g = PoolGeometry.compute(target);
        (uint256 vEth, uint256 vToken) = CurveMath.virtualReserves(target);

        // Ticks are usable and ordered: tail < curve lower < curve upper.
        assertEq(g.curveTickUpper % C.TICK_SPACING, 0);
        assertEq(g.curveTickLower % C.TICK_SPACING, 0);
        assertEq(g.tailTickLower, Dex.minUsableTick(C.TICK_SPACING));
        assertLt(g.tailTickLower, g.curveTickLower);
        assertLt(g.curveTickLower, g.curveTickUpper);
        assertLt(g.curveTickUpper, -Dex.minUsableTick(C.TICK_SPACING));
        assertEq(g.startSqrtPriceX96, Dex.sqrtAtTick(g.curveTickUpper));
        assertEq(g.graduationSqrtPriceX96, Dex.sqrtAtTick(g.curveTickLower));

        // The positions hold (just under) 800M and 200M tokens.
        uint256 curveTokens =
            SqrtPriceMath.getAmount1Delta(g.graduationSqrtPriceX96, g.startSqrtPriceX96, g.curveLiquidity, true);
        uint256 tailTokens = SqrtPriceMath.getAmount1Delta(
            Dex.sqrtAtTick(g.tailTickLower), g.graduationSqrtPriceX96, g.tailLiquidity, true
        );
        assertLe(curveTokens, C.CURVE_SUPPLY, "curve fits its supply");
        assertLe(tailTokens, C.POOL_SUPPLY, "tail fits its supply");
        // Liquidity rounds down, leaving under a billionth of one token unplaced (it is never minted); with a
        // tiny raw target (e.g. a 6-decimal quote) one unit of liquidity is worth more token-wei, still dust.
        uint256 perUnitL = (uint256(g.startSqrtPriceX96) >> 96) + 1;
        assertGe(curveTokens, C.CURVE_SUPPLY - 1e9 - perUnitL, "curve uses its supply");
        assertGe(tailTokens, C.POOL_SUPPLY - 1e9 - perUnitL, "tail uses its supply");
        assertLt(1e9 + perUnitL, 1e13, "never more than 1e-5 of one token");

        // The curve position is the bonding curve: L = sqrt(vE * vT), ending at the target in quote.
        // Tick rounding (0.1% steps at each end) keeps both within a fraction of a percent.
        assertApproxEqRel(g.curveLiquidity, Math.sqrt(vEth * vToken), 3e15, "L = sqrt(k)");
        assertApproxEqRel(g.graduationQuote, target, 3e15, "raises the target");
    }

    function test_geometry_commonTargets() public pure {
        uint256[7] memory targets =
            [uint256(4 ether), 5 ether, 7.5 ether, 10 ether, 0.075 ether, 0.01 ether, 0.1875 ether];
        for (uint256 i; i < targets.length; ++i) {
            _checkGeometry(targets[i]);
        }
    }

    function test_geometry_absoluteBounds() public pure {
        _checkGeometry(C.MIN_TARGET_FLOOR);
        _checkGeometry(C.MAX_TARGET_CEILING);
    }

    /// @dev ERC-20 quotes: the generic bounds for every supported decimals, 0.01 to 10^12 whole units.
    function test_geometry_quoteBoundsEveryDecimals() public pure {
        for (uint256 d = C.MIN_QUOTE_DECIMALS; d <= C.MAX_QUOTE_DECIMALS; ++d) {
            _checkGeometry(10 ** (d - C.QUOTE_TARGET_MIN_EXP));
            _checkGeometry(10 ** (d + C.QUOTE_TARGET_MAX_EXP));
        }
    }

    function testFuzz_geometry_quoteRange(uint256 target) public pure {
        target = bound(target, 10 ** (C.MIN_QUOTE_DECIMALS - C.QUOTE_TARGET_MIN_EXP), 10 ** (C.MAX_QUOTE_DECIMALS + C.QUOTE_TARGET_MAX_EXP));
        _checkGeometry(target);
    }

    function testFuzz_geometry(uint256 target) public pure {
        target = bound(target, C.MIN_TARGET_FLOOR, C.MAX_TARGET_CEILING);
        _checkGeometry(target);
    }

    /// @dev The tail's depth where it takes over matches a full-range pool of (target quote, 200M tokens),
    ///      which is what a curve-then-migrate design would have created at graduation.
    function test_tailDepthMatchesAFullRangePool() public pure {
        PoolGeometry.Geometry memory g = PoolGeometry.compute(4 ether);
        uint256 fullRangeL = Math.sqrt(g.graduationQuote * C.POOL_SUPPLY);
        assertApproxEqRel(g.tailLiquidity, fullRangeL, 5e15);
    }

    function test_priceRisesSixteenfoldAcrossTheCurve() public pure {
        PoolGeometry.Geometry memory g = PoolGeometry.compute(4 ether);
        // Price in quote per token is 1 / (tokens per ETH): the ratio of sqrt prices squared.
        uint256 ratio = Math.mulDiv(uint256(g.startSqrtPriceX96), uint256(g.startSqrtPriceX96), 1)
            / Math.mulDiv(uint256(g.graduationSqrtPriceX96), uint256(g.graduationSqrtPriceX96), 1e18);
        assertApproxEqRel(ratio, 16e18, 5e15);
    }

    function test_revert_geometryTargetZero() public {
        vm.expectRevert(CurveMath.TargetZero.selector);
        h.geometry(0);
    }
}
