// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {StealthConstants as C} from "./StealthConstants.sol";

/// @title CurveMath
/// @notice The constant-product bonding curve a Stealth pool's liquidity is shaped to.
/// @dev Amounts of the quote currency (the native coin or an ERC-20) are in its raw units. Price along the curve is
///      (virtualQuote + quoteRaised) / (virtualToken - tokensSold). The virtual reserves are chosen so the curve
///      ends, after selling `curveSupply` tokens for `target` quote, at the price E / L where the remaining L tokens
///      take over.
library CurveMath {
    error CurveSplitInvalid();
    error TargetZero();
    error ReserveZero();

    /// @notice Virtual reserves for a curve that sells `curveSupply` and leaves `poolSupply` for the tail.
    /// @dev virtualQuote = L*E/(T-L), virtualToken = T + L*(virtualQuote+E)/E. Both round down.
    function virtualReserves(uint256 target, uint256 curveSupply, uint256 poolSupply)
        internal
        pure
        returns (uint256 virtualQuote, uint256 virtualToken)
    {
        if (curveSupply <= poolSupply) revert CurveSplitInvalid();
        if (target == 0) revert TargetZero();
        virtualQuote = Math.mulDiv(poolSupply, target, curveSupply - poolSupply);
        virtualToken = curveSupply + Math.mulDiv(poolSupply, virtualQuote + target, target);
    }

    /// @notice Virtual reserves for the protocol's supply split.
    function virtualReserves(uint256 target) internal pure returns (uint256 virtualQuote, uint256 virtualToken) {
        return virtualReserves(target, C.CURVE_SUPPLY, C.POOL_SUPPLY);
    }

    /// @notice sqrtPriceX96 of a pool whose currency0 is the quote and currency1 the token.
    /// @dev Pool price is currency1 per currency0, so this is sqrt(tokenReserve / quoteReserve) * 2^96. Every Stealth
    ///      token's address is above its quote's, so the quote is always currency0.
    ///      A ratio of 2^64 or more (more than ~1.8e19 token-wei per raw quote unit: small raw targets, e.g. an
    ///      ERC-20 quote with 6 decimals) would overflow the Q192 form, so it is taken as sqrt(ratio * 2^128) * 2^32,
    ///      which still keeps at least 96 significant bits. Below 2^64 the result is the exact floor, as before.
    function sqrtPriceX96(uint256 quoteReserve, uint256 tokenReserve) internal pure returns (uint160) {
        if (quoteReserve == 0 || tokenReserve == 0) revert ReserveZero();
        if (quoteReserve > type(uint256).max >> 64 || tokenReserve < quoteReserve << 64) {
            return SafeCast.toUint160(Math.sqrt(Math.mulDiv(tokenReserve, 1 << 192, quoteReserve)));
        }
        return SafeCast.toUint160(Math.sqrt(Math.mulDiv(tokenReserve, 1 << 128, quoteReserve)) << 32);
    }
}
