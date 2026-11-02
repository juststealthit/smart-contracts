// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Dex, PoolKey, BalanceDelta, Currency} from "@dex/Dex.sol";
import {BaseTest} from "./BaseTest.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthToken} from "../../src/StealthToken.sol";
import {UniversalRouterLib as UR, IUniversalRouter, IPermit2} from "@dex/UniversalRouterLib.sol";

/// @notice A Stealth pool traded through the DEX's own periphery: its Universal Router (the path wallets, the DEX's UI
///         and aggregators use), Permit2 and its quoter. Launches, then trades in all four swap modes, checking every
///         quote against the fill and every fee against the formula. Runs locally against the etched production
///         bytecode (test/unit/Routing.t.sol) and on live forks (test/fork/Routing.fork.t.sol), for native pairs and
///         ERC-20 pairs.
abstract contract RoutingBase is BaseTest {
    
    address internal token;
    PoolKey internal key;
    /// @dev address(0) for a native pair.
    address internal quoteToken;
    /// @dev One whole unit of the quote (1e18 for native, 10^decimals for an ERC-20); amounts below scale with it.
    uint256 internal unit;

    /// @dev The quote to pair with; override for an ERC-20 pair.
    function _makeQuote() internal virtual returns (address) {
        return address(0);
    }

    function setUp() public virtual override {
        super.setUp();
        quoteToken = _makeQuote();
        if (quoteToken == address(0)) {
            unit = 1 ether;
            token = _launchWith(creator, TAX, 4 ether, 0.5 ether);
        } else {
            unit = 10 ** IERC20Metadata(quoteToken).decimals();
            vm.prank(admin);
            factory.listQuote(quoteToken, unit, 4 * unit, 1_000_000_000 * unit);
            _syncConfig();
            token = _launchQuote(creator, quoteToken, TAX, 4 * unit, unit / 2);
        }
        key = locker.poolKey(token);
        for (uint256 i; i < traders.length; ++i) {
            if (quoteToken != address(0)) _fundQuote(token, traders[i], 1_000 * unit);
        }
        if (quoteToken != address(0)) _fundQuote(token, sniper, 1_000 * unit);
    }

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    function test_routing_wiring() public view {
        assertGt(_dexRouter().code.length, 0);
        assertGt(_dexQuoter().code.length, 0);
        assertGt(_dexPermit2().code.length, 0);
        assertEq(Currency.unwrap(key.currency0), quoteToken, "the quote is currency0");
        assertEq(Currency.unwrap(key.currency1), token);
    }

    function test_routing_launch() public view {
        StealthLocker.PoolInfo memory info = locker.getPool(token);
        (uint256 quoted,) = locker.quoteLaunchBuy(4 * unit, TAX, unit / 2);
        assertEq(IERC20(token).balanceOf(creator), quoted, "first buy as quoted");
        (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) = _getSlot0(_poolId(token));
        assertLt(sqrtPriceX96, info.startSqrtPriceX96, "the first buy moved the price");
        assertEq(lpFee, 0, "no LP fee: the hook takes the fee");
        assertEq(protocolFee, 0, "no protocol fee on a static 0-fee pool");
        assertEq(hook.currentFee(token), 900_000, "sniper fee right after launch");
        assertEq(_poolLiquidity(_poolId(token)), info.curveLiquidity);
        assertEq(StealthToken(token).poolId(), _poolId(token));
    }

    /// @notice The DEX's quoter runs the hook, so its quotes equal the fills in all four modes, in the sniper
    ///         window and after it.
    function test_routing_quoterMatchesAllFourModes() public {
        uint256 q = _quoteIn(true, unit / 10);
        assertEq(_buy(traders[0], token, unit / 10), q, "sniper-window exact-in buy");
        _skipSniperWindow(token);

        q = _quoteIn(true, unit);
        uint256 got = _buy(traders[1], token, unit);
        assertEq(got, q, "exact-in buy");

        q = _quoteIn(false, got / 3);
        assertEq(_sell(traders[1], token, got / 3), q, "exact-in sell");

        uint256 quoteIn = _quoteOut(true, 1_000_000e18);
        BalanceDelta d = _buyExactOut(traders[2], token, 1_000_000e18, unit);
        assertEq(uint256(uint128(-d.amount0())), quoteIn, "exact-out buy");

        uint256 tokensIn = _quoteOut(false, unit / 20);
        d = _sellExactOut(traders[1], token, unit / 20);
        assertEq(uint256(uint128(-d.amount1())), tokensIn, "exact-out sell");
        assertEq(uint256(uint128(d.amount0())), unit / 20);
    }

    /// @notice All four modes through the Universal Router; every fee in the quote, to the fee vault.
    function test_routing_universalRouter_allFourModes() public {
        _skipSniperWindow(token);
        address t = traders[3];
        Currency q = key.currency0;

        // Exact-in buy.
        uint256 quoted = _quoteIn(true, unit / 2);
        uint256 c0 = _vaultClaims(q);
        uint256 before = IERC20(token).balanceOf(t);
        _urExactIn(t, true, unit / 2, quoted);
        assertEq(IERC20(token).balanceOf(t) - before, quoted, "router buy as quoted");
        assertEq(_vaultClaims(q) - c0, _feeOnInput(unit / 2, TAX_PIPS), "the tier of the quote in");

        // Exact-in sell, paid through Permit2.
        uint256 sellAmount = IERC20(token).balanceOf(t) / 2;
        quoted = _quoteIn(false, sellAmount);
        uint256 qBefore = _quoteBalance(token, t);
        c0 = _vaultClaims(q);
        _urExactIn(t, false, sellAmount, quoted);
        uint256 got = _quoteBalance(token, t) - qBefore;
        assertEq(got, quoted, "router sell as quoted");
        assertEq(_vaultClaims(q) - c0, _feeOnInput(got + (_vaultClaims(q) - c0), TAX_PIPS), "the tier of the quote out");

        // Exact-out buy: pays exactly the quote (native: the rest swept back).
        uint256 quoteIn = _quoteOut(true, 2_000_000e18);
        qBefore = _quoteBalance(token, t);
        before = IERC20(token).balanceOf(t);
        _urExactOutBuy(t, 2_000_000e18, quoteIn * 2);
        assertEq(IERC20(token).balanceOf(t) - before, 2_000_000e18);
        assertEq(qBefore - _quoteBalance(token, t), quoteIn, "paid the quote, nothing more");

        // Exact-out sell through Permit2: exactly the quote asked for.
        uint256 tokensIn = _quoteOut(false, unit / 50);
        qBefore = _quoteBalance(token, t);
        before = IERC20(token).balanceOf(t);
        c0 = _vaultClaims(q);
        _urExactOutSell(t, unit / 50, tokensIn);
        assertEq(_quoteBalance(token, t) - qBefore, unit / 50, "exact quote out");
        assertEq(before - IERC20(token).balanceOf(t), tokensIn, "paid the quoted tokens");
        assertEq(_vaultClaims(q) - c0, _feeOnTop(unit / 50, TAX_PIPS));

        assertEq(_dexRouter().balance, 0, "no native left in the router");
        assertEq(IERC20(token).balanceOf(_dexRouter()), 0, "no tokens left in the router");
        if (quoteToken != address(0)) assertEq(IERC20(quoteToken).balanceOf(_dexRouter()), 0, "no quote left");
        assertEq(_vaultClaims(q), vault.totalOwed(q));
        assertEq(IERC20(token).balanceOf(address(vault)) + IERC20(token).balanceOf(address(locker)), 0);
    }

    /// @notice The 90% sniper fee through the router, in the swap-then-settle order every aggregator uses. The fee is
    ///         a claim, so it never needs the settlement contract to front funds it doesn't hold yet.
    function test_routing_sniperBuyThroughTheRouter() public {
        Currency q = key.currency0;
        uint256 c0 = _vaultClaims(q);
        uint256 quoted = _quoteIn(true, unit);
        _urExactIn(sniper, true, unit, quoted);
        assertEq(_vaultClaims(q) - c0, unit * 90 / 100, "90% in the quote, to the vault");
        assertEq(IERC20(token).balanceOf(sniper), quoted);
    }

    /// @notice Graduation, sweep and creator claim.
    function test_routing_graduateSweepClaim() public {
        Currency q = key.currency0;
        _skipSniperWindow(token);
        _graduate(token, traders[4]);
        _sell(traders[4], token, IERC20(token).balanceOf(traders[4]) / 4);
        assertEq(_vaultClaims(q), _vaultOwed(_one(token)));
        uint256 m = vault.marketingOwed(token);
        uint256 p = vault.platformOwed(token);
        uint256 c = vault.coinOwed(token);
        uint256 mb = _quoteBalance(token, marketing);
        uint256 tb = _quoteBalance(token, platform);
        uint256 cb = _quoteBalance(token, creator);
        vm.prank(claimer);
        vault.sweep(_one(token));
        vm.prank(creator);
        vault.claimCreator(token);
        assertEq(_quoteBalance(token, marketing) - mb, m);
        assertEq(_quoteBalance(token, platform) - tb, p);
        assertEq(_quoteBalance(token, creator) - cb, c);
        assertEq(_vaultClaims(q), 0);
    }

    /// @notice The StealthRouter on the same pools: the same fill the DEX's quoter gives.
    function test_routing_stealthRouter_matchesQuoter() public {
        _skipSniperWindow(token);
        address t = traders[6];
        uint256 quoted = _quoteIn(true, unit);
        (uint256 paid, uint256 got) = _routerSwap(t, token, true, true, unit, quoted, unit);
        assertEq(paid, unit);
        assertEq(got, quoted, "StealthRouter fill == DEX quoter quote");
        assertEq(_vaultClaims(key.currency0), vault.totalOwed(key.currency0));
    }

    // ---------------------------------------------------------------------
    // Universal Router helpers
    // ---------------------------------------------------------------------

    function _approvePermit2(address erc20) internal {
        IERC20(erc20).approve(_dexPermit2(), type(uint256).max);
        IPermit2(_dexPermit2()).approve(erc20, _dexRouter(), type(uint160).max, uint48(block.timestamp + 1 hours));
    }

    function _urExactIn(address t, bool buy, uint256 amountIn, uint256 minOut) internal {
        (bytes memory commands, bytes[] memory inputs) = UR.exactIn(key, buy, amountIn, minOut);
        bool native = buy && quoteToken == address(0);
        vm.startPrank(t);
        if (!buy) _approvePermit2(token);
        else if (!native) _approvePermit2(quoteToken);
        IUniversalRouter(_dexRouter()).execute{value: native ? amountIn : 0}(commands, inputs, block.timestamp);
        vm.stopPrank();
    }

    function _urExactOutBuy(address t, uint256 amountOut, uint256 maxIn) internal {
        (bytes memory commands, bytes[] memory inputs) = UR.exactOutBuy(key, amountOut, maxIn);
        bool native = quoteToken == address(0);
        vm.startPrank(t);
        if (!native) _approvePermit2(quoteToken);
        IUniversalRouter(_dexRouter()).execute{value: native ? maxIn : 0}(commands, inputs, block.timestamp);
        vm.stopPrank();
    }

    function _urExactOutSell(address t, uint256 amountOut, uint256 maxIn) internal {
        (bytes memory commands, bytes[] memory inputs) = UR.exactOutSell(key, amountOut, maxIn);
        vm.startPrank(t);
        _approvePermit2(token);
        IUniversalRouter(_dexRouter()).execute(commands, inputs, block.timestamp);
        vm.stopPrank();
    }

    function _quoteIn(bool buy, uint256 amount) internal returns (uint256) {
        return UR.quoteIn(_dexQuoter(), key, buy, amount);
    }

    function _quoteOut(bool buy, uint256 amount) internal returns (uint256) {
        return UR.quoteOut(_dexQuoter(), key, buy, amount);
    }
}
