// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Dex, BalanceDelta} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {tierOf} from "../utils/Tiers.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PoolGeometry} from "../../src/libraries/PoolGeometry.sol";
import {StealthConstants as C} from "../../src/libraries/StealthConstants.sol";
import {MockERC20} from "../utils/MockTokens.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {LaunchType} from "../../src/interfaces/IStealth.sol";

/// @notice Cross-checks the contracts and the live pool maths against model/curve_model.py, an independent Python
///         implementation using exact rational arithmetic. Needs ffi, so it only runs with STEALTH_DIFF=true under
///         `FOUNDRY_PROFILE=diff` (v4) or `diff-infinity`.
contract DifferentialTest is BaseTest {
    /// @dev Rounding the pool may keep per swap, in raw units of the quote: a unit or two per swap step, and a swap takes one step
    ///      per 2,560 ticks it crosses.
    uint256 internal constant DUST = 100;

    function setUp() public override {
        if (!vm.envOr("STEALTH_DIFF", false)) {
            vm.skip(true);
            return;
        }
        super.setUp();
    }

    // ---------------------------------------------------------------------
    // Integer mirrors: equal to the wei
    // ---------------------------------------------------------------------

    function testFuzz_diff_virtualReserves(uint256 target) public {
        target = bound(target, 10 ** (C.MIN_QUOTE_DECIMALS - C.QUOTE_TARGET_MIN_EXP), C.MAX_TARGET_CEILING);
        (uint256 vEth, uint256 vToken) = CurveMath.virtualReserves(target);
        (uint256 pEth, uint256 pToken) = abi.decode(_py("vreserves", _a(target)), (uint256, uint256));
        assertEq(vEth, pEth, "virtualEth");
        assertEq(vToken, pToken, "virtualToken");
    }

    function testFuzz_diff_sqrtPrice(uint256 ethReserve, uint256 tokenReserve) public {
        ethReserve = bound(ethReserve, 1e14, 1e24);
        tokenReserve = bound(tokenReserve, 1e24, 2e27);
        uint256 s = CurveMath.sqrtPriceX96(ethReserve, tokenReserve);
        assertEq(s, abi.decode(_py("sqrtp", _a(ethReserve, tokenReserve)), (uint256)));
    }

    /// @dev The second form, for ratios of 2^64 and more (tiny raw quote reserves, e.g. 6-decimal quotes).
    function testFuzz_diff_sqrtPrice_highRatio(uint256 quoteReserve, uint256 tokenReserve) public {
        quoteReserve = bound(quoteReserve, 1, 1e8);
        tokenReserve = bound(tokenReserve, 1e24, 2e27);
        uint256 s = CurveMath.sqrtPriceX96(quoteReserve, tokenReserve);
        assertEq(s, abi.decode(_py("sqrtp", _a(quoteReserve, tokenReserve)), (uint256)));
    }

    /// @notice StealthFeeVault.credit against the model: every launch type, every tier, the sniper range of rates.
    function testFuzz_diff_split(uint256 amount, uint8 typeSeed, uint16 taxSeed, uint256 elapsedSeed) public {
        LaunchType t = LaunchType(typeSeed % 6);
        uint16 tax = tierOf(taxSeed);
        address token = t == LaunchType.Team ? _launchOpts(creator, tax, 0, _team2()) : _launchOpts(creator, tax, 0, _typed(t));
        vm.warp(block.timestamp + bound(elapsedSeed, 0, 20));
        uint24 rate = hook.currentFee(token);
        amount = bound(amount, 1, 1000 ether);
        uint256[] memory args = new uint256[](4);
        args[0] = amount;
        args[1] = rate;
        args[2] = uint8(t);
        args[3] = uint256(tax) * 100;
        uint256[3] memory want = abi.decode(_py("split", args), (uint256[3]));
        vm.prank(address(hook));
        vault.credit(token, NATIVE, amount, rate);
        assertEq(vault.platformOwed(token), want[0], "platform");
        assertEq(vault.marketingOwed(token), want[1], "marketing");
        assertEq(vault.coinOwed(token), want[2], "coin");
        assertEq(want[0] + want[1] + want[2], amount, "every unit booked");
    }

    /// @notice The sniper curve against the model, second by second, every tier.
    function testFuzz_diff_sniper(uint16 taxSeed, uint256 elapsedSeed) public {
        uint16 tax = tierOf(taxSeed);
        address token = _launchWith(creator, tax, 4 ether, 0);
        uint256 elapsed = bound(elapsedSeed, 0, 30);
        vm.warp(block.timestamp + elapsed);
        uint256[] memory args = new uint256[](2);
        args[0] = uint256(tax) * 100;
        args[1] = elapsed;
        assertEq(hook.currentFee(token), abi.decode(_py("sniper", args), (uint256)));
    }

    /// @notice Real swaps in all four modes: the books move exactly as the model's split of the fee says, and the coin's
    ///         part is 70% of its tier on the trade's gross quote leg, to within one unit, at any rate.
    function testFuzz_diff_swapSplit(uint256 amount, uint8 mode, uint8 typeSeed, uint16 taxSeed, uint256 elapsedSeed) public {
        LaunchType t = LaunchType(typeSeed % 6);
        uint16 tax = tierOf(taxSeed);
        address token = t == LaunchType.Team ? _launchOpts(creator, tax, 0, _team2()) : _launchOpts(creator, tax, 0, _typed(t));
        _skipSniperWindow(token);
        _buy(traders[0], token, 2 ether); // inventory, and quote in the pool to sell into
        // Back to the launch's own window, so the swap under test can pay any rate on the sniper curve.
        vm.warp(hook.sniperWindowEnd(token) - 15 + bound(elapsedSeed, 0, 20));
        uint24 rate = hook.currentFee(token);
        uint256 c0 = _vaultClaims();
        uint256[3] memory before = [vault.platformOwed(token), vault.marketingOwed(token), vault.coinOwed(token)];
        uint256 gross = _tradeInMode(token, mode % 4, bound(amount, 1e9, 0.1 ether), c0);
        uint256[] memory args = new uint256[](4);
        args[0] = _vaultClaims() - c0;
        args[1] = rate;
        args[2] = uint8(t);
        args[3] = uint256(tax) * 100;
        uint256[3] memory want = abi.decode(_py("split", args), (uint256[3]));
        assertEq(vault.platformOwed(token) - before[0], want[0], "platform");
        assertEq(vault.marketingOwed(token) - before[1], want[1], "marketing");
        assertEq(vault.coinOwed(token) - before[2], want[2], "coin");
        uint256 exact = abi.decode(_py("coinexact", _a(gross, uint256(tax) * 100)), (uint256));
        assertApproxEqAbs(want[1] + want[2], exact, 1, "the coin gets 70% of its tier");
    }

    /// @dev One swap in `mode`; returns the trade's gross quote leg.
    function _tradeInMode(address token, uint256 mode, uint256 amount, uint256 c0) internal returns (uint256 gross) {
        address who = traders[0];
        if (mode == 0) {
            _swap(who, token, true, -int256(amount), amount);
            return amount;
        }
        if (mode == 1) {
            BalanceDelta d = _buyExactOut(who, token, amount * 1_000, 100 ether);
            return uint128(-d.amount0());
        }
        if (mode == 2) {
            uint256 got = _sell(who, token, IERC20(token).balanceOf(who) / 8);
            return got + (_vaultClaims() - c0);
        }
        _sellExactOut(who, token, amount / 100);
        return amount / 100 + (_vaultClaims() - c0);
    }

    /// @notice A team's lifetime earnings divide exactly as the model does (remainder to wallet 0), and a claim pays it.
    function testFuzz_diff_team(uint256 amount, uint16 s1, uint16 s2) public {
        address[] memory w = new address[](3);
        w[0] = makeAddr("wallet0");
        w[1] = makeAddr("wallet1");
        w[2] = makeAddr("wallet2");
        uint16[] memory bps = new uint16[](3);
        bps[1] = uint16(bound(s1, 1, 9_998));
        bps[2] = uint16(bound(s2, 1, 9_999 - bps[1]));
        bps[0] = 10_000 - bps[1] - bps[2];
        address token = _launchOpts(creator, TAX, 0, _teamOf(w, bps));
        amount = bound(amount, 1, 1000 ether);
        vm.prank(address(hook));
        vault.credit(token, NATIVE, amount, TAX_PIPS);
        uint256[] memory args = new uint256[](4);
        args[0] = vault.teamAccrued(token);
        args[1] = bps[0];
        args[2] = bps[1];
        args[3] = bps[2];
        uint256[3] memory want = abi.decode(_py("team", args), (uint256[3]));
        assertEq(vault.claimable(token, w[0]), want[0]);
        assertEq(vault.claimable(token, w[1]), want[1]);
        assertEq(vault.claimable(token, w[2]), want[2]);
    }

    function _team2() internal returns (StealthFactory.LaunchOptions memory) {
        address[] memory w = new address[](2);
        w[0] = makeAddr("wallet0");
        w[1] = makeAddr("wallet1");
        uint16[] memory bps = new uint16[](2);
        bps[0] = 6_000;
        bps[1] = 4_000;
        return _teamOf(w, bps);
    }

    /// @notice The locked curve holds exactly the ETH and tokens the geometry says, at every target.
    function testFuzz_diff_geometry(uint256 target) public {
        target = bound(target, 10 ** (C.MIN_QUOTE_DECIMALS - C.QUOTE_TARGET_MIN_EXP), C.MAX_TARGET_CEILING);
        PoolGeometry.Geometry memory g = PoolGeometry.compute(target);
        uint256[] memory args = new uint256[](3);
        args[0] = g.graduationSqrtPriceX96;
        args[1] = g.startSqrtPriceX96;
        args[2] = g.curveLiquidity;
        (uint256 eth, uint256 tokens) = abi.decode(_py("grad", args), (uint256, uint256));
        assertEq(g.graduationQuote, eth, "graduation ETH is the exact value, rounded down");
        assertLe(tokens, C.CURVE_SUPPLY, "the curve never needs more than its 800M");
        // All but dust: under 1e-9 tokens, or one unit of liquidity's worth for tiny raw targets.
        assertApproxEqAbs(tokens, C.CURVE_SUPPLY, 1e9 + (uint256(g.startSqrtPriceX96) >> 96) + 1, "and uses all but dust");
    }

    // ---------------------------------------------------------------------
    // Live pool: every swap against the exact value
    // ---------------------------------------------------------------------

    function testFuzz_diff_swaps(uint16 taxSeed, uint256 targetSeed, uint256[10] memory ops) public {
        uint16 tax = tierOf(taxSeed);
        address token = _launchWith(creator, tax, bound(targetSeed, 4 ether, 10 ether), 0);
        if (ops[0] % 2 == 0) _skipSniperWindow(token); // otherwise the first swaps pay the sniper fee
        vm.deal(traders[0], 1_000_000 ether);
        unit = 1 ether;
        for (uint256 i; i < ops.length; ++i) {
            _step(token, ops[i]);
        }
    }

    /// @notice The same against a 6-decimal ERC-20 quote: the model is in raw quote units, so nothing changes.
    function testFuzz_diff_swaps_quote6(uint16 taxSeed, uint256 targetSeed, uint256[10] memory ops) public {
        uint16 tax = tierOf(taxSeed);
        MockERC20 q = _listedQuote("mUSD6", 6, 1, 1_000_000);
        unit = 1e6;
        address token = _launchQuote(creator, address(q), tax, bound(targetSeed, 4 * unit, 1_000 * unit), 0);
        if (ops[0] % 2 == 0) _skipSniperWindow(token);
        q.mint(traders[0], 1e12 * unit);
        for (uint256 i; i < ops.length; ++i) {
            _step(token, ops[i]);
        }
    }

    uint256 internal unit;

    function _step(address token, uint256 op) internal {
        uint256 kind = op % 4;
        uint256 amount = op >> 8;
        address who = traders[0];
        uint256 held = IERC20(token).balanceOf(who);
        uint256 S = _sqrtPrice(token);
        uint256 fee = hook.currentFee(token);

        if (kind == 0) {
            BalanceDelta d = _swap(who, token, true, -int256(bound(amount, 1, 5 * unit)), bound(amount, 1, 5 * unit));
            _checkBuy(token, S, fee, uint128(-d.amount0()), uint128(d.amount1()));
        } else if (kind == 1) {
            uint256 want = bound(amount, 1, IERC20(token).balanceOf(settlementAddr) / 10);
            BalanceDelta d = _buyExactOut(who, token, want, 100_000 * unit);
            assertEq(uint128(d.amount1()), want, "exact output filled");
            _checkBuy(token, S, fee, uint128(-d.amount0()), want);
        } else if (kind == 2) {
            if (held == 0) return;
            uint256 tokensIn = bound(amount, 1, held);
            BalanceDelta d = _swap(who, token, false, -int256(tokensIn), 0);
            _checkSell(token, S, fee, tokensIn, uint128(d.amount0()));
        } else {
            (, uint256 raised,,) = locker.progress(token);
            if (held == 0 || raised < 20 || raised < unit / 1e9) return;
            uint256 ethOut = bound(amount, 1, raised / 20);
            // Only if the holder can cover it: the model's value of their whole bag must exceed the ask.
            (uint256 bagValue, bool ok) = _sellValue(token, S, fee, held);
            if (!ok || bagValue < ethOut * 2) return;
            BalanceDelta d = _sellExactOut(who, token, ethOut);
            assertEq(uint128(d.amount0()), ethOut, "exact output filled");
            _checkSell(token, S, fee, uint128(-d.amount1()), ethOut);
        }
    }

    /// @dev The buyer paid at least the exact price of what they got, and at most dust more.
    function _checkBuy(address token, uint256 S, uint256 fee, uint256 paid, uint256 got) internal {
        StealthLocker.PoolInfo memory info = locker.getPool(token);
        uint256[] memory args = new uint256[](8);
        args[0] = S;
        args[1] = info.graduationSqrtPriceX96;
        args[2] = info.startSqrtPriceX96;
        args[3] = Dex.sqrtAtTick(info.tailTickLower);
        args[4] = info.curveLiquidity;
        args[5] = info.tailLiquidity;
        args[6] = fee;
        args[7] = got;
        uint256 cost = abi.decode(_py("buycost", args), (uint256));
        assertGe(paid, cost, "the pool undercharged a buy");
        // Rounding happens on the net amount; grossing it up by the fee scales it (x10 at the 90% sniper fee).
        assertLe(paid - cost, DUST * 1_000_000 / (1_000_000 - fee), "the pool overcharged a buy by more than dust");
    }

    /// @dev The seller got at most the exact value of what they sold (fee taken out of the ETH), and at most dust less.
    function _checkSell(address token, uint256 S, uint256 fee, uint256 sold, uint256 got) internal {
        (uint256 value, bool ok) = _sellValue(token, S, fee, sold);
        assertTrue(ok, "a sell the hook allowed would pass the launch price");
        assertLe(got, value, "the pool overpaid a sell");
        assertLe(value - got, DUST, "the pool underpaid a sell by more than dust");
    }

    function _sellValue(address token, uint256 S, uint256 fee, uint256 tokensIn)
        internal
        returns (uint256 value, bool ok)
    {
        StealthLocker.PoolInfo memory info = locker.getPool(token);
        uint256[] memory args = new uint256[](8);
        args[0] = S;
        args[1] = info.graduationSqrtPriceX96;
        args[2] = info.startSqrtPriceX96;
        args[3] = Dex.sqrtAtTick(info.tailTickLower);
        args[4] = info.curveLiquidity;
        args[5] = info.tailLiquidity;
        args[6] = fee;
        args[7] = tokensIn;
        uint256 okWord;
        (value, okWord) = abi.decode(_py("sellvalue", args), (uint256, uint256));
        ok = okWord == 1;
    }

    // ---------------------------------------------------------------------
    // ffi
    // ---------------------------------------------------------------------

    function _py(string memory cmd, uint256[] memory args) internal returns (bytes memory) {
        string[] memory inputs = new string[](3 + args.length);
        inputs[0] = "python3";
        inputs[1] = "model/curve_model.py";
        inputs[2] = cmd;
        for (uint256 i; i < args.length; ++i) {
            inputs[3 + i] = vm.toString(args[i]);
        }
        return vm.ffi(inputs);
    }

    function _a(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _a(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }
}
