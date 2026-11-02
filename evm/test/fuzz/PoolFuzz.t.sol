// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath, BalanceDelta} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {tierOf} from "../utils/Tiers.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";

/// @notice Random trading in every shape. Every swap pays exactly the fee its mode defines, on the quote leg, and after
///         every swap the pool is still exactly the locked curve: same positions, nothing past the launch price,
///         graduation flagged exactly when crossed, every fee in the vault in the quote.
contract PoolFuzzTest is BaseTest {
    address internal token;
    uint24 internal fee;
    StealthLocker.PoolInfo internal info;
    uint160 internal minPrice;

    function _setUpToken(uint16 taxSeed, uint256 targetSeed) internal {
        uint16 tax = tierOf(taxSeed);
        token = _launch(tax, bound(targetSeed, 4 ether, 10 ether));
        fee = uint24(tax) * 100;
        info = locker.getPool(token);
        minPrice = info.startSqrtPriceX96;
        for (uint256 i; i < 3; ++i) {
            vm.deal(traders[i], 1_000_000 ether);
        }
    }

    function testFuzz_randomSwaps(uint16 taxSeed, uint256 targetSeed, uint256[12] memory ops) public {
        _setUpToken(taxSeed, targetSeed);
        for (uint256 i; i < ops.length; ++i) {
            uint256 kind = ops[i] % 4;
            uint256 amount = ops[i] >> 8;
            address who = traders[ops[i] % 3];
            uint256 c0 = _vaultClaims();
            if (kind == 0) {
                uint256 ethIn = bound(amount, 1, 6 ether);
                _buy(who, token, ethIn);
                assertEq(_vaultClaims() - c0, _feeOnInput(ethIn, fee), "exact-in buy: fee out of the quote in");
            } else if (kind == 1) {
                uint256 poolTokens = IERC20(token).balanceOf(settlementAddr);
                BalanceDelta d = _buyExactOut(who, token, bound(amount, 1, poolTokens / 5), 1_000 ether);
                uint256 paid = uint256(uint128(-d.amount0()));
                uint256 f = _vaultClaims() - c0;
                assertEq(f, _feeOnTop(paid - f, fee), "exact-out buy: fee on top of the quote in");
            } else if (kind == 2) {
                uint256 held = IERC20(token).balanceOf(who);
                if (held == 0) continue;
                uint256 got = _sell(who, token, bound(amount, 1, held));
                uint256 f = _vaultClaims() - c0;
                assertEq(f, _feeOnInput(got + f, fee), "exact-in sell: fee out of the quote out");
            } else {
                uint256 held = IERC20(token).balanceOf(who);
                (, uint256 raised,,) = locker.progress(token);
                if (held == 0 || raised < 1e12) continue;
                // A small exact-output sell: at most 1% of the quote in the pool, which the holder can always cover.
                uint256 ethOut = bound(amount, 1, raised / 100);
                (uint256 ethIfAllSold,) = _ethForAll(who);
                if (ethIfAllSold <= ethOut * 2) continue;
                BalanceDelta d = _sellExactOut(who, token, ethOut);
                assertEq(uint256(uint128(d.amount0())), ethOut, "exact quote out");
                assertEq(_vaultClaims() - c0, _feeOnTop(ethOut, fee), "exact-out sell: fee on top of the quote out");
            }
            _check();
        }
        _settleEverything();
    }

    function _ethForAll(address who) internal view returns (uint256 eth, uint256 held) {
        held = IERC20(token).balanceOf(who);
        (, uint256 raised, uint256 sold,) = locker.progress(token);
        eth = sold == 0 ? 0 : FullMath.mulDiv(raised, held, sold) / 2;
    }

    function _check() internal {
        uint160 price = _sqrtPrice(token);
        if (price < minPrice) minPrice = price;
        assertLe(price, info.startSqrtPriceX96, "never past the launch price");
        assertEq(hook.graduated(token), minPrice <= info.graduationSqrtPriceX96, "graduated iff the line was crossed");
        assertEq(_positionLiquidityOf(token, CURVE_SALT), info.curveLiquidity, "curve position untouched");
        assertEq(_positionLiquidityOf(token, TAIL_SALT), info.tailLiquidity, "tail position untouched");
        // The pool picks the active range by tick, not price: a zero-size buy at the launch price crosses into the curve
        // (tick = upper - 1) without moving the price, so the tick decides.
        uint128 active = _poolLiquidity(_poolId(token));
        (, int24 tick,,) = _getSlot0(_poolId(token));
        if (tick >= info.curveTickUpper) assertEq(active, 0, "nothing active at the launch tick");
        else if (tick >= info.curveTickLower) assertEq(active, info.curveLiquidity, "only the curve is active");
        else assertEq(active, info.tailLiquidity, "only the tail is active");
        assertEq(_lpFee(token), 0, "no LP fee");
        assertEq(hook.currentFee(token), fee, "the tier after the window");
        assertEq(address(locker).balance, 0);
        assertEq(address(hook).balance, 0);
        assertEq(address(vault).balance, 0);
        assertEq(_dexClaimOf(address(hook), NATIVE), 0, "hook holds no claims");
        assertEq(IERC20(token).balanceOf(address(locker)), 0, "no token fees anywhere");
        assertEq(IERC20(token).balanceOf(address(hook)), 0);
        assertEq(IERC20(token).balanceOf(address(vault)), 0);
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "vault claims == owed");
        (uint256 g0, uint256 g1) = _feeGrowthGlobals(_poolId(token));
        assertEq(g0 + g1, 0, "the positions never earn fees");
    }

    /// @dev Everyone sells back, then the vault pays out: the books close exactly.
    function _settleEverything() internal {
        for (uint256 i; i < 3; ++i) {
            uint256 held = IERC20(token).balanceOf(traders[i]);
            if (held > 0) _sell(traders[i], token, held);
            _check();
        }
        assertEq(_vaultClaims(), _vaultOwed(_one(token)), "vault books exact");
        vault.sweep(_one(token));
        if (vault.coinOwed(token) > 0) {
            vm.prank(creator);
            vault.claimCreator(token);
        }
        assertEq(_vaultClaims(), 0, "fully paid out");
        assertEq(vault.totalOwed(NATIVE), 0);
        assertLe(_sqrtPrice(token), info.startSqrtPriceX96);
    }

    function testFuzz_feeIsTheTax(uint16 taxSeed, uint256 ethIn, uint256 sellFraction) public {
        _setUpToken(taxSeed, 4 ether);
        ethIn = bound(ethIn, 1e9, 3 ether);
        uint256 c0 = _vaultClaims();
        uint256 got = _buy(traders[0], token, ethIn);
        assertEq(_vaultClaims() - c0, FullMath.mulDivRoundingUp(ethIn, fee, 1_000_000), "buy: tax on the quote in");

        uint256 tokensIn = bound(sellFraction, 1e6, got);
        uint256 c1 = _vaultClaims();
        uint256 ethOut = _sell(traders[0], token, tokensIn);
        uint256 f = _vaultClaims() - c1;
        assertEq(f, FullMath.mulDivRoundingUp(ethOut + f, fee, 1_000_000), "sell: tax on the quote out, never tokens");
        assertEq(IERC20(token).balanceOf(address(vault)) + IERC20(token).balanceOf(address(locker)), 0);
    }

    function testFuzz_roundTripNeverProfits(uint16 taxSeed, uint256 ethIn) public {
        _setUpToken(taxSeed, 4 ether);
        ethIn = bound(ethIn, 1e6, 100 ether);
        address t = traders[2];
        uint256 before = t.balance;
        uint256 got = _buy(t, token, ethIn);
        if (got > 0) _sell(t, token, got);
        assertLt(t.balance, before, "buy then sell always costs the fee");
    }

    function testFuzz_splitBuysNeverBeatOneBuy(uint16 taxSeed, uint256 total, uint8 parts) public {
        uint16 tax = tierOf(taxSeed);
        address a = _launch(tax, 4 ether);
        address b = _launch(tax, 4 ether);
        parts = uint8(bound(parts, 2, 20));
        total = bound(total, uint256(parts) * 1e9, 3 ether);
        uint256 big = _buy(traders[0], a, total);
        uint256 piece = total / parts;
        uint256 small;
        for (uint256 i; i < parts; ++i) {
            small += _buy(traders[1], b, i == parts - 1 ? total - piece * (parts - 1) : piece);
        }
        assertLe(small, big, "splitting a buy never gets more tokens");
    }
}
