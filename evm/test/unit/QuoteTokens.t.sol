// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Dex, PoolKey, Currency, BalanceDelta, IDexManager} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {TestRouter} from "../utils/TestRouter.sol";
import {
    MockERC20,
    FeeOnTransferERC20,
    FeeOnTopERC20,
    RebasingERC20,
    NoDecimalsToken
} from "../utils/MockTokens.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {LaunchType} from "../../src/interfaces/IStealth.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthHook} from "../../src/StealthHook.sol";
import {StealthToken} from "../../src/StealthToken.sol";
import {StealthTokenDeployer} from "../../src/StealthTokenDeployer.sol";
import {StealthConstants as C} from "../../src/libraries/StealthConstants.sol";
import {UniversalRouterLib as UR, IUniversalRouter, IDexQuoter, PathKey} from "@dex/UniversalRouterLib.sol";

/// @notice Tokens paired with an ERC-20 quote instead of native: USDT-like 18-decimal and USDC-like 6-decimal quotes,
///         listing and generic target bounds, the transfer check that refuses fee-on-transfer quotes, the token
///         address search, mixed-currency payouts, and a token paired with another Stealth coin (including a
///         native -> coin A -> coin B route through the Universal Router).
contract QuoteTokensTest is BaseTest {
    event QuoteListed(
        address indexed quote, uint8 decimals, uint256 minTarget, uint256 defaultTarget, uint256 maxTarget
    );

    function _bal(Currency q, address who) internal view returns (uint256) {
        return Dex.isNative(q) ? who.balance : IERC20(Currency.unwrap(q)).balanceOf(who);
    }

    function _allowUnlisted() internal {
        vm.prank(admin);
        factory.setUnlistedQuotesAllowed(true);
        _syncConfig();
    }

    // ---------------------------------------------------------------------
    // Full life on an ERC-20 quote, 18 and 6 decimals
    // ---------------------------------------------------------------------

    function test_erc20Quote18_lifecycle() public {
        _lifecycle(18);
    }

    function test_erc20Quote6_lifecycle() public {
        _lifecycle(6);
    }

    function _lifecycle(uint8 decimals) internal {
        MockERC20 q = _listedQuote("QT", decimals, 1, 1_000_000);
        address token = _lifecycleLaunch(q, 10 ** decimals);
        _skipSniperWindow(token);
        _lifecycleTrade(q, token, 10 ** decimals);
        _graduate(token, traders[1]);
        _lifecyclePayout(q, token);
    }

    /// @dev Launch with a first buy of 1 unit: far over the 5% cap, so most of it comes back.
    function _lifecycleLaunch(MockERC20 q, uint256 u) internal returns (address token) {
        Currency qc = Currency.wrap(address(q));
        (uint256 quotedTokens, uint256 quotedUsed) = locker.quoteLaunchBuy(4 * u, TAX, u);
        token = _launchQuote(creator, address(q), TAX, 4 * u, u);
        assertGt(uint160(token), uint160(address(q)), "token address above the quote's");
        assertEq(StealthToken(token).quote(), address(q));
        assertEq(Currency.unwrap(_key(token).currency0), address(q), "the quote is currency0");
        assertEq(Currency.unwrap(vault.quoteOf(token)), address(q));
        assertEq(Currency.unwrap(locker.getPool(token).quote), address(q));
        assertEq(IERC20(token).balanceOf(creator), quotedTokens, "first buy exactly as quoted");
        assertEq(u - q.balanceOf(creator), quotedUsed, "kept exactly what the quote said; the rest refunded");
        assertEq(q.balanceOf(address(locker)) + q.balanceOf(address(factory)) + q.balanceOf(address(hook)), 0);
        assertGt(_vaultClaims(qc), 0);
        assertEq(_vaultClaims(qc), vault.totalOwed(qc), "the first buy's fee is a quote claim");
        assertEq(_vaultClaims(), 0, "no native involved");
    }

    /// @dev All four modes after the sniper window, fees in the quote.
    function _lifecycleTrade(MockERC20 q, address token, uint256 u) internal {
        Currency qc = Currency.wrap(address(q));
        address t = traders[0];
        _fundQuote(token, t, 100 * u);
        uint256 c0 = _vaultClaims(qc);
        BalanceDelta d = _swap(t, token, true, -int256(u), 0);
        assertEq(uint256(uint128(-d.amount0())), u, "exact-in buy pays exactly 1 unit");
        assertEq(_vaultClaims(qc) - c0, _feeOnInput(u, TAX_PIPS));

        c0 = _vaultClaims(qc);
        uint256 got = _sell(t, token, uint256(uint128(d.amount1())) / 2);
        uint256 fee = _vaultClaims(qc) - c0;
        assertEq(fee, _feeOnInput(got + fee, TAX_PIPS), "exact-in sell");

        c0 = _vaultClaims(qc);
        d = _buyExactOut(t, token, 1_000_000e18, 0);
        fee = _vaultClaims(qc) - c0;
        assertEq(fee, _feeOnTop(uint256(uint128(-d.amount0())) - fee, TAX_PIPS), "exact-out buy");

        c0 = _vaultClaims(qc);
        uint256 before = q.balanceOf(t);
        _sellExactOut(t, token, u / 100);
        assertEq(q.balanceOf(t) - before, u / 100, "exact-out sell");
        assertEq(_vaultClaims(qc) - c0, _feeOnTop(u / 100, TAX_PIPS));
    }

    /// @dev Pay everybody, in the quote.
    function _lifecyclePayout(MockERC20 q, address token) internal {
        Currency qc = Currency.wrap(address(q));
        assertEq(_vaultClaims(qc), _vaultOwed(_one(token)));
        uint256[3] memory owed = [vault.marketingOwed(token), vault.platformOwed(token), vault.coinOwed(token)];
        uint256[3] memory before = [q.balanceOf(marketing), q.balanceOf(platform), q.balanceOf(creator)];
        vm.prank(creator);
        vault.claimCreator(token);
        vm.prank(claimer);
        vault.sweep(_one(token));
        assertEq(q.balanceOf(marketing) - before[0], owed[0]);
        assertEq(q.balanceOf(platform) - before[1], owed[1]);
        assertEq(q.balanceOf(creator) - before[2], owed[2]);
        assertEq(_vaultClaims(qc), 0);
        assertEq(vault.totalOwed(qc), 0);
        assertEq(marketing.balance, ACTOR_BALANCE, "no native moved");
    }

    // ---------------------------------------------------------------------
    // Listing and target bounds
    // ---------------------------------------------------------------------

    function test_listQuote_validation() public {
        MockERC20 q = new MockERC20("Q", "Q", 6);
        vm.prank(attacker);
        vm.expectRevert(StealthFactory.NotAdmin.selector);
        factory.listQuote(address(q), 1e6, 1e6, 2e6);

        vm.startPrank(admin);
        (uint256 lo, uint256 hi) = factory.quoteTargetBounds(6);
        assertEq(lo, 1e4, "0.01 units");
        assertEq(hi, 1e18, "10^12 units");
        vm.expectRevert(StealthFactory.OutOfRange.selector);
        factory.listQuote(address(q), lo - 1, lo, hi);
        vm.expectRevert(StealthFactory.OutOfRange.selector);
        factory.listQuote(address(q), lo, lo, hi + 1);
        vm.expectRevert(StealthFactory.OutOfRange.selector);
        factory.listQuote(address(q), 2e6, 1e6, 3e6);

        address five = address(new MockERC20("Q5", "Q5", 5));
        address nineteen = address(new MockERC20("Q19", "Q19", 19));
        address noDecimals = address(new NoDecimalsToken());
        vm.expectRevert(StealthFactory.UnsupportedQuote.selector);
        factory.listQuote(five, 1e5, 1e5, 1e6);
        vm.expectRevert(StealthFactory.UnsupportedQuote.selector);
        factory.listQuote(nineteen, 1e19, 1e19, 1e20);
        vm.expectRevert(StealthFactory.InvalidQuote.selector);
        factory.listQuote(noDecimals, 1e6, 1e6, 2e6);
        vm.expectRevert(StealthFactory.InvalidQuote.selector);
        factory.listQuote(makeAddr("eoa"), 1e6, 1e6, 2e6);

        vm.expectEmit(true, false, false, true, address(factory));
        emit QuoteListed(address(q), 6, 1e6, 2e6, 3e6);
        factory.listQuote(address(q), 1e6, 2e6, 3e6);
        StealthFactory.QuoteConfig memory qc = factory.quoteConfig(address(q));
        assertTrue(qc.listed);
        assertEq(qc.decimals, 6);
        assertEq(qc.defaultTarget, 2e6);

        factory.delistQuote(address(q));
        assertFalse(factory.quoteConfig(address(q)).listed);
        vm.expectRevert(StealthFactory.QuoteNotListed.selector);
        factory.delistQuote(address(q));
        vm.stopPrank();
    }

    function test_listedQuote_rangeEnforced() public {
        MockERC20 q = _listedQuote("QT", 18, 100, 1_000);
        q.mint(creator, 1e30);
        vm.startPrank(creator);
        q.approve(address(factory), type(uint256).max);
        vm.expectRevert(StealthFactory.InvalidTarget.selector);
        factory.launch(_paramsQ(address(q), TAX, 100e18 - 1, 0, 0));
        vm.expectRevert(StealthFactory.InvalidTarget.selector);
        factory.launch(_paramsQ(address(q), TAX, 1_000e18 + 1, 0, 0));
        factory.launch(_paramsQ(address(q), TAX, 100e18, 0, 0));
        factory.launch(_paramsQ(address(q), TAX, 1_000e18, 0, 0));
        vm.stopPrank();
    }

    function test_unlistedQuote_refusedUnlessAllowed_thenGenericBounds() public {
        MockERC20 q = new MockERC20("Q", "Q", 6);
        q.mint(creator, 1e30);
        vm.prank(creator);
        q.approve(address(factory), type(uint256).max);
        vm.prank(creator);
        vm.expectRevert(StealthFactory.QuoteNotListed.selector);
        factory.launch(_paramsQ(address(q), TAX, 1e6, 0, 0));

        _allowUnlisted();
        vm.startPrank(creator);
        vm.expectRevert(StealthFactory.InvalidTarget.selector);
        factory.launch(_paramsQ(address(q), TAX, 1e4 - 1, 0, 0));
        vm.expectRevert(StealthFactory.InvalidTarget.selector);
        factory.launch(_paramsQ(address(q), TAX, 1e18 + 1, 0, 0));
        address low = factory.launch(_paramsQ(address(q), TAX, 1e4, 0, 0)); // 0.01 units
        address high = factory.launch(_paramsQ(address(q), TAX, 1e18, 0, 0)); // 10^12 units
        vm.stopPrank();
        assertApproxEqRel(locker.getPool(low).graduationQuote, 1e4, 3e15);
        assertApproxEqRel(locker.getPool(high).graduationQuote, 1e18, 3e15);
        // Both ends trade: a buy through the whole curve on the low one graduates it.
        _skipSniperWindow(low);
        _graduate(low, traders[0]);
    }

    function test_revert_badQuoteAddresses() public {
        _allowUnlisted();
        address[5] memory bad =
            [makeAddr("eoa"), address(vault), address(hook), address(manager), address(new NoDecimalsToken())];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(creator);
            vm.expectRevert(StealthFactory.InvalidQuote.selector);
            factory.launch(_paramsQ(bad[i], TAX, 1e18, 0, 0));
        }
        address five = address(new MockERC20("Q5", "Q5", 5));
        vm.prank(creator);
        vm.expectRevert(StealthFactory.UnsupportedQuote.selector);
        factory.launch(_paramsQ(five, TAX, 1e5, 0, 0));
    }

    // ---------------------------------------------------------------------
    // Transfer checks: fee-on-transfer and friends
    // ---------------------------------------------------------------------

    function test_revert_feeOnTransferQuote_evenIfListed() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20(18, 100); // 1% burned on every transfer
        vm.prank(admin);
        factory.listQuote(address(fot), 1e18, 1e18, 10e18); // an admin mistake: the launch still refuses it
        _syncConfig();
        fot.mint(creator, 100e18);
        vm.startPrank(creator);
        fot.approve(address(factory), type(uint256).max);
        vm.expectRevert(StealthFactory.UnsupportedQuote.selector);
        factory.launch(_paramsQ(address(fot), TAX, 4e18, 1e18, 0)); // with a first buy
        vm.expectRevert(StealthFactory.UnsupportedQuote.selector);
        factory.launch(_paramsQ(address(fot), TAX, 4e18, 0, 0)); // and without: the probe catches it
        vm.stopPrank();
    }

    /// @dev Even a 0.01% fee on a 6-decimal token is caught by the probe (10,000 raw units at least).
    function test_revert_tinyFeeOnTransfer_sixDecimals() public {
        _allowUnlisted();
        FeeOnTransferERC20 fot = new FeeOnTransferERC20(6, 1);
        assertEq(factory.quoteProbeAmount(address(fot)), 10_000);
        fot.mint(creator, 1e12);
        vm.startPrank(creator);
        fot.approve(address(factory), type(uint256).max);
        vm.expectRevert(StealthFactory.UnsupportedQuote.selector);
        factory.launch(_paramsQ(address(fot), TAX, 4e6, 0, 0));
        vm.stopPrank();
    }

    function test_revert_feeOnTopQuote() public {
        _allowUnlisted();
        FeeOnTopERC20 fot = new FeeOnTopERC20(18, 1);
        fot.mint(creator, 100e18);
        vm.startPrank(creator);
        fot.approve(address(factory), type(uint256).max);
        vm.expectRevert(StealthFactory.UnsupportedQuote.selector);
        factory.launch(_paramsQ(address(fot), TAX, 4e18, 0, 0));
        vm.stopPrank();
    }

    /// @dev A rebasing token moves exact amounts, so no transfer check can see it. This is why mainnet refuses
    ///      unlisted quotes (`unlistedQuotesAllowed` false) and the admin vets each listing (docs/SPEC.md).
    function test_rebasingQuote_isNotDetectableByTransfers() public {
        _allowUnlisted();
        RebasingERC20 rb = new RebasingERC20();
        rb.mint(creator, 100e18);
        vm.startPrank(creator);
        rb.approve(address(factory), type(uint256).max);
        address token = factory.launch(_paramsQ(address(rb), TAX, 4e18, 0, 0));
        vm.stopPrank();
        assertEq(StealthToken(token).quote(), address(rb));
    }

    function test_probe_returnedExactly_andNeedsAnApproval() public {
        _allowUnlisted();
        MockERC20 q = new MockERC20("Q", "Q", 18);
        uint256 probe = factory.quoteProbeAmount(address(q));
        assertEq(probe, 1e14, "10^(18-4)");
        q.mint(creator, probe);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, probe)
        );
        factory.launch(_paramsQ(address(q), TAX, 4e18, 0, 0));

        vm.startPrank(creator);
        q.approve(address(factory), probe);
        address token = factory.launch(_paramsQ(address(q), TAX, 4e18, 0, 0));
        vm.stopPrank();
        assertEq(q.balanceOf(creator), probe, "the probe came straight back");
        assertEq(IERC20(token).balanceOf(creator), 0, "no first buy");
        assertEq(_vaultClaims(Currency.wrap(address(q))), 0, "no fee");
        assertEq(q.balanceOf(address(locker)), 0);
    }

    function test_erc20Launch_valueIsTheLaunchFeeOnly() public {
        MockERC20 q = _listedQuote("QT", 18, 1, 100);
        q.mint(creator, 1e18);
        vm.prank(creator);
        q.approve(address(factory), type(uint256).max);
        vm.prank(creator);
        vm.expectRevert(StealthFactory.InvalidValue.selector);
        factory.launch{value: 1}(_paramsQ(address(q), TAX, 4e18, 0, 0));

        vm.prank(admin);
        factory.setLaunchFee(0.01 ether);
        _syncConfig();
        vm.prank(creator);
        vm.expectRevert(StealthFactory.InvalidValue.selector);
        factory.launch{value: 0.02 ether}(_paramsQ(address(q), TAX, 4e18, 0, 0));
        uint256 tb = platform.balance;
        vm.prank(creator);
        address token = factory.launch{value: 0.01 ether}(_paramsQ(address(q), TAX, 4e18, 0.1e18, 0));
        assertEq(platform.balance - tb, 0.01 ether, "launch fee in native, to the platform");
        assertEq(vault.launchFeePaid(token), 0.01 ether);
        assertGt(IERC20(token).balanceOf(creator), 0);
    }

    function test_revert_erc20FirstBuy_slippage() public {
        MockERC20 q = _listedQuote("QT", 6, 1, 100);
        q.mint(creator, 10e6);
        vm.startPrank(creator);
        q.approve(address(factory), type(uint256).max);
        vm.expectRevert(StealthLocker.Slippage.selector);
        factory.launch(_paramsQ(address(q), TAX, 4e6, 1e6, C.LAUNCH_ALLOWANCE + 1));
        vm.stopPrank();
        assertEq(q.balanceOf(creator), 10e6, "nothing moved");
    }

    // ---------------------------------------------------------------------
    // Token address search
    // ---------------------------------------------------------------------

    function test_highQuoteAddress_tokenMinedAbove() public {
        _allowUnlisted();
        address high = address(uint160(0xF) << 156); // 0xF000...0: only 1 address in 16 is above it
        deployCodeTo("MockTokens.sol:MockERC20", abi.encode("High", "HI", uint8(18)), high);
        StealthFactory.LaunchParams memory p = _paramsQ(high, TAX, 4e18, 0, 0);
        address predicted = factory.predictTokenAddress(creator, p);
        address token = _launchQuote(creator, high, TAX, 4e18, 0);
        assertEq(token, predicted, "prediction follows the search");
        assertGt(uint160(token), uint160(high));
        _skipSniperWindow(token);
        _fundQuote(token, traders[0], 10e18);
        assertGt(_buy(traders[0], token, 1e18), 0, "trades like any other");
    }

    function test_revert_quoteAddressTooHigh() public {
        _allowUnlisted();
        address top = address(type(uint160).max - 0xffff);
        deployCodeTo("MockTokens.sol:MockERC20", abi.encode("Top", "TOP", uint8(18)), top);
        MockERC20(top).mint(creator, 1e18);
        vm.startPrank(creator);
        MockERC20(top).approve(address(factory), type(uint256).max);
        vm.expectRevert(StealthTokenDeployer.QuoteAddressTooHigh.selector);
        factory.launch(_paramsQ(top, TAX, 4e18, 0, 0));
        vm.stopPrank();
    }

    /// @dev The registered quote lives in the fee vault now; a pool opened with another currency0 is refused.
    function test_revert_hookInitialize_wrongQuote() public {
        address token = address(type(uint160).max - 5);
        MockERC20 other = new MockERC20("Other", "OT", 18);
        uint160 price = 2 ** 96;
        vm.startPrank(address(locker));
        hook.register(token, _reg(TAX_PIPS, price, price / 2));
        PoolKey memory key =
            Dex.key(Currency.wrap(address(other)), token, address(hook), address(manager), C.POOL_FEE, C.TICK_SPACING);
        vm.expectRevert();
        manager.initialize(key, price);
        vm.stopPrank();
        assertEq(hook.getConfig(token).launchTime, 0, "no pool");
    }

    // ---------------------------------------------------------------------
    // Mixed currencies in the StealthFeeVault
    // ---------------------------------------------------------------------

    function _launchMarketing(address quote, uint256 target) internal returns (address token) {
        uint256 pull = factory.quoteProbeAmount(quote);
        deal(quote, creator, IERC20(quote).balanceOf(creator) + pull);
        StealthFactory.LaunchParams memory p = _paramsQ(quote, TAX, target, 0, 0);
        p.options = _typed(LaunchType.Marketing);
        vm.startPrank(creator);
        IERC20(quote).approve(address(factory), pull);
        token = factory.launch(p);
        vm.stopPrank();
    }

    function test_sweep_mixedCurrencies_paysEachInItsOwn() public {
        MockERC20 q18 = _listedQuote("Q18", 18, 1, 100);
        MockERC20 q6 = _listedQuote("Q6", 6, 1, 100);
        // Interleaved on purpose: native, q18, q6, native.
        address[] memory list = new address[](4);
        // Marketing coins, so both wallets are owed in every currency.
        list[0] = _launchOpts(creator, TAX, 0, _typed(LaunchType.Marketing));
        list[1] = _launchMarketing(address(q18), 4e18);
        list[2] = _launchMarketing(address(q6), 4e6);
        list[3] = _launchOpts(creator, 575, 0, _typed(LaunchType.Marketing));
        _skipSniperWindow(list[3]);
        for (uint256 i; i < list.length; ++i) {
            uint256 u = i == 2 ? 1e6 : 1e18;
            _fundQuote(list[i], traders[0], 10 * u);
            uint256 got = _buy(traders[0], list[i], u);
            _sell(traders[0], list[i], got / 2);
        }
        Currency[3] memory cs = [NATIVE, Currency.wrap(address(q18)), Currency.wrap(address(q6))];
        uint256[3] memory expectM;
        uint256[3] memory expectP;
        uint256[3] memory mb;
        uint256[3] memory tb;
        for (uint256 i; i < list.length; ++i) {
            uint256 j = i == 3 ? 0 : i;
            expectM[j] += vault.marketingOwed(list[i]);
            expectP[j] += vault.platformOwed(list[i]);
        }
        for (uint256 j; j < 3; ++j) {
            mb[j] = _bal(cs[j], marketing);
            tb[j] = _bal(cs[j], platform);
        }
        vault.sweep(list);
        for (uint256 j; j < 3; ++j) {
            assertEq(_bal(cs[j], marketing) - mb[j], expectM[j], "marketing paid in its currency");
            assertEq(_bal(cs[j], platform) - tb[j], expectP[j], "platform paid in its currency");
            assertEq(_vaultClaims(cs[j]), vault.totalOwed(cs[j]), "claims == owed per currency");
            assertGt(expectM[j], 0);
        }
        for (uint256 i; i < list.length; ++i) {
            assertEq(vault.marketingOwed(list[i]) + vault.platformOwed(list[i]), 0);
        }
    }

    /// @dev Claims gifted in an ERC-20 are skimmed to the platform in that ERC-20; owed balances untouched.
    function test_skim_perCurrency() public {
        MockERC20 q = _listedQuote("QT", 18, 1, 100);
        Currency qc = Currency.wrap(address(q));
        address token = _launchQuote(creator, address(q), TAX, 4e18, 0);
        _skipSniperWindow(token);
        _fundQuote(token, traders[0], 10e18);
        uint256 got = _buy(traders[0], token, 1e18);
        // A sell paid out as an ERC-6909 claim, then gifted to the vault.
        PoolKey memory key = _key(token);
        vm.startPrank(traders[0]);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        BalanceDelta d = swapRouter.swap(
            key,
            IDexManager.SwapParams(false, -int256(got / 2), MAX_PRICE_LIMIT),
            TestRouter.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );
        uint256 gift = uint256(uint128(d.amount0()));
        _dexTransferClaims(address(vault), qc, gift);
        vm.stopPrank();
        uint256 owed = vault.totalOwed(qc);
        assertEq(_vaultClaims(qc), owed + gift);
        (uint256 c0,) = vault.skim(NATIVE);
        assertEq(c0, 0, "other currencies untouched");
        uint256 tb = q.balanceOf(platform);
        (uint256 claims,) = vault.skim(qc);
        assertEq(claims, gift);
        assertEq(q.balanceOf(platform) - tb, gift);
        assertEq(_vaultClaims(qc), owed, "owed untouched");
    }

    // ---------------------------------------------------------------------
    // Another Stealth coin as the quote
    // ---------------------------------------------------------------------

    function test_stealthCoinAsQuote_launchTradeAndRoute() public {
        _allowUnlisted();
        // Coin A, paired with native.
        address coinA = _launch(TAX, 4 ether);
        assertGt(_buy(creator, coinA, 1 ether), 0);

        // Coin B, paired with A, with a first buy paid in A. The deployer finds B an address above A.
        vm.startPrank(creator);
        IERC20(coinA).approve(address(factory), type(uint256).max);
        address coinB = factory.launch(_paramsQ(coinA, 325, 10_000_000e18, 1_000_000e18, 0)); // target 10M A
        vm.stopPrank();
        assertGt(uint160(coinB), uint160(coinA));
        assertEq(StealthToken(coinB).quote(), coinA);
        Currency qa = Currency.wrap(coinA);
        assertGt(_vaultClaims(qa), 0, "B's first-buy fee is a claim on A");
        assertEq(_vaultClaims(qa), vault.totalOwed(qa));
        assertEq(IERC20(coinA).balanceOf(address(locker)), 0);

        _skipSniperWindow(coinB);
        _routeNativeToB(coinA, coinB);

        // B's creator is paid in A.
        uint256 owed = vault.coinOwed(coinB);
        uint256 before = IERC20(coinA).balanceOf(creator);
        vm.prank(creator);
        vault.claimCreator(coinB);
        assertEq(IERC20(coinA).balanceOf(creator) - before, owed);
        assertEq(_vaultClaims(qa), vault.totalOwed(qa));
    }

    /// @dev native -> A -> B through the Universal Router: each hop pays its own pool's fee, in its own quote.
    function _routeNativeToB(address coinA, address coinB) internal {
        Currency qa = Currency.wrap(coinA);
        PathKey[] memory path = new PathKey[](2);
        path[0] = UR.hop(_key(coinA), qa);
        path[1] = UR.hop(_key(coinB), Currency.wrap(coinB));
        (uint256 quoted,) = IDexQuoter(_dexQuoter()).quoteExactInput(IDexQuoter.QuoteExactParams(NATIVE, path, 1 ether));
        assertGt(quoted, 0);
        uint256 aOut = _snapQuoteIn(coinA, 1 ether); // what the first hop yields
        uint256 native0 = _vaultClaims();
        uint256 a0 = _vaultClaims(qa);
        (bytes memory commands, bytes[] memory inputs) = UR.exactInPath(NATIVE, path, 1 ether, quoted);
        vm.prank(traders[2]);
        IUniversalRouter(_dexRouter()).execute{value: 1 ether}(commands, inputs, block.timestamp);
        assertEq(IERC20(coinB).balanceOf(traders[2]), quoted, "route filled as quoted");
        assertEq(_vaultClaims() - native0, _feeOnInput(1 ether, TAX_PIPS), "hop 1: A's fee in native");
        assertEq(_vaultClaims(qa) - a0, _feeOnInput(aOut, 32_500), "hop 2: B's fee in A");
        assertEq(IERC20(coinA).balanceOf(_dexRouter()) + IERC20(coinB).balanceOf(_dexRouter()), 0);
    }

    /// @dev The first hop's output, on a snapshot.
    function _snapQuoteIn(address coin, uint256 nativeIn) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        out = _buy(traders[9], coin, nativeIn);
        vm.revertToState(snap);
    }
}
