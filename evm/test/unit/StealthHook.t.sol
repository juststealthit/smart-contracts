// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Dex, IDexHooks, IDexManager, PoolKey, Currency, BalanceDelta} from "@dex/Dex.sol";
import {TestRouter} from "../utils/TestRouter.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {StealthHook} from "../../src/StealthHook.sol";

contract StealthHookTest is BaseTest {
    event Graduated(address indexed token, uint160 sqrtPriceX96);
    event SwapFee(address indexed token, address indexed sender, bool isBuy, bool exactInput, uint256 fee, uint24 rate);

    uint24 internal constant SNIPER = 900_000;

    function _wrapped(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return _wrappedHookError(address(hook), callback, reason);
    }

    function _assertNothingStuck(address token) internal view {
        assertEq(address(hook).balance, 0, "hook native");
        assertEq(address(locker).balance, 0, "locker native");
        assertEq(address(vault).balance, 0, "vault native");
        assertEq(_dexClaimOf(address(hook), NATIVE), 0, "hook claims");
        assertEq(_dexClaimOf(address(locker), NATIVE), 0, "locker claims");
        assertEq(IERC20(token).balanceOf(address(hook)), 0, "hook tokens");
        assertEq(IERC20(token).balanceOf(address(locker)), 0, "locker tokens");
        assertEq(IERC20(token).balanceOf(address(vault)), 0, "vault tokens");
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "vault claims == owed");
    }

    // ---------------------------------------------------------------------
    // Setup and access
    // ---------------------------------------------------------------------

    function test_poolHasNoLpFee() public {
        address token = _launch(TAX, 4 ether);
        assertEq(_key(token).fee, 0, "static LP fee 0");
        assertEq(_lpFee(token), 0);
    }

    function test_register_onlyLockerOnce() public {
        vm.prank(attacker);
        vm.expectRevert(StealthHook.NotLocker.selector);
        hook.register(address(1), _reg(12_500, 1, 1));
        vm.startPrank(address(locker));
        uint24[5] memory notTiers = [uint24(12_499), 12_501, 50_000, 57_499, 57_501]; // around and between the tiers
        for (uint256 i; i < notTiers.length; ++i) {
            vm.expectRevert(StealthHook.InvalidFee.selector);
            hook.register(address(1), _reg(notTiers[i], 1, 1));
        }
        StealthHook.Registration memory longLimits = _reg(12_500, 1, 1);
        longLimits.limitsWindow = 60 minutes + 1;
        vm.expectRevert(StealthHook.InvalidFee.selector);
        hook.register(address(1), longLimits); // limits above 60 minutes
        vm.expectRevert(StealthHook.InvalidFee.selector);
        hook.register(address(1), _reg(12_500, 0, 1)); // no start price
        hook.register(address(1), _reg(12_500, 1, 1));
        vm.expectRevert(StealthHook.AlreadyRegistered.selector);
        hook.register(address(1), _reg(12_500, 1, 1));
        vm.stopPrank();
    }

    /// @notice All five tiers register, and no other rate does.
    function test_register_everyTier() public {
        uint24[5] memory tiers = [uint24(12_500), 22_500, 32_500, 42_500, 57_500];
        vm.startPrank(address(locker));
        for (uint256 i; i < tiers.length; ++i) {
            hook.register(address(uint160(i + 1)), _reg(tiers[i], 1, 1));
        }
        vm.stopPrank();
    }

    function test_callbacksOnlyFromPoolManager() public {
        address token = _launch(TAX, 4 ether);
        PoolKey memory key = _key(token);
        IDexManager.SwapParams memory params = IDexManager.SwapParams(true, -1 ether, MIN_PRICE_LIMIT);
        vm.startPrank(attacker);
        vm.expectRevert(StealthHook.NotPoolManager.selector);
        hook.beforeSwap(attacker, key, params, "");
        vm.expectRevert(StealthHook.NotPoolManager.selector);
        hook.afterSwap(attacker, key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(StealthHook.NotPoolManager.selector);
        hook.beforeInitialize(address(locker), key, 1 << 96);
        vm.expectRevert(StealthHook.NotPoolManager.selector);
        hook.afterInitialize(address(locker), key, 1 << 96, 0);
        vm.expectRevert(StealthHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(locker), key, IDexManager.ModifyLiquidityParams(0, 10, 1, 0), "");
        vm.stopPrank();
    }

    function test_unusedCallbacksRevert() public {
        PoolKey memory key;
        IDexManager.ModifyLiquidityParams memory mp;
        vm.expectRevert(StealthHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(0), key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(StealthHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(0), key, mp, "");
        vm.expectRevert(StealthHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(0), key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(StealthHook.HookNotImplemented.selector);
        hook.afterDonate(address(0), key, 0, 0, "");
    }

    // ---------------------------------------------------------------------
    // Pool creation and liquidity gating
    // ---------------------------------------------------------------------

    function test_nobodyElseCanCreateAStealthPool() public {
        address token = _launchWith(creator, TAX, 4 ether, 0);
        uint24[3] memory fees = [uint24(0), 3000, 0x800000];
        int24[3] memory spacings = [int24(10), 60, 200];
        bytes memory refusal =
            _wrapped(IDexHooks.beforeInitialize.selector, abi.encodeWithSelector(StealthHook.NotLocker.selector));
        vm.startPrank(attacker);
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 3; ++j) {
                PoolKey memory k = _key(token);
                k.fee = fees[i];
                k = _withTickSpacing(k, spacings[j]);
                vm.expectRevert(refusal);
                manager.initialize(k, 1 << 96);
            }
        }
        vm.stopPrank();
    }

    function test_revert_malformedPoolEvenFromLocker() public {
        address token = _launchWith(creator, TAX, 4 ether, 0);
        uint160 start = locker.getPool(token).startSqrtPriceX96;
        PoolKey[5] memory bad = [_key(token), _key(token), _key(token), _key(token), _key(token)];
        bad[0].currency0 = Currency.wrap(address(0xdead)); // not the registered quote (native)
        bad[1].fee = 3000; // not the zero LP fee
        bad[2] = _withTickSpacing(bad[2], 60); // not the Stealth spacing
        bad[3].currency1 = Currency.wrap(address(0xbeef)); // not registered
        (PoolKey memory foreign, bool hasManager) = _withManager(bad[4], address(0xdead)); // not the pool manager
        bad[4] = foreign;
        vm.startPrank(address(manager));
        for (uint256 i; i < (hasManager ? 5 : 4); ++i) {
            vm.expectRevert(StealthHook.InvalidPool.selector);
            hook.beforeInitialize(address(locker), bad[i], start);
        }
        vm.stopPrank();
        PoolKey memory key = _key(token);
        vm.prank(address(manager));
        vm.expectRevert(StealthHook.InvalidPool.selector);
        hook.beforeInitialize(address(locker), key, start);
    }

    /// @notice The checks of `test_revert_malformedPoolEvenFromLocker`, each on its own: the token is registered and its
    ///         pool not yet created, so nothing but the bad field refuses the key.
    function test_revert_malformedPoolBeforeItExists() public {
        address token = address(uint160(0xbeef) << 140);
        uint160 start = 1 << 96;
        vm.prank(address(locker));
        hook.register(token, _reg(TAX_PIPS, start, start / 2));
        PoolKey memory good = Dex.key(NATIVE, token, address(hook), address(manager), 0, 10);
        vm.startPrank(address(manager));
        assertEq(hook.beforeInitialize(address(locker), good, start), IDexHooks.beforeInitialize.selector, "the good key");
        PoolKey memory k = Dex.key(Currency.wrap(address(0xdead)), token, address(hook), address(manager), 0, 10);
        vm.expectRevert(StealthHook.InvalidPool.selector);
        hook.beforeInitialize(address(locker), k, start);
        k = Dex.key(NATIVE, token, address(hook), address(manager), 3000, 10);
        vm.expectRevert(StealthHook.InvalidPool.selector);
        hook.beforeInitialize(address(locker), k, start);
        k = Dex.key(NATIVE, token, address(hook), address(manager), 0, 60);
        vm.expectRevert(StealthHook.InvalidPool.selector);
        hook.beforeInitialize(address(locker), k, start);
        vm.expectRevert(StealthHook.InvalidPool.selector);
        hook.beforeInitialize(address(locker), good, start + 1); // not the launch price
        vm.stopPrank();
    }

    function test_onlyTheLockerAddsLiquidity() public {
        address token = _launch(TAX, 4 ether);
        uint256 held = _buy(traders[0], token, 2 ether);
        TestRouter lp = new TestRouter(manager);
        PoolKey memory key = _key(token);
        int24 tick = Dex.tickAtSqrt(_sqrtPrice(token)) / 10 * 10;
        bytes memory refusal =
            _wrapped(IDexHooks.beforeAddLiquidity.selector, abi.encodeWithSelector(StealthHook.NotLocker.selector));
        vm.startPrank(traders[0]);
        IERC20(token).approve(address(lp), type(uint256).max);
        vm.expectRevert(refusal);
        lp.modifyLiquidity(key, IDexManager.ModifyLiquidityParams(tick - 600, tick, 1e18, 0), "");
        vm.expectRevert(refusal);
        lp.modifyLiquidity{value: 1 ether}(key, IDexManager.ModifyLiquidityParams(tick + 10, tick + 610, 1e15, 0), "");
        vm.expectRevert(refusal);
        lp.modifyLiquidity{value: 1 ether}(
            key, IDexManager.ModifyLiquidityParams(Dex.minUsableTick(10), -Dex.minUsableTick(10), 1e15, 0), ""
        );
        vm.stopPrank();
        assertGt(held, 0);
        assertEq(
            _positionLiquidityOf(token, CURVE_SALT), locker.getPool(token).curveLiquidity, "only the locked positions"
        );
    }

    /// @notice Nobody can donate into a Stealth pool: a donation would become fees stuck in the locked positions.
    function test_revert_donate() public {
        address token = _launch(TAX, 4 ether);
        _buy(traders[0], token, 1 ether);
        TestRouter donor = new TestRouter(manager);
        PoolKey memory key = _key(token);
        vm.prank(traders[1]);
        vm.expectRevert(
            _wrapped(IDexHooks.beforeDonate.selector, abi.encodeWithSelector(StealthHook.DonationsDisabled.selector))
        );
        donor.donate{value: 1 ether}(key, 1 ether, 0, "");
        vm.prank(address(0xbad));
        vm.expectRevert(StealthHook.NotPoolManager.selector);
        hook.beforeDonate(address(0), key, 0, 0, "");
    }

    // ---------------------------------------------------------------------
    // The fee on the quote leg: all four swap modes
    // ---------------------------------------------------------------------

    function test_exactInBuy_feeOutOfTheQuoteIn() public {
        address token = _launch(TAX, 4 ether);
        uint256 g = 1 ether;
        uint256 fee = _feeOnInput(g, TAX_PIPS);
        uint256 c0 = _vaultClaims();
        vm.expectEmit(true, true, false, true, address(hook));
        emit SwapFee(token, address(swapRouter), true, true, fee, TAX_PIPS);
        BalanceDelta d = _swap(traders[0], token, true, -int256(g), g);
        assertEq(-d.amount0(), int128(int256(g)), "the trader pays exactly the quote in");
        assertEq(_vaultClaims() - c0, fee, "fee = ceil(the tier of the quote in)");
        assertGt(d.amount1(), 0);
        _assertNothingStuck(token);
    }

    function test_exactOutSell_feeOnTopOfTheQuoteOut() public {
        address token = _launch(TAX, 4 ether);
        _buy(traders[0], token, 2 ether);
        uint256 x = 0.5 ether;
        uint256 fee = _feeOnTop(x, TAX_PIPS);
        vm.prank(traders[0]);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        uint256 c0 = _vaultClaims();
        vm.expectEmit(true, true, false, true, address(hook));
        emit SwapFee(token, address(swapRouter), false, false, fee, TAX_PIPS);
        BalanceDelta d = _sellExactOut(traders[0], token, x);
        assertEq(d.amount0(), int128(int256(x)), "the trader receives exactly the quote asked for");
        assertEq(_vaultClaims() - c0, fee);
        assertGe(fee * 1_000_000, (x + fee) * TAX_PIPS, "at least the tier of the gross quote out");
        _assertNothingStuck(token);
    }

    function test_exactOutBuy_feeOnTopOfTheQuoteIn() public {
        address token = _launch(TAX, 4 ether);
        uint256 tokensOut = 10_000_000e18;
        uint256 c0 = _vaultClaims();
        BalanceDelta d = _buyExactOut(traders[0], token, tokensOut, 5 ether);
        assertEq(d.amount1(), int128(int256(tokensOut)), "exact tokens out");
        uint256 paid = uint256(uint128(-d.amount0()));
        uint256 fee = _vaultClaims() - c0;
        uint256 poolIn = paid - fee;
        assertEq(fee, _feeOnTop(poolIn, TAX_PIPS), "fee = ceil(poolIn * tier / (1 - tier))");
        _assertNothingStuck(token);
    }

    function test_exactInSell_feeOutOfTheQuoteOut() public {
        address token = _launch(TAX, 4 ether);
        uint256 held = _buy(traders[0], token, 2 ether);
        uint256 c0 = _vaultClaims();
        BalanceDelta d = _swap(traders[0], token, false, -int256(held / 2), 0);
        uint256 received = uint256(uint128(d.amount0()));
        uint256 fee = _vaultClaims() - c0;
        assertEq(fee, _feeOnInput(received + fee, TAX_PIPS), "fee = ceil(the tier of the pool's quote out)");
        assertEq(-d.amount1(), int128(int256(held / 2)));
        _assertNothingStuck(token);
    }

    /// @notice An exact-in buy and the exact-out buy of the same tokens cost the same, to a few wei.
    function test_buyModesAgree() public {
        address token = _launch(TAX, 4 ether);
        uint256 snap = vm.snapshotState();
        BalanceDelta a = _swap(traders[0], token, true, -int256(1 ether), 1 ether);
        vm.revertToState(snap);
        BalanceDelta b = _buyExactOut(traders[0], token, uint256(uint128(a.amount1())), 2 ether);
        assertApproxEqAbs(uint256(uint128(-b.amount0())), 1 ether, 3, "same cost either way");
    }

    /// @notice An exact-in sell and the exact-out sell of the same quote agree too.
    function test_sellModesAgree() public {
        address token = _launch(TAX, 4 ether);
        uint256 held = _buy(traders[0], token, 2 ether);
        uint256 snap = vm.snapshotState();
        BalanceDelta a = _swap(traders[0], token, false, -int256(held / 3), 0);
        vm.revertToState(snap);
        BalanceDelta b = _sellExactOut(traders[0], token, uint256(uint128(a.amount0())));
        assertApproxEqAbs(uint256(uint128(-b.amount1())), held / 3, 1e9, "same tokens either way");
    }

    // ---------------------------------------------------------------------
    // Sniper fee and first buy
    // ---------------------------------------------------------------------

    function test_sniperFeeOnBuysAndSellsThenTheTier() public {
        address token = _launchWith(creator, TAX, 4 ether, 0);
        uint256 end = hook.sniperWindowEnd(token);
        assertEq(end, block.timestamp + 15);
        assertEq(hook.currentFee(token), SNIPER);

        uint256 c0 = _vaultClaims();
        BalanceDelta d = _swap(sniper, token, true, -int256(1 ether), 1 ether);
        assertEq(_vaultClaims() - c0, 0.9 ether, "90% of a sniper buy");

        uint256 c1 = _vaultClaims();
        BalanceDelta s = _swap(sniper, token, false, -int256(uint256(uint128(d.amount1()))), 0);
        uint256 got = uint256(uint128(s.amount0()));
        assertEq(_vaultClaims() - c1, _feeOnInput(got + (_vaultClaims() - c1), SNIPER), "90% of a sniper sell");

        vm.warp(end - 1);
        uint24 last = uint24(SNIPER - (uint256(SNIPER - TAX_PIPS) * 14) / 15);
        assertEq(hook.currentFee(token), last, "the last second is the last step down");
        assertGt(last, TAX_PIPS, "still above the tier");
        uint256 c2 = _vaultClaims();
        _swap(traders[0], token, true, -int256(0.1 ether), 0.1 ether);
        assertEq(_vaultClaims() - c2, _feeOnInput(0.1 ether, last));

        vm.warp(end);
        assertEq(hook.currentFee(token), TAX_PIPS, "window closed: no lazy refresh or poke needed");
        uint256 c3 = _vaultClaims();
        _swap(traders[0], token, true, -int256(1 ether), 1 ether);
        assertEq(_vaultClaims() - c3, 0.0425 ether, "then the tier");
    }

    function test_creatorFirstBuyPaysTheTaxNotTheSniperFee() public {
        address token = _launchWith(creator, TAX, 4 ether, 1 ether);
        (uint256 tokensOut, uint256 ethUsed) = locker.quoteLaunchBuy(4 ether, TAX, 1 ether);
        assertEq(IERC20(token).balanceOf(creator), tokensOut);
        uint256 fee = _vaultClaims();
        // ethUsed = fee + what the pool took; the fee is the tier of the gross, not 90%.
        assertLt(fee * 100, ethUsed * 6, "about the tier");
        assertGt(fee * 100, ethUsed * 4);
        assertEq(hook.currentFee(token), SNIPER, "everyone else still pays the sniper fee");
    }

    // ---------------------------------------------------------------------
    // Partial fills
    // ---------------------------------------------------------------------

    function test_revert_exactInBuyStoppedByAPriceLimit() public {
        address token = _launch(TAX, 4 ether);
        uint160 limit = _sqrtPrice(token) * 999 / 1000; // allows only a sliver of the buy
        PoolKey memory key = _key(token);
        vm.prank(traders[0]);
        vm.expectRevert(_wrapped(IDexHooks.afterSwap.selector, abi.encodeWithSelector(StealthHook.PartialFill.selector)));
        swapRouter.swap{value: 1 ether}(
            key,
            IDexManager.SwapParams(true, -1 ether, limit),
            TestRouter.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_revert_exactOutSellStoppedByAPriceLimit() public {
        address token = _launch(TAX, 4 ether);
        _buy(traders[0], token, 2 ether);
        uint160 limit = _sqrtPrice(token) * 1001 / 1000;
        PoolKey memory key = _key(token);
        vm.startPrank(traders[0]);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        vm.expectRevert(_wrapped(IDexHooks.afterSwap.selector, abi.encodeWithSelector(StealthHook.PartialFill.selector)));
        swapRouter.swap(
            key,
            IDexManager.SwapParams(false, 1 ether, limit),
            TestRouter.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// @notice In the two afterSwap modes the fee follows what actually traded, so a price limit is fine.
    function test_partialFillAllowedWhereTheFeeFollowsTheFill() public {
        address token = _launch(TAX, 4 ether);
        uint160 limit = _sqrtPrice(token) * 999 / 1000;
        PoolKey memory key = _key(token);
        uint256 c0 = _vaultClaims();
        vm.prank(traders[0]);
        BalanceDelta d = swapRouter.swap{value: 5 ether}(
            key,
            IDexManager.SwapParams(true, int256(100_000_000e18), limit),
            TestRouter.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertLt(uint256(uint128(d.amount1())), 100_000_000e18, "stopped early");
        uint256 fee = _vaultClaims() - c0;
        assertEq(fee, _feeOnTop(uint256(uint128(-d.amount0())) - fee, TAX_PIPS));
    }

    // ---------------------------------------------------------------------
    // Graduation and the start-price guard
    // ---------------------------------------------------------------------

    function test_graduationFlagAtTheCrossing() public {
        address token = _launch(TAX, 4 ether);
        uint160 grad = locker.getPool(token).graduationSqrtPriceX96;
        _buy(traders[0], token, 3 ether);
        assertFalse(hook.graduated(token));
        assertGt(_sqrtPrice(token), grad);
        vm.expectEmit(true, false, false, false, address(hook));
        emit Graduated(token, 0);
        _graduate(token, traders[1]);
        assertLe(_sqrtPrice(token), grad);
        _sell(traders[1], token, IERC20(token).balanceOf(traders[1]));
        assertGt(_sqrtPrice(token), grad);
        assertTrue(hook.graduated(token), "selling back below the line doesn't un-graduate");
    }

    function test_revert_swapPastTheStartPrice() public {
        address token = _launch(TAX, 4 ether);
        deal(token, attacker, 1_000e18);
        PoolKey memory key = _key(token);
        vm.startPrank(attacker);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        vm.expectRevert(_wrapped(IDexHooks.afterSwap.selector, abi.encodeWithSelector(StealthHook.PriceAboveStart.selector)));
        swapRouter.swap(
            key,
            IDexManager.SwapParams(false, -int256(1_000e18), MAX_PRICE_LIMIT),
            TestRouter.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function test_sellingEverythingBackEndsAtTheStartPriceAtMost() public {
        address token = _launch(TAX, 4 ether);
        for (uint256 i; i < 5; ++i) {
            _buy(traders[i], token, 0.3 ether);
        }
        for (uint256 i; i < 5; ++i) {
            _sell(traders[i], token, IERC20(token).balanceOf(traders[i]));
        }
        assertLe(_sqrtPrice(token), locker.getPool(token).startSqrtPriceX96);
        (, uint256 raised,,) = locker.progress(token);
        assertLe(raised, 10, "the pool gave back all the quote it took, to rounding");
        _assertNothingStuck(token);
    }
}
