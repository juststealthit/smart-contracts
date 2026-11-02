// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Dex, DexBase, DexCallback, IDexManager, IDexHooks, PoolKey, Currency, BalanceDelta} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockERC20} from "../utils/MockTokens.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";
import {StealthHook} from "../../src/StealthHook.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthToken} from "../../src/StealthToken.sol";
import {IStealthFeeVault, LaunchType, TeamShare} from "../../src/interfaces/IStealth.sol";
import {StealthConstants as C} from "../../src/libraries/StealthConstants.sol";
import {PoolGeometry} from "../../src/libraries/PoolGeometry.sol";
import {SwapInsideVaultUnlock} from "../review/ReviewAttempts.t.sol";

/// @notice Pretends to be the locker: everything it tries must be refused by the real hook and vault.
contract FakeLocker {
    function registerOnHook(StealthHook hook, address token, StealthHook.Registration calldata r) external {
        hook.register(token, r);
    }

    function registerOnVault(StealthFeeVault vault, address token) external {
        vault.registerToken(token, address(this), Currency.wrap(address(0)), LaunchType.Creator, new TeamShare[](0), C.TAX_TIER_1);
    }

    function credit(StealthFeeVault vault, address token, uint256 fee) external {
        vault.credit(token, Currency.wrap(address(0)), fee, 12_500);
    }
}

/// @notice An ERC-20 quote that tries to get back into the factory and locker from inside its own transfers.
contract ReentrantQuote is ERC20 {
    StealthFactory internal factory;
    bytes internal _launch;
    uint256 public tries;
    bytes public lastError;

    constructor() ERC20("Reentrant", "RQ") {}

    function arm(StealthFactory f, bytes calldata launchCall) external {
        factory = f;
        _launch = launchCall;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(factory) == address(0) || from == address(0)) return;
        tries++;
        (bool ok, bytes memory err) = address(factory).call(_launch);
        require(!ok, "re-entered the factory");
        lastError = err;
    }
}

/// @notice A team wallet that rejects the native coin, or tries to claim twice from inside a payout.
contract TeamWallet {
    StealthFeeVault internal immutable vault;
    address internal token;
    bool internal reenter;

    constructor(StealthFeeVault v) {
        vault = v;
    }

    function arm(address token_, bool reenter_) external {
        token = token_;
        reenter = reenter_;
    }

    function claim() external returns (uint256) {
        return vault.claimCreator(token);
    }

    receive() external payable {
        require(reenter, "rejects native");
        vault.claimCreator(token);
    }
}

/// @notice Attacks on what is new in Stealth: tokens as clones with their terms in code, one hook key check per build,
///         the fee vault's packed books.
contract CloneAttacksTest is BaseTest {
    function _impl() internal view returns (StealthToken) {
        return tokenDeployer.implementation();
    }

    function _locked(address who, uint256 value) internal returns (address token) {
        StealthFactory.LaunchOptions memory o;
        o.firstBuyLock = 1 days;
        token = _launchOpts(who, TAX, value, o);
    }

    // ---------------------------------------------------------------------
    // Clones
    // ---------------------------------------------------------------------

    /// @notice A token's code is EIP-1167 plus inert data: one fixed target, nothing that could point it elsewhere.
    function test_clone_codeIsPlainEip1167() public {
        address token = _launch(TAX, 4 ether);
        bytes memory code = token.code;
        bytes memory expected = abi.encodePacked(
            hex"363d3d373d3d3d363d73", address(_impl()), hex"5af43d82803e903d91602b57fd5bf3"
        );
        for (uint256 i; i < expected.length; ++i) {
            assertEq(code[i], expected[i], "proxy byte");
        }
        for (uint256 slot; slot < 8; ++slot) {
            // Nothing in the first slots can matter to the target: it is in the code. Supply is the only base slot.
            if (slot != 2) assertEq(vm.load(token, bytes32(slot)), bytes32(0), "no stray state");
        }
        // The ERC-1967 implementation slot stays empty, whatever anyone calls.
        assertEq(
            vm.load(token, bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)),
            bytes32(0),
            "not an upgradeable proxy"
        );
    }

    /// @notice There is no initializer to front-run or replay.
    function test_clone_hasNoInitializer() public {
        address token = _launch(TAX, 4 ether);
        string[5] memory sigs = [
            "initialize()",
            "initialize(address)",
            "init()",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)"
        ];
        vm.startPrank(attacker);
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = token.call(abi.encodeWithSignature(sigs[i], attacker, ""));
            assertFalse(ok, sigs[i]);
            (ok,) = address(_impl()).call(abi.encodeWithSignature(sigs[i], attacker, ""));
            assertFalse(ok, sigs[i]);
        }
        vm.stopPrank();
    }

    /// @notice Re-minting a clone: nobody but the locker, and not even the locker a second time.
    function test_clone_cannotBeReminted() public {
        address token = _launch(TAX, 4 ether);
        uint256 supply = IERC20(token).totalSupply();
        address[3] memory callers = [attacker, address(factory), address(hook)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(StealthToken.NotLocker.selector);
            StealthToken(token).mintSupply(callers[i], 1);
        }
        vm.prank(address(locker));
        vm.expectRevert(StealthToken.AlreadyMinted.selector);
        StealthToken(token).mintSupply(attacker, 1);
        assertEq(IERC20(token).totalSupply(), supply, "supply unchanged");
    }

    /// @notice The locker's own path to `mintSupply` cannot run twice for a token, and its callback only answers the DEX.
    function test_clone_lockerHasNoSecondMintPath() public {
        address token = _launch(TAX, 4 ether);
        StealthLocker.LaunchInput memory input;
        input.token = token;
        input.launcher = attacker;
        input.taxBps = TAX;
        input.target = 4 ether;
        vm.prank(address(factory));
        vm.expectRevert(StealthLocker.AlreadyLaunched.selector);
        locker.launch(input);

        address[3] memory lockers = [address(locker), address(vault), address(stealthRouter)];
        for (uint256 i; i < lockers.length; ++i) {
            vm.prank(attacker);
            vm.expectRevert(DexCallback.NotSettlement.selector);
            (bool ok,) = lockers[i].call(abi.encodeWithSelector(_dexCallbackSelector(), ""));
            ok;
        }
    }

    /// @notice The implementation is a contract like any other: nobody but the locker can touch it, and whatever
    ///         happens to its own storage never reaches a clone.
    function test_clone_implementationIsInert() public {
        address token = _launch(TAX, 4 ether);
        uint256 supply = IERC20(token).totalSupply();
        StealthToken impl = _impl();
        assertEq(impl.totalSupply(), 0, "the implementation has no supply");
        vm.startPrank(attacker);
        vm.expectRevert(StealthToken.NotLocker.selector);
        impl.mintSupply(attacker, 1);
        vm.expectRevert(StealthToken.NotLocker.selector);
        impl.setFirstBuyLock(attacker, 1);
        vm.stopPrank();

        // Even a locker that minted on the implementation would leave every clone alone.
        vm.prank(address(locker));
        impl.mintSupply(attacker, 123);
        assertEq(IERC20(token).totalSupply(), supply, "clones have their own storage");
        assertEq(IERC20(token).balanceOf(attacker), 0);
    }

    function test_clone_firstBuyLock_onlyLocker_once() public {
        address token = _locked(creator, 0.05 ether);
        uint256 amount = StealthToken(token).lockedAmount();
        assertGt(amount, 0);
        vm.prank(attacker);
        vm.expectRevert(StealthToken.NotLocker.selector);
        StealthToken(token).setFirstBuyLock(attacker, 1);
        vm.prank(address(factory));
        vm.expectRevert(StealthToken.NotLocker.selector);
        StealthToken(token).setFirstBuyLock(attacker, 1);
        vm.prank(address(locker));
        vm.expectRevert(StealthToken.LockAlreadySet.selector);
        StealthToken(token).setFirstBuyLock(attacker, 1);
        assertEq(StealthToken(token).lockedAccount(), creator);
        assertEq(StealthToken(token).lockedAmount(), amount);

        // A token with no lock: same refusal, and nothing to enable by force.
        address plain = _launch(TAX, 4 ether);
        vm.prank(attacker);
        vm.expectRevert(StealthToken.NotLocker.selector);
        StealthToken(plain).setFirstBuyLock(creator, 1);
    }

    /// @notice A length-prefixed field cannot bleed into the next one, whatever bytes it holds, at every limit.
    function test_clone_metadataFieldsCannotShift() public {
        StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
        p.name = string(_fill(C.MAX_NAME_LENGTH, 0xff));
        p.symbol = string(_fill(C.MAX_SYMBOL_LENGTH, 0x00));
        p.logo = string(_fill(C.MAX_LOGO_LENGTH, 0x02));
        p.description = string(_fill(C.MAX_DESCRIPTION_LENGTH, 0xfe));
        p.socials.twitter = string(_fill(C.MAX_SOCIAL_LENGTH, 0x01));
        p.socials.telegram = "";
        p.socials.discord = string(_fill(1, 0x00));
        p.socials.website = string(_fill(C.MAX_SOCIAL_LENGTH, 0xff));
        p.socials.farcaster = "x";
        vm.prank(creator);
        StealthToken t = StealthToken(factory.launch(p));
        assertEq(t.name(), p.name);
        assertEq(t.symbol(), p.symbol);
        assertEq(t.logo(), p.logo);
        assertEq(t.description(), p.description);
        (string memory tw, string memory tg, string memory dc, string memory web, string memory fc) = t.socials();
        assertEq(tw, p.socials.twitter);
        assertEq(tg, "");
        assertEq(dc, p.socials.discord);
        assertEq(web, p.socials.website);
        assertEq(fc, "x");
        assertEq(t.deployer(), creator);
        assertEq(t.quote(), address(0));
    }

    function _fill(uint256 length, bytes1 b) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = b;
        }
    }

    // ---------------------------------------------------------------------
    // Forged keys and fake pools
    // ---------------------------------------------------------------------

    /// @notice Each field of the key is checked, as if the pool manager really called with it: wrong fee, tick spacing,
    ///         quote and price are all refused, and so is a token nobody registered.
    function test_forgedKey_everyFieldRefused() public {
        address token = makeAddr("registeredToken");
        vm.prank(address(locker));
        hook.register(token, _reg(TAX_PIPS, 1 << 96, 1 << 95));
        address m = address(manager);
        uint160 start = 1 << 96;

        PoolKey memory good = Dex.key(NATIVE, token, address(hook), m, C.POOL_FEE, C.TICK_SPACING);
        vm.prank(m);
        assertEq(hook.beforeInitialize(address(locker), good, start), IDexHooks.beforeInitialize.selector);

        PoolKey[5] memory bad = [
            Dex.key(NATIVE, token, address(hook), m, 3000, C.TICK_SPACING), // wrong fee
            Dex.key(NATIVE, token, address(hook), m, 0x800000, C.TICK_SPACING), // dynamic fee flag
            Dex.key(NATIVE, token, address(hook), m, C.POOL_FEE, 60), // wrong tick spacing
            Dex.key(Currency.wrap(address(1)), token, address(hook), m, C.POOL_FEE, C.TICK_SPACING), // wrong quote
            Dex.key(NATIVE, makeAddr("unregistered"), address(hook), m, C.POOL_FEE, C.TICK_SPACING) // unknown token
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(m);
            vm.expectRevert(StealthHook.InvalidPool.selector);
            hook.beforeInitialize(address(locker), bad[i], start);
        }
        vm.prank(m);
        vm.expectRevert(StealthHook.InvalidPool.selector);
        hook.beforeInitialize(address(locker), good, start + 1); // wrong price
        vm.prank(m);
        vm.expectRevert(StealthHook.NotLocker.selector);
        hook.beforeInitialize(attacker, good, start); // wrong sender
    }

    /// @notice A pool once opened cannot be registered or opened again, by the locker or anyone.
    function test_forgedKey_liveTokenCannotBeReopened() public {
        address token = _launch(TAX, 4 ether);
        PoolKey memory key = _key(token);
        uint160 start = locker.getPool(token).startSqrtPriceX96;
        vm.prank(address(manager));
        vm.expectRevert(StealthHook.InvalidPool.selector);
        hook.beforeInitialize(address(locker), key, start);
        vm.prank(address(locker));
        vm.expectRevert(StealthHook.AlreadyRegistered.selector);
        hook.register(token, _reg(TAX_PIPS, start, 1));
    }

    /// @notice Through the real pool manager: an attacker can't open a pool with the Stealth hook on any settings,
    ///         for any token, a live Stealth token included.
    function test_fakePool_onRealManager_refused() public {
        address live = _launch(TAX, 4 ether);
        MockERC20 q = new MockERC20("Q", "Q", 18);
        address m = address(manager);
        (address c0, address c1) = address(q) < live ? (address(q), live) : (live, address(q));
        PoolKey[4] memory keys = [
            Dex.key(NATIVE, live, address(hook), m, 3000, C.TICK_SPACING),
            Dex.key(NATIVE, live, address(hook), m, C.POOL_FEE, 60),
            Dex.key(Currency.wrap(c0), c1, address(hook), m, C.POOL_FEE, C.TICK_SPACING),
            Dex.key(NATIVE, address(q), address(hook), m, C.POOL_FEE, C.TICK_SPACING)
        ];
        for (uint256 i; i < keys.length; ++i) {
            bytes memory err = _dexHookError(
                address(hook),
                IDexHooks.beforeInitialize.selector,
                abi.encodeWithSelector(StealthHook.NotLocker.selector)
            );
            vm.prank(attacker);
            vm.expectRevert(err);
            manager.initialize(keys[i], 1 << 96);
        }
    }

    /// @notice A fake locker gets nothing from the hook or the vault, and books stay as they were.
    function test_fakeLocker_refusedEverywhere() public {
        address token = _launch(TAX, 4 ether);
        _buy(traders[0], token, 1 ether);
        uint256 owed = vault.totalOwed(NATIVE);
        FakeLocker fake = new FakeLocker();
        vm.expectRevert(StealthHook.NotLocker.selector);
        fake.registerOnHook(hook, makeAddr("fresh"), _reg(TAX_PIPS, 1 << 96, 1 << 95));
        vm.expectRevert(StealthFeeVault.NotAuthorized.selector);
        fake.registerOnVault(vault, makeAddr("fresh"));
        vm.expectRevert(StealthFeeVault.NotAuthorized.selector);
        fake.credit(vault, token, 1 ether);
        assertEq(vault.totalOwed(NATIVE), owed, "nothing booked");
        assertEq(vault.creatorOf(makeAddr("fresh")), address(0));
    }

    /// @notice A copy of the hook is not the hook: its fee would be refused by the vault, so no pool can use a look-alike
    ///         to write into the books. On v4 it can't even be deployed at a plain address.
    function test_fakeHook_cannotCredit() public {
        if (Dex.HOOK_ADDRESS_MASK != 0) {
            vm.expectRevert();
            new StealthHook(manager, IStealthFeeVault(address(vault)));
        } else {
            StealthHook copy = new StealthHook(manager, IStealthFeeVault(address(vault)));
            assertTrue(address(copy) != address(hook));
        }
        address token = _launch(TAX, 4 ether);
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotAuthorized.selector);
        vault.credit(token, NATIVE, 1, 12_500);
    }

    /// @notice The hook only ever credits in the pool's quote; a mismatch would be refused rather than mixed.
    function test_credit_wrongCurrencyRefused() public {
        address token = _launch(TAX, 4 ether);
        MockERC20 q = _listedQuote("QT", 18, 1, 1_000);
        address paired = _launchQuote(creator, address(q), TAX, 4e18, 0);
        vm.prank(address(hook));
        vm.expectRevert(StealthFeeVault.WrongCurrency.selector);
        vault.credit(token, Currency.wrap(address(q)), 1, TAX_PIPS);
        vm.prank(address(hook));
        vm.expectRevert(StealthFeeVault.WrongCurrency.selector);
        vault.credit(paired, NATIVE, 1, TAX_PIPS);
    }

    /// @notice A registration with a rate that is not a tier is refused even from the locker.
    function test_hook_refusesRateOffTier() public {
        uint24[6] memory rates = [uint24(0), 12_499, 12_501, 50_000, 100_000, 900_000];
        for (uint256 i; i < rates.length; ++i) {
            vm.prank(address(locker));
            vm.expectRevert(StealthHook.InvalidFee.selector);
            hook.register(makeAddr("fresh"), _reg(rates[i], 1 << 96, 1 << 95));
        }
    }

    // ---------------------------------------------------------------------
    // Re-entry
    // ---------------------------------------------------------------------

    /// @notice While the vault is paying coin A's creator, that creator swaps on coin B: `credit` runs inside the
    ///         payout, on another token's books. Neither book moves by a wei more than it should.
    function test_crossPool_reentryIntoCredit_booksExact() public {
        address a = _launch(575, 4 ether);
        address b = _launch(325, 4 ether);
        _buy(traders[0], a, 2 ether);
        SwapInsideVaultUnlock c = new SwapInsideVaultUnlock(vault, manager);
        c.setup(a, _key(b));
        vm.prank(creator);
        vault.offerCreator(a, address(c));
        c.accept();

        uint256 owedA = vault.coinOwed(a);
        uint256 marketingA = vault.marketingOwed(a);
        uint256 platformA = vault.platformOwed(a);
        c.claim();
        vm.prank(claimer);
        vault.sweep(_one(a));

        assertGt(c.tokensBought(), 0, "swapped on the other pool inside the payout");
        assertEq(vault.coinOwed(a), 0, "A's creator paid in full");
        assertEq(vault.marketingOwed(a) + vault.platformOwed(a), 0, "A swept");
        assertEq(vault.marketingPaid(a), marketingA);
        assertEq(vault.platformPaid(a), platformA);
        uint256 fee = _feeOnInput(owedA / 2, 32_500);
        assertEq(vault.tokenOwed(b), fee, "B booked exactly its own trade");
        assertEq(vault.coinOwed(b), _coinPart(fee, 32_500, 32_500));
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "claims == owed");
        address[] memory both = new address[](2);
        both[0] = a;
        both[1] = b;
        assertEq(_vaultOwed(both), vault.totalOwed(NATIVE), "the sum of the books");
    }

    /// @notice A quote token that calls back into the factory from its own transfers gets the guard's refusal, on the
    ///         pull and on the refund, and the launch it sits in still comes out right.
    function test_reentrantQuote_cannotReenterTheLaunch() public {
        vm.prank(admin);
        factory.setUnlistedQuotesAllowed(true);
        _syncConfig();
        ReentrantQuote q = new ReentrantQuote();
        StealthFactory.LaunchParams memory p = _paramsQ(address(q), TAX, 4e18, 0, 0);
        uint256 probe = factory.quoteProbeAmount(address(q));
        q.mint(creator, probe);
        q.arm(factory, abi.encodeCall(StealthFactory.launch, (p)));
        vm.startPrank(creator);
        q.approve(address(factory), probe);
        address token = factory.launch(p);
        vm.stopPrank();
        assertGe(q.tries(), 2, "both transfers tried it");
        assertEq(bytes4(q.lastError()), bytes4(keccak256("ReentrancyGuardReentrantCall()")), "guard refused");
        assertEq(q.balanceOf(creator), probe, "the probe came back");
        assertEq(q.balanceOf(address(locker)), 0);
        assertGt(IERC20(token).totalSupply(), 0);
    }

    /// @notice On a Team coin one wallet that rejects the native coin hurts only itself, and a wallet that tries to
    ///         claim again from inside its payout gets nothing extra.
    function test_teamWallet_rejecting_orReentering() public {
        TeamWallet bad = new TeamWallet(vault);
        TeamWallet again = new TeamWallet(vault);
        address[] memory w = new address[](3);
        w[0] = creator;
        w[1] = address(bad);
        w[2] = address(again);
        uint16[] memory bps = new uint16[](3);
        bps[0] = 5_000;
        bps[1] = 3_000;
        bps[2] = 2_000;
        address token = _launchOpts(creator, TAX, 0, _teamOf(w, bps));
        _skipSniperWindow(token);
        bad.arm(token, false);
        again.arm(token, true);
        _buy(traders[0], token, 2 ether);

        vm.expectRevert();
        bad.claim();
        vm.expectRevert(); // the re-entry reverts, which makes the payment revert
        again.claim();
        assertEq(vault.memberPaid(token, address(again)), 0, "nothing moved");

        uint256 before = creator.balance;
        vm.prank(creator);
        uint256 got = vault.claimCreator(token);
        assertEq(creator.balance - before, got);
        assertEq(got, vault.teamAccrued(token) - vault.teamAccrued(token) * 3_000 / 10_000 - vault.teamAccrued(token) * 2_000 / 10_000);
        assertEq(vault.claimable(token, address(bad)), vault.coinOwed(token) - vault.claimable(token, address(again)));
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "claims == owed");
    }
}
