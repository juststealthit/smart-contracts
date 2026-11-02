// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Dex, IDexManager, PoolKey, BalanceDelta, Currency} from "@dex/Dex.sol";
import {DexTest} from "@dex/DexTest.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthHook} from "../../src/StealthHook.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthToken} from "../../src/StealthToken.sol";
import {StealthTokenDeployer} from "../../src/StealthTokenDeployer.sol";
import {StealthRouter} from "../../src/StealthRouter.sol";
import {LaunchType, TeamShare} from "../../src/interfaces/IStealth.sol";
import {StealthDeploy} from "../../script/lib/StealthDeploy.sol";
import {TestRouter} from "./TestRouter.sol";
import {MockERC20} from "./MockTokens.sol";

/// @notice Deploys the full system against the production DEX bytecode, placed at its real addresses so its immutables
///         line up (see test/fixtures/README.md). The same tests run on both builds: `DexTest` is the build's own.
abstract contract BaseTest is DexTest {
    Currency internal constant NATIVE = Currency.wrap(address(0));
    uint160 internal constant MIN_PRICE_LIMIT = Dex.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = Dex.MAX_SQRT_PRICE - 1;
    uint256 internal constant ACTOR_BALANCE = 10_000 ether;
    bytes32 internal constant CURVE_SALT = bytes32(0);
    bytes32 internal constant TAIL_SALT = bytes32(uint256(1));
    /// @dev The tiers, in bps and pips. `TAX` is the one most tests use.
    uint16 internal constant TAX = 425;
    uint24 internal constant TAX_PIPS = 42_500;
    uint256 internal constant TARGET = 4 ether;

    TestRouter internal swapRouter;

    StealthFeeVault internal vault;
    StealthTokenDeployer internal tokenDeployer;
    StealthLocker internal locker;
    StealthHook internal hook;
    StealthFactory internal factory;
    StealthRouter internal stealthRouter;

    // Roles.
    address internal deployer;
    address internal admin = makeAddr("admin");
    address internal platform = makeAddr("platform");
    address internal marketing = makeAddr("marketing");
    address internal claimer = makeAddr("claimer");
    address internal creatorManager = makeAddr("creatorManager");
    address internal distributor = makeAddr("distributor");
    address internal creator = makeAddr("creator1");
    address internal creator2 = makeAddr("creator2");
    address internal handoff = makeAddr("creatorHandoff");
    address internal sniper = makeAddr("sniper");
    address internal attacker = makeAddr("attacker");
    address[] internal traders;

    /// @dev The factory's config version, cached so `_params` makes no external call (which would consume a prank).
    uint64 internal cfgVersion;

    /// @dev Fork tests on a live chain salt every actor's label: a deterministic test address can collide with a
    ///      contract deployed on that chain.
    function _actorSalt() internal view virtual returns (string memory) {
        return "";
    }

    function _actor(string memory name) internal returns (address) {
        return makeAddr(string.concat(name, _actorSalt()));
    }

    function setUp() public virtual {
        if (bytes(_actorSalt()).length != 0) {
            admin = _actor("admin");
            platform = _actor("platform");
            marketing = _actor("marketing");
            claimer = _actor("claimer");
            creatorManager = _actor("creatorManager");
            distributor = _actor("distributor");
            creator = _actor("creator1");
            creator2 = _actor("creator2");
            handoff = _actor("creatorHandoff");
            sniper = _actor("sniper");
            attacker = _actor("attacker");
        }
        _installDex();
        swapRouter = new TestRouter(manager);

        for (uint256 i; i < 10; ++i) {
            traders.push(_actor(string.concat("trader", vm.toString(i + 1))));
            vm.deal(traders[i], ACTOR_BALANCE);
        }
        address[9] memory everyone = [admin, platform, marketing, claimer, creator, creator2, handoff, sniper, attacker];
        for (uint256 i; i < everyone.length; ++i) {
            vm.deal(everyone[i], ACTOR_BALANCE);
        }

        deployer = address(this);
        StealthDeploy.System memory s = StealthDeploy.deploy(_deployParams(), deployer);
        vault = s.feeVault;
        tokenDeployer = s.tokenDeployer;
        locker = s.locker;
        hook = s.hook;
        factory = s.factory;
        stealthRouter = s.router;
        cfgVersion = factory.configVersion();

        vm.label(address(vault), "StealthFeeVault");
        vm.label(address(tokenDeployer), "StealthTokenDeployer");
        vm.label(address(locker), "StealthLocker");
        vm.label(address(hook), "StealthHook");
        vm.label(address(factory), "StealthFactory");
        vm.label(address(manager), "PoolManager");
    }

    /// @dev Native targets 4-10 by default. Override for other runs.
    function _deployParams() internal virtual returns (StealthDeploy.Params memory p) {
        p.poolManager = manager;
        p.admin = admin;
        p.platform = platform;
        p.marketing = marketing;
        p.creatorManager = creatorManager;
        p.distributor = distributor;
        p.permit2 = _dexPermit2();
        p.reassignNotice = 24 hours;
        p.targetFloor = 4 ether;
        p.targetCeiling = 10 ether;
        p.config = StealthDeploy.config(4 ether, 4 ether, 10 ether);
    }

    // ---------------------------------------------------------------------
    // Launch helpers
    // ---------------------------------------------------------------------

    function _socials() internal pure returns (StealthToken.Socials memory) {
        return StealthToken.Socials({
            twitter: "https://x.com/stealthpad",
            telegram: "https://t.me/stealthpad",
            discord: "",
            website: "https://stealthpad.xyz",
            farcaster: ""
        });
    }

    /// @dev Call after changing the factory config, before the next launch.
    function _syncConfig() internal {
        cfgVersion = factory.configVersion();
    }

    function _params(uint16 taxBps, uint256 target, uint256 minOut)
        internal
        view
        returns (StealthFactory.LaunchParams memory)
    {
        return _paramsQ(address(0), taxBps, target, 0, minOut);
    }

    function _paramsQ(address quote, uint16 taxBps, uint256 target, uint256 quoteAmount, uint256 minOut)
        internal
        view
        returns (StealthFactory.LaunchParams memory)
    {
        return StealthFactory.LaunchParams({
            name: "Stealth Test",
            symbol: "MKT",
            logo: "ipfs://bafystealthtestlogo",
            description: "A Stealth test token.",
            socials: _socials(),
            taxBps: taxBps,
            quote: quote,
            target: target,
            quoteAmount: quoteAmount,
            minTokensOut: minOut,
            configVersion: cfgVersion,
            creator: address(0),
            options: _noOptions()
        });
    }

    /// @dev Creator type, no limits, no lock.
    function _noOptions() internal pure returns (StealthFactory.LaunchOptions memory o) {}

    /// @dev Options with a launch type and nothing else.
    function _typed(LaunchType t) internal pure returns (StealthFactory.LaunchOptions memory o) {
        o.launchType = t;
    }

    /// @dev Options for a Team launch with these wallets and bps.
    function _teamOf(address[] memory wallets, uint16[] memory bps)
        internal
        pure
        returns (StealthFactory.LaunchOptions memory o)
    {
        o.launchType = LaunchType.Team;
        o.team = new TeamShare[](wallets.length);
        for (uint256 i; i < wallets.length; ++i) {
            o.team[i] = TeamShare(wallets[i], bps[i]);
        }
    }

    /// @dev Launches a native-paired token from `who` with options, `value` as launch fee plus first buy.
    function _launchOpts(address who, uint16 taxBps, uint256 value, StealthFactory.LaunchOptions memory o)
        internal
        returns (address token)
    {
        StealthFactory.LaunchParams memory p = _params(taxBps, 4 ether, 0);
        p.options = o;
        vm.prank(who);
        token = factory.launch{value: value}(p);
    }

    /// @dev Launches from `who` with `value` as the launch fee plus first buy. Stays inside the sniper window.
    function _launchWith(address who, uint16 taxBps, uint256 target, uint256 value) internal returns (address token) {
        vm.prank(who);
        token = factory.launch{value: value}(_params(taxBps, target, 0));
    }

    /// @dev Launches with no first buy, then waits out the sniper window.
    function _launch(uint16 taxBps, uint256 target) internal returns (address token) {
        token = _launchWith(creator, taxBps, target, 0);
        _skipSniperWindow(token);
    }

    /// @dev Launches a token paired with an ERC-20 quote from `who`, minting `who` what the launch pulls.
    function _launchQuote(address who, address quote, uint16 taxBps, uint256 target, uint256 quoteAmount)
        internal
        returns (address token)
    {
        uint256 pull = factory.quoteProbeAmount(quote);
        if (quoteAmount > pull) pull = quoteAmount;
        deal(quote, who, IERC20(quote).balanceOf(who) + pull);
        StealthFactory.LaunchParams memory p = _paramsQ(quote, taxBps, target, quoteAmount, 0);
        uint256 fee = factory.config().launchFee;
        vm.startPrank(who);
        IERC20(quote).approve(address(factory), pull);
        token = factory.launch{value: fee}(p);
        vm.stopPrank();
    }

    /// @dev A mock quote listed with a target range of [minUnits, maxUnits] whole units (default the minimum).
    function _listedQuote(string memory symbol, uint8 decimals, uint256 minUnits, uint256 maxUnits)
        internal
        returns (MockERC20 q)
    {
        q = new MockERC20(string.concat("Mock ", symbol), symbol, decimals);
        uint256 unit = 10 ** decimals;
        vm.prank(admin);
        factory.listQuote(address(q), minUnits * unit, minUnits * unit, maxUnits * unit);
        _syncConfig();
    }

    /// @dev A hook registration with no buy limit.
    function _reg(uint24 tax, uint160 start, uint160 grad) internal pure returns (StealthHook.Registration memory r) {
        r.taxFee = tax;
        r.startSqrtPriceX96 = start;
        r.graduationSqrtPriceX96 = grad;
    }

    function _skipSniperWindow(address token) internal {
        uint256 end = hook.sniperWindowEnd(token);
        if (block.timestamp < end) vm.warp(end);
    }

    // ---------------------------------------------------------------------
    // Pool helpers
    // ---------------------------------------------------------------------

    function _key(address token) internal view returns (PoolKey memory) {
        return locker.poolKey(token);
    }

    function _poolId(address token) internal view returns (bytes32) {
        return Dex.id(_key(token));
    }

    function _quoteOf(address token) internal view returns (Currency) {
        return vault.quoteOf(token);
    }

    function _sqrtPrice(address token) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = _getSlot0(_poolId(token));
    }

    function _lpFee(address token) internal view returns (uint24 lpFee) {
        (,,, lpFee) = _getSlot0(_poolId(token));
    }

    /// @dev Balance of the token's quote currency (native or the ERC-20).
    function _quoteBalance(address token, address who) internal view returns (uint256) {
        Currency q = _quoteOf(token);
        return Dex.isNative(q) ? who.balance : IERC20(Currency.unwrap(q)).balanceOf(who);
    }

    /// @dev Gives `who` `amount` more of the token's quote.
    function _fundQuote(address token, address who, uint256 amount) internal {
        Currency q = _quoteOf(token);
        if (Dex.isNative(q)) vm.deal(who, who.balance + amount);
        else deal(Currency.unwrap(q), who, IERC20(Currency.unwrap(q)).balanceOf(who) + amount);
    }

    function _settings() internal pure returns (TestRouter.TestSettings memory) {
        return TestRouter.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    /// @dev amountSpecified < 0 is exact input, > 0 is exact output. `value` is native sent along (native-paired buys).
    function _swap(address who, address token, bool zeroForOne, int256 amountSpecified, uint256 value)
        internal
        returns (BalanceDelta delta)
    {
        PoolKey memory key = _key(token);
        vm.startPrank(who);
        if (!zeroForOne && IERC20(token).allowance(who, address(swapRouter)) < type(uint128).max) {
            IERC20(token).approve(address(swapRouter), type(uint256).max);
        }
        if (zeroForOne && !Dex.isNative(key.currency0)) {
            IERC20(Currency.unwrap(key.currency0)).approve(address(swapRouter), type(uint256).max);
            value = 0;
        }
        delta = swapRouter.swap{value: value}(
            key,
            IDexManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            _settings(),
            ""
        );
        vm.stopPrank();
    }

    /// @dev Exact-input buy. Returns the tokens received.
    function _buy(address who, address token, uint256 quoteIn) internal returns (uint256 tokensOut) {
        uint256 before = IERC20(token).balanceOf(who);
        _swap(who, token, true, -int256(quoteIn), quoteIn);
        tokensOut = IERC20(token).balanceOf(who) - before;
    }

    function _buyExactOut(address who, address token, uint256 tokensOut, uint256 maxQuote)
        internal
        returns (BalanceDelta)
    {
        return _swap(who, token, true, int256(tokensOut), maxQuote);
    }

    /// @dev Exact-input sell. Returns the quote received.
    function _sell(address who, address token, uint256 tokensIn) internal returns (uint256 quoteOut) {
        uint256 before = _quoteBalance(token, who);
        _swap(who, token, false, -int256(tokensIn), 0);
        quoteOut = _quoteBalance(token, who) - before;
    }

    function _sellExactOut(address who, address token, uint256 quoteOut) internal returns (BalanceDelta) {
        return _swap(who, token, false, int256(quoteOut), 0);
    }

    /// @dev One swap through the StealthRouter from `who` (plain approvals). `limit` is min out (exact in) or max in.
    function _routerSwap(
        address who,
        address token,
        bool buy,
        bool exactInput,
        uint256 amount,
        uint256 limit,
        uint256 value
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        PoolKey memory key = _key(token);
        vm.startPrank(who);
        if (!buy) IERC20(token).approve(address(stealthRouter), type(uint256).max);
        if (buy && !Dex.isNative(key.currency0)) {
            IERC20(Currency.unwrap(key.currency0)).approve(address(stealthRouter), type(uint256).max);
            value = 0;
        }
        (amountIn, amountOut) = stealthRouter.swap{value: value}(
            StealthRouter.Swap({
                key: key,
                zeroForOne: buy,
                exactInput: exactInput,
                amount: uint128(amount),
                limit: uint128(limit),
                recipient: who,
                usePermit2: false,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    /// @dev Buys until the price passes the graduation price.
    function _graduate(address token, address who) internal {
        if (hook.graduated(token)) return;
        StealthLocker.PoolInfo memory info = locker.getPool(token);
        (, uint256 raised,,) = locker.progress(token);
        uint256 fee = hook.currentFee(token);
        uint256 need = (info.graduationQuote - raised) * 1_000_000 / (1_000_000 - fee) * 101 / 100 + 1e6;
        _fundQuote(token, who, need);
        _buy(who, token, need);
        assertTrue(hook.graduated(token), "not graduated");
    }

    function _positionLiquidityOf(address token, bytes32 salt) internal view returns (uint128 liquidity) {
        StealthLocker.PoolInfo memory info = locker.getPool(token);
        (int24 lower, int24 upper) =
            salt == CURVE_SALT ? (info.curveTickLower, info.curveTickUpper) : (info.tailTickLower, info.curveTickLower);
        liquidity = _positionLiquidity(_poolId(token), address(locker), lower, upper, salt);
    }

    // ---------------------------------------------------------------------
    // Accounting helpers
    // ---------------------------------------------------------------------

    /// @dev Everything the vault owes for the given tokens, every role and pot.
    function _vaultOwed(address[] memory tokens) internal view returns (uint256 owed) {
        for (uint256 i; i < tokens.length; ++i) {
            owed += vault.tokenOwed(tokens[i]);
        }
    }

    /// @dev The fee vault's ERC-6909 native claim: where every native fee is held.
    function _vaultClaims() internal view returns (uint256) {
        return _dexClaimOf(address(vault), NATIVE);
    }

    function _vaultClaims(Currency currency) internal view returns (uint256) {
        return _dexClaimOf(address(vault), currency);
    }

    /// @dev Fee the hook charges on a quote amount the trader fixed: out of an exact input, on top of an exact output.
    /// @dev The coin's part of a `fee` charged at `rate` on a coin of tier `tier`, both in pips: 70% of the tier, written
    ///      out from the design and not read from the constants. Everything else of the fee is the platform's.
    function _coinPart(uint256 fee, uint24 tier, uint24 rate) internal pure returns (uint256) {
        return fee * (uint256(tier) * 7 / 10) / rate;
    }

    function _feeOnInput(uint256 gross, uint24 rate) internal pure returns (uint256) {
        return (gross * rate + 999_999) / 1_000_000;
    }

    function _feeOnTop(uint256 net, uint24 rate) internal pure returns (uint256) {
        return (net * rate + (1_000_000 - rate) - 1) / (1_000_000 - rate);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}
