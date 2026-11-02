// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Dex, SqrtPriceMath, LiquidityAmounts} from "@dex/Dex.sol";
import {CurveMath} from "./CurveMath.sol";
import {StealthConstants as C} from "./StealthConstants.sol";

/// @title PoolGeometry
/// @notice Turns a graduation target into the two locked liquidity positions that make up a Stealth pool.
/// @dev Pool price is tokens per quote unit (the quote is currency0). Buying tokens lowers the price.
///      A constant-product curve with virtual reserves (vQ, vT) is exactly a concentrated-liquidity position
///      with L = sqrt(vQ * vT) between the curve's start and end prices, so:
///        - the curve position holds 800M tokens between the start price and the graduation price, and holds
///          the target in quote once the price reaches the graduation price;
///        - the tail position holds the other 200M tokens from the graduation price down to the pool's limit.
///      Both start out as tokens only. Ticks are rounded down to the tick spacing. The maths is in raw units of
///      the quote, so it is the same for the native coin and for an ERC-20 of any supported decimals.
library PoolGeometry {
    struct Geometry {
        uint160 startSqrtPriceX96; // launch price: the curve position's upper tick
        uint160 graduationSqrtPriceX96; // the curve position's lower tick
        int24 curveTickLower;
        int24 curveTickUpper;
        int24 tailTickLower;
        uint128 curveLiquidity;
        uint128 tailLiquidity;
        uint256 graduationQuote; // quote the curve position holds at the graduation price (net of fees)
    }

    error TicksCollapsed();

    function compute(uint256 target) internal pure returns (Geometry memory g) {
        (uint256 vQuote, uint256 vToken) = CurveMath.virtualReserves(target);
        uint160 startExact = CurveMath.sqrtPriceX96(vQuote, vToken);
        uint160 graduationExact = CurveMath.sqrtPriceX96(vQuote + target, vToken - C.CURVE_SUPPLY);

        g.curveTickUpper = floorToSpacing(Dex.tickAtSqrt(startExact));
        g.curveTickLower = floorToSpacing(Dex.tickAtSqrt(graduationExact));
        g.tailTickLower = Dex.minUsableTick(C.TICK_SPACING);
        if (g.curveTickLower >= g.curveTickUpper || g.tailTickLower >= g.curveTickLower) revert TicksCollapsed();

        g.startSqrtPriceX96 = Dex.sqrtAtTick(g.curveTickUpper);
        g.graduationSqrtPriceX96 = Dex.sqrtAtTick(g.curveTickLower);

        g.curveLiquidity = LiquidityAmounts.getLiquidityForAmount1(
            g.graduationSqrtPriceX96, g.startSqrtPriceX96, C.CURVE_SUPPLY - C.SEED_ROUNDING_BUFFER
        );
        g.tailLiquidity = LiquidityAmounts.getLiquidityForAmount1(
            Dex.sqrtAtTick(g.tailTickLower), g.graduationSqrtPriceX96, C.POOL_SUPPLY - C.SEED_ROUNDING_BUFFER
        );
        g.graduationQuote =
            SqrtPriceMath.getAmount0Delta(g.graduationSqrtPriceX96, g.startSqrtPriceX96, g.curveLiquidity, false);
    }

    /// @notice Rounds a tick down to a multiple of the tick spacing.
    function floorToSpacing(int24 tick) internal pure returns (int24) {
        int24 compressed = tick / C.TICK_SPACING;
        if (tick < 0 && tick % C.TICK_SPACING != 0) compressed--;
        return compressed * C.TICK_SPACING;
    }
}
