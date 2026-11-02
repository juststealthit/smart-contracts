// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Dex, DexBase, DexCallback, IDexManager, PoolKey, Currency, BalanceDelta} from "@dex/Dex.sol";
import {DexTestLib} from "@dex/DexTest.sol";
import {TestRouter} from "../utils/TestRouter.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";

contract XToken is ERC20 {
    constructor() ERC20("X", "X") {
        _mint(msg.sender, 1e30);
    }
}

/// @notice Minimal multi-hop router: chains hops through the caller's own deltas exactly like the DEXes' own router base
///         contracts (exact-in forwards each hop's output, exact-out walks back from the last hop).
contract MiniRouter is DexCallback {
    struct Route {
        uint8 mode; // 0 exact-in ETH->F->X, 1 exact-in X->F->ETH, 2 exact-out ETH->F->X, 3 exact-out X->F->ETH
        PoolKey flare;
        PoolKey xPool;
        uint256 amount;
        address user;
    }

    constructor(IDexManager m) DexBase(m) {}

    function run(Route calldata r) external payable returns (uint256 ethLeg, uint256 xLeg) {
        (ethLeg, xLeg) = abi.decode(_lockRaw(abi.encode(r)), (uint256, uint256));
        if (address(this).balance != 0) payable(r.user).transfer(address(this).balance);
    }

    function _swap(PoolKey memory k, bool zfo, int256 amt) internal returns (BalanceDelta) {
        return poolManager.swap(
            k, IDexManager.SwapParams(zfo, amt, zfo ? Dex.MIN_SQRT_PRICE + 1 : Dex.MAX_SQRT_PRICE - 1), ""
        );
    }

    function _abs(int128 v) internal pure returns (uint256) {
        return uint256(uint128(v < 0 ? -v : v));
    }

    function _onLock(bytes calldata data) internal override returns (bytes memory) {
        Route memory r = abi.decode(data, (Route));
        address f = Currency.unwrap(r.flare.currency1);
        bool fIs0 = Currency.unwrap(r.xPool.currency0) == f;
        Currency x = fIs0 ? r.xPool.currency1 : r.xPool.currency0;
        uint256 ethLeg;
        uint256 xLeg;
        if (r.mode == 0) {
            BalanceDelta d1 = _swap(r.flare, true, -int256(r.amount));
            uint256 fOut = _abs(d1.amount1());
            BalanceDelta d2 = _swap(r.xPool, fIs0, -int256(fOut));
            ethLeg = _abs(d1.amount0());
            xLeg = _abs(fIs0 ? d2.amount1() : d2.amount0());
            _settleNative(ethLeg);
            _take(x, r.user, xLeg);
        } else if (r.mode == 1) {
            BalanceDelta d1 = _swap(r.xPool, !fIs0, -int256(r.amount));
            uint256 fOut = _abs(fIs0 ? d1.amount0() : d1.amount1());
            BalanceDelta d2 = _swap(r.flare, false, -int256(fOut));
            ethLeg = _abs(d2.amount0());
            xLeg = r.amount;
            _payX(x, r.user, xLeg);
            _take(Currency.wrap(address(0)), r.user, ethLeg);
        } else if (r.mode == 2) {
            BalanceDelta d2 = _swap(r.xPool, fIs0, int256(r.amount));
            uint256 fIn = _abs(fIs0 ? d2.amount0() : d2.amount1());
            BalanceDelta d1 = _swap(r.flare, true, int256(fIn));
            ethLeg = _abs(d1.amount0());
            xLeg = r.amount;
            _settleNative(ethLeg);
            _take(x, r.user, xLeg);
        } else {
            BalanceDelta d2 = _swap(r.flare, false, int256(r.amount));
            uint256 fIn = _abs(d2.amount1());
            BalanceDelta d1 = _swap(r.xPool, !fIs0, int256(fIn));
            ethLeg = _abs(d2.amount0());
            xLeg = _abs(fIs0 ? d1.amount1() : d1.amount0());
            _payX(x, r.user, xLeg);
            _take(Currency.wrap(address(0)), r.user, ethLeg);
        }
        return abi.encode(ethLeg, xLeg);
    }

    function _payX(Currency x, address from, uint256 amount) internal {
        _sync(x);
        IERC20(Currency.unwrap(x)).transferFrom(from, address(settlement), amount);
        _settle();
    }

    receive() external payable {}
}

/// @notice A creator contract that, when the vault pays it (inside the vault's own lock), trades on a Stealth pool with
///         the manager still unlocked, then tries to also poke the vault's deltas. The pool can be the coin's own or
///         another coin's (cross-pool re-entry into `credit`).
contract SwapInsideVaultUnlock is DexBase {
    StealthFeeVault public immutable vault;
    address public token;
    PoolKey internal _key;
    bool internal _done;
    uint256 public tokensBought;

    constructor(StealthFeeVault v, IDexManager m) DexBase(m) {
        vault = v;
    }

    function setup(address token_, PoolKey calldata k) external {
        token = token_;
        _key = k;
    }

    function accept() external {
        vault.acceptCreator(token);
    }

    function claim() external {
        vault.claimCreator(token);
    }

    receive() external payable {
        if (msg.sender != address(settlement) || _done) return;
        _done = true;
        BalanceDelta d = poolManager.swap(
            _key, IDexManager.SwapParams(true, -int256(msg.value / 2), Dex.MIN_SQRT_PRICE + 1), ""
        );
        _settleNative(uint256(uint128(-d.amount0())));
        tokensBought = uint256(uint128(d.amount1()));
        _take(_key.currency1, address(this), tokensBought);
    }
}

/// @notice Holds a pending ERC-20 sync in its own unlock and calls the vault's payouts from inside it.
contract OuterUnlockPayouts is DexCallback {
    StealthFeeVault public immutable vault;
    IERC20 public immutable erc20;
    address public token;
    address public syncedAfter;
    uint256 public paid;

    constructor(IDexManager m, StealthFeeVault v, IERC20 e) DexBase(m) {
        vault = v;
        erc20 = e;
    }

    function go(address token_) external {
        token = token_;
        _lockRaw("");
    }

    function _onLock(bytes calldata) internal override returns (bytes memory) {
        _sync(Currency.wrap(address(erc20)));
        erc20.transfer(address(settlement), 7e18);
        vault.sweep(_arr(token));
        syncedAfter = Currency.unwrap(DexTestLib.syncedCurrency(poolManager));
        paid = _settle();
        _take(Currency.wrap(address(erc20)), address(this), paid);
        return "";
    }

    function _arr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}

/// @notice Attack ideas that FAILED (the defence holds). Each test passes because the attack does not work.
contract ReviewAttemptsTest is BaseTest {
    uint24 internal constant PIPS = 1_000_000;

    function _ceil(uint256 gross, uint24 rate) internal pure returns (uint256) {
        return (gross * rate + PIPS - 1) / PIPS;
    }

    function _swapL(address who, address token, bool zfo, int256 amt, uint160 limit, uint256 value)
        internal
        returns (BalanceDelta d)
    {
        PoolKey memory key = _key(token);
        vm.startPrank(who);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        d = swapRouter.swap{value: value}(
            key,
            IDexManager.SwapParams(zfo, amt, limit),
            TestRouter.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function _tier(uint8 seed) internal pure returns (uint16) {
        uint16[5] memory tiers = [uint16(125), 225, 325, 425, 575];
        return tiers[seed % 5];
    }

    /// @dev The anti-sniper line worked out independently of the hook.
    function _expectedRate(address token) internal view returns (uint24) {
        uint24 tax = hook.getConfig(token).taxFee;
        uint256 elapsed = block.timestamp - hook.getConfig(token).launchTime;
        return elapsed < 15 ? uint24(900_000 - (uint256(900_000 - tax) * elapsed) / 15) : tax;
    }

    // ---------------------------------------------------------------------
    // 1. Fee == ceil(rate x gross quote leg) in all four modes, with arbitrary price limits in the afterSwap modes
    //    and timestamps straddling the sniper-window boundary.
    // ---------------------------------------------------------------------

    function testFuzz_attempt_feeIsCeilRateGross_anyMode_anyLimit_anyTime(
        uint8 mode,
        uint256 amtSeed,
        uint256 limitSeed,
        uint8 tOffset,
        uint8 tier
    ) public {
        address token = _launchWith(creator, _tier(tier), 4 ether, 0);
        uint256 end = hook.sniperWindowEnd(token);
        vm.warp(end);
        _buy(traders[0], token, 2 ether); // inventory + ETH in the pool
        // land anywhere from 3 s before the window closes to 3 s after it
        vm.warp(end - 3 + (tOffset % 7));
        uint24 rate = _expectedRate(token);
        assertEq(rate, hook.currentFee(token));

        uint160 p = _sqrtPrice(token);
        uint160 start = locker.getPool(token).startSqrtPriceX96;
        uint256 c0 = _vaultClaims();
        mode = mode % 4;
        BalanceDelta d;
        if (mode == 0) {
            uint256 g = bound(amtSeed, 1, 3 ether);
            d = _swapL(traders[1], token, true, -int256(g), MIN_PRICE_LIMIT, g);
            assertEq(uint256(uint128(-d.amount0())), g, "exact-in buy pays exactly G");
        } else if (mode == 1) {
            uint256 x = bound(amtSeed, 1, 0.01 ether);
            d = _swapL(traders[0], token, false, int256(x), MAX_PRICE_LIMIT, 0);
            assertEq(uint256(uint128(d.amount0())), x, "exact-out sell receives exactly X");
        } else if (mode == 2) {
            uint256 out = bound(amtSeed, 1, 100_000_000e18);
            uint160 limit = uint160(uint256(p) * (9000 + (limitSeed % 1000)) / 10_000);
            if (limitSeed % 3 == 0) limit = MIN_PRICE_LIMIT;
            vm.deal(traders[1], 20_000 ether);
            d = _swapL(traders[1], token, true, int256(out), limit, 10_000 ether);
        } else {
            uint256 bal = IERC20(token).balanceOf(traders[0]);
            uint256 tin = bound(amtSeed, 1, bal);
            uint160 limit = p + uint160((uint256(start - p) * (1 + (limitSeed % 10_000))) / 10_000);
            d = _swapL(traders[0], token, false, -int256(tin), limit, 0);
        }
        uint256 fee = _vaultClaims() - c0;
        uint256 gross = mode == 0 || mode == 2 ? uint256(uint128(-d.amount0())) : uint256(uint128(d.amount0())) + fee;
        assertEq(fee, _ceil(gross, rate), "fee != ceil(rate x gross ETH leg)");
        if (gross != 0) assertGt(fee, 0, "a swap that moved ETH paid no fee");
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "books");
    }

    /// @notice The window boundary: the last second inside pays the last step of the sniper fee, the first second
    ///         after pays the tier.
    function test_attempt_sniperBoundaryExact() public {
        address token = _launchWith(creator, 125, 4 ether, 0);
        uint256 end = hook.sniperWindowEnd(token);
        vm.warp(end - 1);
        uint256 c0 = _vaultClaims();
        _buy(traders[0], token, 1 ether);
        assertEq(_vaultClaims() - c0, 0.071667 ether, "t = end-1: 90% - 14/15 of the way down to 1.25%");
        vm.warp(end);
        c0 = _vaultClaims();
        _buy(traders[1], token, 1 ether);
        assertEq(_vaultClaims() - c0, 0.0125 ether, "t = end: tax");
    }

    // ---------------------------------------------------------------------
    // 2. Multi-hop routing through a hookless Stealth-token/X pool, all four shapes: fee still exact on the ETH leg.
    // ---------------------------------------------------------------------

    function _xPool(address token) internal returns (PoolKey memory xPool, XToken x) {
        x = new XToken();
        _buy(traders[5], token, 3 ether);
        xPool = address(x) < token
            ? _dexPlainKey(Currency.wrap(address(x)), Currency.wrap(token), 3000, 60)
            : _dexPlainKey(Currency.wrap(token), Currency.wrap(address(x)), 3000, 60);
        manager.initialize(xPool, 79228162514264337593543950336);
        TestRouter lp = new TestRouter(manager);
        x.transfer(traders[5], 1e27);
        vm.startPrank(traders[5]);
        IERC20(token).approve(address(lp), type(uint256).max);
        x.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(xPool, IDexManager.ModifyLiquidityParams(-887220, 887220, 1e26, 0), "");
        vm.stopPrank();
    }

    function _hop(MiniRouter router, MiniRouter.Route memory r, uint24 rate) internal {
        uint256 c0 = _vaultClaims();
        vm.prank(r.user);
        (uint256 ethLeg,) = router.run{value: r.mode == 0 || r.mode == 2 ? 5 ether : 0}(r);
        uint256 fee = _vaultClaims() - c0;
        uint256 gross = (r.mode == 0 || r.mode == 2) ? ethLeg : ethLeg + fee;
        assertGt(fee, 0);
        assertEq(fee, _ceil(gross, rate), "multi-hop fee != ceil(rate x gross ETH leg)");
        if (r.mode == 0) assertEq(ethLeg, r.amount, "exact-in: pays exactly G");
        if (r.mode == 3) assertEq(ethLeg, r.amount, "exact-out: receives exactly X");
    }

    function test_attempt_multiHop_allFourShapes_feeExact() public {
        address token = _launch(325, 4 ether);
        uint24 rate = hook.getConfig(token).taxFee;
        (PoolKey memory xPool, XToken x) = _xPool(token);
        MiniRouter router = new MiniRouter(manager);
        address user = traders[6];
        x.transfer(user, 1e26);
        vm.prank(user);
        x.approve(address(router), type(uint256).max);
        uint256[4] memory amounts = [uint256(0.5 ether), 1e24, 1e24, 0.1 ether];
        for (uint8 m; m < 4; ++m) {
            _hop(router, MiniRouter.Route({mode: m, flare: _key(token), xPool: xPool, amount: amounts[m], user: user}), rate);
        }
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE));
    }

    // ---------------------------------------------------------------------
    // 3. Swapping inside the vault's own lock (reentrancy via take) keeps the books exact.
    // ---------------------------------------------------------------------

    function test_attempt_creatorSwapsInsideVaultPayout_booksExact() public {
        address token = _launch(575, 4 ether);
        _buy(traders[0], token, 2 ether);
        SwapInsideVaultUnlock c = new SwapInsideVaultUnlock(vault, manager);
        c.setup(token, _key(token));
        vm.prank(creator);
        vault.offerCreator(token, address(c));
        c.accept();
        uint256 owed = vault.coinOwed(token);
        c.claim();
        assertGt(c.tokensBought(), 0, "traded inside the vault's lock");
        // The swap's own fee was credited after the payout: owed again, and backed.
        uint256 newFee = _ceil(owed / 2, hook.getConfig(token).taxFee);
        uint24 tier = hook.getConfig(token).taxFee;
        assertEq(vault.coinOwed(token), _coinPart(newFee, tier, tier));
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "claims == owed");
        assertEq(address(c).balance, owed - owed / 2);
    }

    // ---------------------------------------------------------------------
    // 4. Payouts inside someone else's lock with a pending ERC-20 sync: no interference (burn/take never sync).
    // ---------------------------------------------------------------------

    function test_attempt_sweepInsideOuterUnlockWithPendingSync() public {
        address token = _launch(TAX, 4 ether);
        _buy(traders[0], token, 1 ether);
        XToken e = new XToken();
        OuterUnlockPayouts o = new OuterUnlockPayouts(manager, vault, IERC20(address(e)));
        e.transfer(address(o), 10e18);
        uint256 t0 = platform.balance;
        uint256 owedP = vault.platformOwed(token);
        o.go(token);
        assertEq(platform.balance - t0, owedP, "platform paid from inside the outer lock");
        assertEq(o.syncedAfter(), address(e), "caller's pending sync survived");
        assertEq(o.paid(), 7e18, "caller's payment settled normally");
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE));
    }

    // ---------------------------------------------------------------------
    // 5. Dust in the beforeSwap modes: fee == whole input -> amountToSwap 0 -> pool early-returns; no bypass.
    // ---------------------------------------------------------------------

    function test_attempt_dustExactInBuy_allFee_noRevert() public {
        address token = _launch(575, 4 ether);
        for (uint256 g = 1; g <= 12; ++g) {
            uint256 c0 = _vaultClaims();
            BalanceDelta d = _swapL(traders[0], token, true, -int256(g), MIN_PRICE_LIMIT, g);
            assertEq(_vaultClaims() - c0, _ceil(g, 57_500));
            assertEq(uint256(uint128(-d.amount0())), g);
        }
    }

    // ---------------------------------------------------------------------
    // 6. PartialFill bypass: a limit exactly at the fully-filled price passes; one wei tighter reverts. Only the
    //    trader is protected by it (a partial fill here would over-charge them, never under-charge).
    // ---------------------------------------------------------------------

    function test_attempt_partialFill_onlyOverchargesWouldBeBlocked() public {
        address token = _launch(TAX, 4 ether);
        uint256 snap = vm.snapshotState();
        _buy(traders[0], token, 0.999 ether);
        uint160 early = _sqrtPrice(token);
        vm.revertToState(snap);
        _buy(traders[0], token, 1 ether);
        uint160 after_ = _sqrtPrice(token);
        vm.revertToState(snap);
        // limit == the exact end price: full fill, allowed
        _swapL(traders[0], token, true, -1 ether, after_, 1 ether);
        vm.revertToState(snap);
        PoolKey memory key = _key(token);
        vm.prank(traders[0]);
        vm.expectRevert(); // StealthHook.PartialFill (wrapped)
        swapRouter.swap{value: 1 ether}(
            key,
            IDexManager.SwapParams(true, -1 ether, early),
            TestRouter.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
