// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDexManager, PoolKey, BalanceDelta} from "@dex/Dex.sol";
import {BaseTest} from "./BaseTest.sol";
import {SwapQuoter} from "./SwapQuoter.sol";
import {MockERC20} from "./MockTokens.sol";

/// @notice What a DEX's own admin can do with a protocol fee: the pool keeps that cut (prices get slightly worse), but
///         the hook's fee, the PartialFill rule, quotes and books stay exact. Each build says how its fee is switched on.
abstract contract ProtocolFeeBase is BaseTest {
    /// @dev Sets the DEX's largest protocol fee on `key`'s pool and returns the value slot0 must show.
    function _setMaxProtocolFee(PoolKey memory key) internal virtual returns (uint24);

    function test_protocolFee_hookFeeAndBooksStayExact() public {
        _protocolFeeRun(address(0), 1 ether);
    }

    function test_protocolFee_erc20Quote() public {
        MockERC20 q = _listedQuote("QT", 6, 1, 1_000);
        _protocolFeeRun(address(q), 1e6);
    }

    function _protocolFeeRun(address quote, uint256 u) internal {
        address token = quote == address(0) ? _launch(TAX, 4 * u) : _launchQuote(creator, quote, TAX, 4 * u, 0);
        _skipSniperWindow(token);
        PoolKey memory key = _key(token);
        uint24 expected = _setMaxProtocolFee(key);
        (,, uint24 protocolFee,) = _getSlot0(_poolId(token));
        assertEq(protocolFee, expected, "the DEX's maximum, each way");

        SwapQuoter quoter = new SwapQuoter(manager);
        address t = traders[0];
        _fundQuote(token, t, 100 * u);
        // exact-in buy: the trader pays exactly G, the hook takes ceil(tier G), the pool (protocol fee inside) the rest
        (, uint256 qOut) = quoter.quote(key, IDexManager.SwapParams(true, -int256(u), MIN_PRICE_LIMIT));
        uint256 c0 = _vaultClaims(key.currency0);
        BalanceDelta d = _swap(t, token, true, -int256(u), u);
        assertEq(uint256(uint128(d.amount1())), qOut, "quote == fill");
        assertEq(_vaultClaims(key.currency0) - c0, _feeOnInput(u, TAX_PIPS), "hook fee unchanged");
        // exact-out sell: exactly X out, hook fee on top
        c0 = _vaultClaims(key.currency0);
        d = _sellExactOut(t, token, u / 10);
        assertEq(uint256(uint128(d.amount0())), u / 10);
        assertEq(_vaultClaims(key.currency0) - c0, _feeOnTop(u / 10, TAX_PIPS));
        // exact-out buy and exact-in sell: fee on the pool's quote amount
        c0 = _vaultClaims(key.currency0);
        d = _buyExactOut(t, token, 1_000_000e18, u);
        uint256 fee = _vaultClaims(key.currency0) - c0;
        assertEq(fee, _feeOnTop(uint256(uint128(-d.amount0())) - fee, TAX_PIPS));
        c0 = _vaultClaims(key.currency0);
        uint256 got = _sell(t, token, IERC20(token).balanceOf(t) / 2);
        fee = _vaultClaims(key.currency0) - c0;
        assertEq(fee, _feeOnInput(got + fee, TAX_PIPS));
        assertEq(_vaultClaims(key.currency0), vault.totalOwed(key.currency0), "books exact");
        assertGt(manager.protocolFeesAccrued(key.currency0) + manager.protocolFeesAccrued(key.currency1), 0);
        assertEq(_positionLiquidityOf(token, CURVE_SALT), locker.getPool(token).curveLiquidity, "positions untouched");
    }
}
