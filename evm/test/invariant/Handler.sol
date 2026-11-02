// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Dex, IDexManager, PoolKey, BalanceDelta, Currency} from "@dex/Dex.sol";
import {DexTest} from "@dex/DexTest.sol";
import {TestRouter} from "../utils/TestRouter.sol";
import {SwapQuoter} from "../utils/SwapQuoter.sol";
import {tierOf} from "../utils/Tiers.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";
import {LaunchType, TeamShare} from "../../src/interfaces/IStealth.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthHook} from "../../src/StealthHook.sol";
import {StealthToken} from "../../src/StealthToken.sol";
import {StealthRouter} from "../../src/StealthRouter.sol";

/// @notice Drives random activity across several Stealth pools of every launch type, paired with different quotes (the
///         native coin, an 18-decimal ERC-20 and a 6-decimal ERC-20): launches with first buys, all four swap shapes
///         (sniper window included), router trades, transfers, burns, donation attempts, creator and team claims
///         (whole and partial), hand-offs, takeovers (propose, cancel, accept after the notice), legacy claims, holders
///         pot payouts, buybacks (and refused buybacks), sweeps across currencies and time passing. Every swap is quoted
///         first and its fee checked against the exact formula for its mode, and every fee is split here too, from the
///         design, so the invariants can hold the vault's books against it per token and role. Every call either does
///         something valid or skips; with `fail_on_revert` on, any unexpected revert fails the run.
contract Handler is DexTest {
    uint256 internal constant MAX_TOKENS = 9;
    uint256 internal constant PIPS = 1_000_000;
    uint160 internal constant MIN_PRICE_LIMIT = Dex.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = Dex.MAX_SQRT_PRICE - 1;

    TestRouter public immutable swapRouter;
    TestRouter public immutable donateRouter;
    SwapQuoter public immutable quoter;
    StealthFactory public immutable factory;
    StealthLocker public immutable locker;
    StealthHook public immutable hook;
    StealthFeeVault public immutable vault;
    StealthRouter public immutable stealthRouter;

    address[] public actors;
    address public immutable managerA;
    address public immutable managerB = address(0xB0B);
    address[] public tokens;
    /// @notice The quotes launches pick from; index 0 is the native coin.
    Currency[] public quotes;

    // Ghosts
    mapping(address token => uint256) public supplyAtLaunch;
    mapping(address token => uint256) public burned;
    mapping(address token => uint160) public lowestPrice;
    mapping(string => uint256) public calls;
    /// @notice Every unit of fee the hook credited (vault claim increases), and every unit paid out, per currency.
    mapping(Currency => uint256) public credited;
    mapping(Currency => uint256) public paid;
    /// @notice Lifetime credits per token and role, split here from the design: the platform's part, marketing's part
    ///         and what stays with the coin (its creator, team, holders pot, buyback pot or pot).
    mapping(address token => uint256) public creditedPlatform;
    mapping(address token => uint256) public creditedMarketing;
    mapping(address token => uint256) public creditedCoin;
    /// @notice Lifetime quote spent and tokens burned by buybacks.
    mapping(address token => uint256) public buybackSpent;
    mapping(address token => uint256) public buybackBurned;
    /// @notice Swaps whose fee differed from the formula for their mode, and swaps that filled differently from
    ///         their quote. Both must stay zero.
    uint256 public feeViolations;
    uint256 public quoteMismatches;

    constructor(
        IDexManager manager_,
        address settlement_,
        TestRouter swapRouter_,
        TestRouter donateRouter_,
        SwapQuoter quoter_,
        StealthFactory factory_,
        StealthFeeVault vault_,
        StealthRouter stealthRouter_,
        address[] memory actors_,
        Currency[] memory quotes_
    ) {
        manager = manager_;
        settlementAddr = settlement_;
        swapRouter = swapRouter_;
        donateRouter = donateRouter_;
        quoter = quoter_;
        factory = factory_;
        locker = factory_.locker();
        hook = locker.hook();
        vault = vault_;
        stealthRouter = stealthRouter_;
        actors = actors_;
        quotes = quotes_;
        managerA = vault_.creatorManager();
    }

    // ---------------------------------------------------------------------
    // Views for the invariant contract
    // ---------------------------------------------------------------------

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function allTokens() external view returns (address[] memory) {
        return tokens;
    }

    function allQuotes() external view returns (Currency[] memory) {
        return quotes;
    }

    // ---------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------

    /// @dev Called from setUp as well as by the fuzzer. `quoteSeed` picks the pair currency; amounts are in whole
    ///      quote units scaled by its decimals.
    function launch(
        uint256 actorSeed,
        uint16 taxSeed,
        uint256 targetSeed,
        uint256 devSeed,
        uint256 quoteSeed,
        uint256 optSeed
    ) public {
        if (tokens.length >= MAX_TOKENS) return;
        address who = _actor(actorSeed);
        Currency q = quotes[quoteSeed % quotes.length];
        uint256 devAmount = bound(devSeed, 0, 2 * _unit(q));
        // Every third launch sends its creator fees to another actor.
        address feeTo = taxSeed % 3 == 0 ? _actor(actorSeed / 7) : address(0);
        StealthFactory.LaunchParams memory p = _launchParams(q, taxSeed, targetSeed, devAmount, feeTo);
        p.options = _options(optSeed, actorSeed);
        if (devAmount != 0 && p.minTokensOut == 0) return; // a first buy too small to buy anything
        uint256 c0 = _claims(q);
        uint256 balBefore = _bal(q, who);
        vm.prank(who);
        address token = factory.launch{value: Dex.isNative(q) ? devAmount : 0}(p);
        require(vault.creatorOf(token) == (feeTo == address(0) ? who : feeTo), "wrong creator registered");
        require(vault.quoteOf(token) == q, "wrong quote registered");
        require(balBefore - _bal(q, who) <= devAmount, "launch took more than the first buy");
        tokens.push(token);
        supplyAtLaunch[token] = IERC20(token).totalSupply();
        lowestPrice[token] = _price(token);
        _credit(token, q, _claims(q) - c0, uint24(p.taxBps) * 100);
        calls["launch"]++;
    }

    function _launchParams(Currency q, uint16 taxSeed, uint256 targetSeed, uint256 devAmount, address feeTo)
        internal
        view
        returns (StealthFactory.LaunchParams memory p)
    {
        uint256 unit = _unit(q);
        uint16 tax = tierOf(taxSeed);
        uint256 target = bound(targetSeed, 4 * unit, 10 * unit);
        (uint256 quoted,) = locker.quoteLaunchBuy(target, tax, devAmount);
        p = StealthFactory.LaunchParams({
            name: "Handler",
            symbol: "HND",
            logo: "",
            description: "",
            socials: StealthToken.Socials("", "", "", "", ""),
            taxBps: tax,
            quote: Currency.unwrap(q),
            target: target,
            quoteAmount: Dex.isNative(q) ? 0 : devAmount,
            minTokensOut: quoted,
            configVersion: factory.configVersion(),
            creator: feeTo,
            options: _none()
        });
    }

    function _none() internal pure returns (StealthFactory.LaunchOptions memory o) {}

    /// @dev A random launch type. Team launches share among 2-9 actors with random positive bps summing to 10,000.
    function _options(uint256 seed, uint256 actorSeed) internal view returns (StealthFactory.LaunchOptions memory o) {
        o.launchType = LaunchType(seed % 6);
        if (o.launchType != LaunchType.Team) return o;
        uint256 n = 2 + (seed >> 8) % (actors.length - 1);
        o.team = new TeamShare[](n);
        uint256 left = 10_000;
        for (uint256 i; i < n; ++i) {
            uint256 reserve = n - 1 - i; // at least 1 bps for each wallet still to come
            uint256 share = i == n - 1 ? left : 1 + uint256(keccak256(abi.encode(seed, i))) % (left - reserve);
            o.team[i] = TeamShare(actors[(actorSeed % actors.length + i) % actors.length], uint16(share));
            left -= share;
        }
    }

    function buy(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        if (tokens.length == 0) return;
        address who = _actor(actorSeed);
        address token = _token(tokenSeed);
        Currency q = vault.quoteOf(token);
        amount = bound(amount, 1, 5 * _unit(q));
        (bool ok, uint256 qIn, uint256 qOut) = _quote(token, true, -int256(amount));
        uint24 rate = hook.currentFee(token);
        (BalanceDelta d, uint256 fee) = _swapFee(who, token, true, -int256(amount), Dex.isNative(q) ? amount : 0);
        _check(ok, qIn, qOut, uint128(-d.amount0()), uint128(d.amount1()));
        if (fee != _up(amount * rate, PIPS)) feeViolations++;
        _trade(token, q, fee, rate, amount);
        calls["buy"]++;
    }

    function buyExactOut(uint256 actorSeed, uint256 tokenSeed, uint256 tokensOut) external {
        if (tokens.length == 0) return;
        address who = _actor(actorSeed);
        address token = _token(tokenSeed);
        Currency q = vault.quoteOf(token);
        tokensOut = bound(tokensOut, 1, IERC20(token).balanceOf(settlementAddr) / 20);
        (bool ok, uint256 quoteIn, uint256 qOut) = _quote(token, true, int256(tokensOut));
        if (!ok || quoteIn > _bal(q, who) / 2) return;
        uint24 rate = hook.currentFee(token);
        (BalanceDelta d, uint256 fee) = _swapFee(who, token, true, int256(tokensOut), Dex.isNative(q) ? quoteIn : 0);
        uint256 paidIn = uint128(-d.amount0());
        _check(ok, quoteIn, qOut, paidIn, uint128(d.amount1()));
        if (fee != _up((paidIn - fee) * rate, PIPS - rate)) feeViolations++;
        _trade(token, q, fee, rate, paidIn);
        calls["buyExactOut"]++;
    }

    function sell(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        if (tokens.length == 0) return;
        address who = _actor(actorSeed);
        address token = _token(tokenSeed);
        Currency q = vault.quoteOf(token);
        uint256 held = IERC20(token).balanceOf(who);
        if (held == 0) return;
        amount = bound(amount, 1, held);
        (bool ok, uint256 qIn, uint256 qOut) = _quote(token, false, -int256(amount));
        uint24 rate = hook.currentFee(token);
        (BalanceDelta d, uint256 fee) = _swapFee(who, token, false, -int256(amount), 0);
        uint256 got = uint128(d.amount0());
        _check(ok, qIn, qOut, uint128(-d.amount1()), got);
        if (fee != _up((got + fee) * rate, PIPS)) feeViolations++;
        _trade(token, q, fee, rate, got + fee);
        calls["sell"]++;
    }

    function sellExactOut(uint256 actorSeed, uint256 tokenSeed, uint256 quoteOut) external {
        if (tokens.length == 0) return;
        address who = _actor(actorSeed);
        address token = _token(tokenSeed);
        Currency q = vault.quoteOf(token);
        uint256 tokensIn;
        uint256 qOut;
        (quoteOut, tokensIn, qOut) = _sizeSellOut(token, who, quoteOut);
        if (quoteOut == 0) return;
        uint24 rate = hook.currentFee(token);
        (BalanceDelta d, uint256 fee) = _swapFee(who, token, false, int256(quoteOut), 0);
        _check(true, tokensIn, qOut, uint128(-d.amount1()), uint128(d.amount0()));
        if (fee != _up(quoteOut * rate, PIPS - rate)) feeViolations++;
        _trade(token, q, fee, rate, quoteOut + fee);
        calls["sellExactOut"]++;
    }

    /// @dev A quote amount half the holder's tokens could fetch, and the quote for it; quoteOut 0 means skip.
    function _sizeSellOut(address token, address who, uint256 seed)
        internal
        returns (uint256 quoteOut, uint256 tokensIn, uint256 qOut)
    {
        uint256 held = IERC20(token).balanceOf(who);
        if (held < 2) return (0, 0, 0);
        (bool okValue,, uint256 value) = _quote(token, false, -int256(held / 2));
        if (!okValue || value == 0) return (0, 0, 0);
        quoteOut = bound(seed, 1, value);
        bool ok;
        (ok, tokensIn, qOut) = _quote(token, false, int256(quoteOut));
        if (!ok || tokensIn > held) return (0, 0, 0);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 tokenSeed, uint256 amount) external {
        if (tokens.length == 0) return;
        address from = _actor(fromSeed);
        address token = _token(tokenSeed);
        uint256 held = IERC20(token).balanceOf(from);
        if (held == 0) return;
        vm.prank(from);
        IERC20(token).transfer(_actor(toSeed), bound(amount, 1, held));
        calls["transfer"]++;
    }

    function burn(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        if (tokens.length == 0) return;
        address who = _actor(actorSeed);
        address token = _token(tokenSeed);
        uint256 held = IERC20(token).balanceOf(who);
        if (held == 0) return;
        amount = bound(amount, 1, held / 10 + 1);
        vm.prank(who);
        StealthToken(token).burn(amount);
        burned[token] += amount;
        calls["burn"]++;
    }

    /// @dev Donations are refused by the hook; the attempt must change nothing.
    function donate(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        if (tokens.length == 0) return;
        address who = _actor(actorSeed);
        address token = _token(tokenSeed);
        Currency q = vault.quoteOf(token);
        PoolKey memory key = locker.poolKey(token);
        amount = bound(amount, 1, _unit(q) / 10);
        vm.prank(who);
        try donateRouter.donate{value: Dex.isNative(q) ? amount : 0}(key, amount, 0, "") {
            revert("a donation went through");
        } catch {}
        calls["donateRefused"]++;
    }

    /// @dev The creator of a Creator coin or a team wallet claims its whole balance.
    function claimCreator(uint256 tokenSeed, uint256 actorSeed) external {
        if (tokens.length == 0) return;
        address token = _token(tokenSeed);
        address who = actorSeed % 2 == 0 ? vault.creatorOf(token) : _actor(actorSeed);
        uint256 owed = vault.claimable(token, who);
        if (owed == 0) return;
        _claimAndCheck(token, who, owed, false);
        calls["claimCreator"]++;
    }

    function claimCreatorPart(uint256 tokenSeed, uint256 actorSeed, uint256 amountSeed) external {
        if (tokens.length == 0) return;
        address token = _token(tokenSeed);
        address who = actorSeed % 2 == 0 ? vault.creatorOf(token) : _actor(actorSeed);
        uint256 owed = vault.claimable(token, who);
        if (owed == 0) return;
        _claimAndCheck(token, who, bound(amountSeed, 1, owed), true);
        calls["claimCreatorPart"]++;
    }

    /// @dev A claim pays the claimer and moves nothing else, in its quote.
    function _claimAndCheck(address token, address to, uint256 amount, bool part) internal {
        Currency q = vault.quoteOf(token);
        uint256 m = vault.marketingOwed(token);
        uint256 p = vault.platformOwed(token);
        uint256 owedBefore = vault.coinOwed(token);
        address mkt = vault.marketing();
        address tre = vault.platform();
        uint256 cb = _bal(q, to);
        uint256 mb = _bal(q, mkt);
        uint256 tb = _bal(q, tre);
        vm.prank(to);
        if (part) vault.claimCreatorAmount(token, amount, to);
        else vault.claimCreator(token);
        require(_bal(q, to) - cb == amount, "creator paid the wrong amount");
        require(_bal(q, mkt) == mb && _bal(q, tre) == tb, "a claim paid someone else");
        require(vault.coinOwed(token) == owedBefore - amount, "creator owed wrong after claim");
        require(vault.marketingOwed(token) == m && vault.platformOwed(token) == p, "a claim moved other shares");
        paid[q] += amount;
    }

    /// @dev The creator manager proposes another actor as a token's creator.
    function proposeReassign(uint256 tokenSeed, uint256 toSeed) external {
        if (tokens.length == 0) return;
        address token = _token(tokenSeed);
        address to = _actor(toSeed);
        if (to == vault.creatorOf(token)) return;
        vm.prank(vault.creatorManager());
        vault.proposeReassign(token, to);
        (address pTo, uint64 eta,) = vault.reassignment(token);
        require(pTo == to && eta == block.timestamp + vault.reassignNotice(), "proposal not stored");
        calls["proposeReassign"]++;
    }

    /// @dev The admin or the creator manager cancels an open proposal.
    function cancelReassign(uint256 tokenSeed, bool byAdmin) external {
        if (tokens.length == 0) return;
        address token = _token(tokenSeed);
        (address to,,) = vault.reassignment(token);
        if (to == address(0)) return;
        vm.prank(byAdmin ? factory.admin() : vault.creatorManager());
        vault.cancelReassign(token);
        calls["cancelReassign"]++;
    }

    /// @dev The proposed creator accepts: waits out the notice if needed; an expired proposal is refused and
    ///      cancelled. The old creator's unclaimed share must move to its legacy balance, to the unit.
    function acceptReassign(uint256 tokenSeed) external {
        if (tokens.length == 0) return;
        address token = _token(tokenSeed);
        (address to, uint64 eta, uint32 epoch) = vault.reassignment(token);
        if (to == address(0)) return;
        if (epoch != vault.managerEpoch()) {
            vm.prank(to);
            vm.expectRevert(StealthFeeVault.StaleReassign.selector);
            vault.acceptReassign(token);
            vm.prank(factory.admin());
            vault.cancelReassign(token);
            calls["staleReassign"]++;
            return;
        }
        if (block.timestamp > uint256(eta) + vault.REASSIGN_WINDOW()) {
            vm.prank(to);
            vm.expectRevert(StealthFeeVault.ReassignExpired.selector);
            vault.acceptReassign(token);
            vm.prank(factory.admin());
            vault.cancelReassign(token);
            calls["expiredReassign"]++;
            return;
        }
        if (block.timestamp < eta) {
            vm.prank(to);
            vm.expectRevert(StealthFeeVault.NoticeRunning.selector);
            vault.acceptReassign(token);
            vm.warp(eta);
            vm.roll(block.number + 1);
        }
        address from = vault.creatorOf(token);
        // Only the Creator type pays the role: on a Team coin the wallets and their balances are untouched.
        bool paysRole = vault.launchTypeOf(token) == LaunchType.Creator;
        uint256 backlog = paysRole ? vault.coinOwed(token) : 0;
        uint256 teamBefore = vault.coinOwed(token);
        uint256 legacyBefore = vault.legacyOwed(token, from);
        vm.prank(to);
        vault.acceptReassign(token);
        require(vault.creatorOf(token) == to, "creator not replaced");
        if (paysRole) require(vault.claimable(token, from) == 0, "backlog left with the old creator");
        require(vault.coinOwed(token) == teamBefore - backlog, "coin owed wrong after takeover");
        require(vault.legacyOwed(token, from) == legacyBefore + backlog, "backlog not kept for the old creator");
        (address left,,) = vault.reassignment(token);
        require(left == address(0), "proposal not cleared");
        calls["acceptReassign"]++;
    }

    /// @dev The admin rotates the creator manager among two wallets: every open proposal becomes void.
    function rotateManager() external {
        address next = vault.creatorManager() == managerA ? managerB : managerA;
        uint32 e = vault.managerEpoch();
        vm.prank(factory.admin());
        vault.setCreatorManager(next);
        require(vault.managerEpoch() == e + 1 && vault.creatorManager() == next, "rotation not applied");
        calls["rotateManager"]++;
    }

    /// @dev The current creator hands off voluntarily to the wallet an open proposal names: the proposal settles.
    function handoffToProposed(uint256 tokenSeed) external {
        if (tokens.length == 0) return;
        address token = _token(tokenSeed);
        (address to,,) = vault.reassignment(token);
        if (to == address(0)) return;
        address from = vault.creatorOf(token);
        uint256 owed = vault.coinOwed(token);
        vm.prank(from);
        vault.offerCreator(token, to);
        vm.prank(to);
        vault.acceptCreator(token);
        (address left,,) = vault.reassignment(token);
        require(left == address(0), "settled proposal not cleared");
        require(vault.creatorOf(token) == to && vault.coinOwed(token) == owed, "hand-off moved the wrong amount");
        calls["handoffToProposed"]++;
    }

    /// @dev An actor with a legacy balance on a token claims it.
    function claimLegacy(uint256 tokenSeed, uint256 actorSeed) external {
        if (tokens.length == 0) return;
        address token = _tokenWithLegacy(tokenSeed);
        address who = _actor(actorSeed);
        uint256 owed = vault.legacyOwed(token, who);
        // Few actors hold a legacy balance: take the next one that does.
        for (uint256 i; i < actors.length && owed == 0; ++i) {
            who = actors[i];
            owed = vault.legacyOwed(token, who);
        }
        if (owed == 0) return;
        Currency q = vault.quoteOf(token);
        uint256 before = _bal(q, who);
        vm.prank(who);
        vault.claimLegacy(token, who);
        require(_bal(q, who) - before == owed, "legacy paid the wrong amount");
        paid[q] += owed;
        calls["claimLegacy"]++;
    }

    function handoff(uint256 tokenSeed, uint256 toSeed) external {
        if (tokens.length == 0) return;
        address token = _token(tokenSeed);
        address from = vault.creatorOf(token);
        address to = _actor(toSeed);
        if (to == from) return;
        vm.prank(from);
        vault.offerCreator(token, to);
        vm.prank(to);
        vault.acceptCreator(token);
        calls["handoff"]++;
    }

    /// @dev Anyone sweeps any subset of tokens (mixed quotes, duplicates and unknown addresses included). Each
    ///      currency's payouts must match what was owed in it.
    function sweep(uint256 actorSeed, uint256 mask) external {
        if (tokens.length == 0) return;
        address[] memory list = new address[](tokens.length + 2);
        uint256 n;
        for (uint256 i; i < tokens.length; ++i) {
            if ((mask >> i) & 1 == 1) list[n++] = tokens[i];
        }
        list[n++] = tokens[mask % tokens.length]; // maybe a duplicate
        list[n++] = address(uint160(mask) | 1); // not a token
        assembly ("memory-safe") {
            mstore(list, n)
        }
        uint256[] memory expectM = new uint256[](quotes.length);
        uint256[] memory expectP = new uint256[](quotes.length);
        uint256[] memory mb = new uint256[](quotes.length);
        uint256[] memory tb = new uint256[](quotes.length);
        for (uint256 j; j < quotes.length; ++j) {
            mb[j] = _bal(quotes[j], vault.marketing());
            tb[j] = _bal(quotes[j], vault.platform());
        }
        for (uint256 i; i < tokens.length; ++i) {
            bool listed;
            for (uint256 k; k < n; ++k) {
                if (list[k] == tokens[i]) listed = true;
            }
            if (!listed) continue;
            uint256 j = _quoteIndex(vault.quoteOf(tokens[i]));
            expectM[j] += vault.marketingOwed(tokens[i]);
            expectP[j] += vault.platformOwed(tokens[i]);
        }
        vm.prank(_actor(actorSeed));
        (uint256 m, uint256 p) = vault.sweep(list);
        uint256 sumM;
        uint256 sumP;
        for (uint256 j; j < quotes.length; ++j) {
            require(_bal(quotes[j], vault.marketing()) - mb[j] == expectM[j], "sweep paid marketing wrong");
            require(_bal(quotes[j], vault.platform()) - tb[j] == expectP[j], "sweep paid platform wrong");
            paid[quotes[j]] += expectM[j] + expectP[j];
            sumM += expectM[j];
            sumP += expectP[j];
        }
        require(m == sumM && p == sumP, "sweep returned wrong totals");
        calls["sweep"]++;
    }

    // ---------------------------------------------------------------------
    // Router trades, pots, buybacks
    // ---------------------------------------------------------------------

    /// @dev An exact-input buy or sell through the StealthRouter: the fee is the formula.
    function routerTrade(uint256 actorSeed, uint256 tokenSeed, uint256 amount, bool isBuy) external {
        if (tokens.length == 0) return;
        address who = _actor(actorSeed);
        address token = _token(tokenSeed);
        if (isBuy) {
            amount = bound(amount, 1, 2 * _unit(vault.quoteOf(token)));
        } else {
            uint256 held = IERC20(token).balanceOf(who);
            if (held == 0) return;
            amount = bound(amount, 1, held);
        }
        (bool ok,, uint256 qOut) = _quote(token, isBuy, -int256(amount));
        if (!ok) return;
        Currency q = vault.quoteOf(token);
        uint24 rate = hook.currentFee(token);
        uint256 c0 = _claims(q);
        uint256 got = _doRouterSwap(who, token, isBuy, amount);
        if (got != qOut) quoteMismatches++;
        uint256 fee = _claims(q) - c0;
        uint256 gross = isBuy ? amount : got + fee;
        if (fee != _up(gross * rate, PIPS)) feeViolations++;
        _trade(token, q, fee, rate, gross);
        calls["routerTrade"]++;
    }

    function _doRouterSwap(address who, address token, bool isBuy, uint256 amount) internal returns (uint256 got) {
        PoolKey memory key = locker.poolKey(token);
        uint256 value = isBuy && Dex.isNative(key.currency0) ? amount : 0;
        vm.startPrank(who);
        if (!isBuy) IERC20(token).approve(address(stealthRouter), amount);
        (uint256 paidIn, uint256 out) = stealthRouter.swap{value: value}(
            StealthRouter.Swap(key, isBuy, true, uint128(amount), 0, who, false, block.timestamp)
        );
        vm.stopPrank();
        if (paidIn != amount) quoteMismatches++;
        got = out;
    }

    /// @dev The distributor pays part of a Holders or Pot coin's pot to one or two actors. Resending the same call is refused.
    function withdrawPot(uint256 tokenSeed, uint256 amountSeed, uint256 toSeed) external {
        if (tokens.length == 0) return;
        address token = _token(tokenSeed);
        LaunchType launchType = vault.launchTypeOf(token);
        if (launchType != LaunchType.Holders && launchType != LaunchType.Pot) return;
        uint256 owed = vault.coinOwed(token);
        if (owed == 0) return;
        Currency q = vault.quoteOf(token);
        uint256 next = toSeed % actors.length + 1;
        bool two = owed >= 2 && toSeed % 2 == 0;
        address[] memory to = new address[](two ? 2 : 1);
        uint256[] memory amt = new uint256[](two ? 2 : 1);
        to[0] = _actor(toSeed);
        amt[0] = bound(amountSeed, 1, two ? owed - 1 : owed);
        if (two) {
            to[1] = _actor(next);
            amt[1] = owed - amt[0];
        }
        uint256 total = amt[0] + (two ? amt[1] : 0);
        uint256 b0 = _bal(q, to[0]);
        uint256 nonce = vault.potNonce(token);
        vm.prank(vault.distributor());
        vault.withdrawPot(token, to, amt, nonce);
        require(_bal(q, to[0]) - b0 == amt[0], "pot paid wrong");
        require(vault.potNonce(token) == nonce + 1, "nonce did not move");
        vm.prank(vault.distributor());
        vm.expectRevert(StealthFeeVault.StaleNonce.selector);
        vault.withdrawPot(token, to, amt, nonce);
        paid[q] += total;
        calls["withdrawPot"]++;
    }

    /// @dev The distributor spends part of a Buyback coin's pot, at exactly the quote it just saw: the pot falls by the
    ///      spend less the coin's part of the buy's own tax, and the supply falls by exactly the tokens bought.
    function buyback(uint256 tokenSeed, uint256 amountSeed) external {
        if (tokens.length == 0) return;
        address token = _token(tokenSeed);
        if (vault.launchTypeOf(token) != LaunchType.Buyback || block.timestamp < hook.sniperWindowEnd(token)) return;
        uint256 pot = vault.coinOwed(token);
        if (pot == 0) return;
        uint256 amount = bound(amountSeed, 1, pot);
        (bool ok,, uint256 out) = _quote(token, true, -int256(amount));
        if (!ok || out == 0) return;
        Currency q = vault.quoteOf(token);
        uint24 rate = hook.currentFee(token);
        uint256 c0 = _claims(q);
        uint256 supply = IERC20(token).totalSupply();
        uint256 poolTokens = IERC20(token).balanceOf(settlementAddr);
        uint256 nonce = vault.potNonce(token);
        vm.prank(vault.distributor());
        uint256 got = vault.buyback(token, amount, out, block.timestamp, nonce);
        require(got == out, "bought differently from the quote");
        require(IERC20(token).totalSupply() == supply - got, "supply did not fall by the tokens bought");
        require(poolTokens - IERC20(token).balanceOf(settlementAddr) == got, "tokens did not come from the pool");
        uint256 fee = _claims(q) + amount - c0;
        if (fee != _up(amount * rate, PIPS)) feeViolations++;
        // A retry of the same call, landed or not, must not spend twice.
        vm.prank(vault.distributor());
        vm.expectRevert(StealthFeeVault.StaleNonce.selector);
        vault.buyback(token, amount, out, block.timestamp, nonce);
        burned[token] += got;
        buybackSpent[token] += amount;
        buybackBurned[token] += got;
        paid[q] += amount;
        _trade(token, q, fee, rate, amount);
        calls["buyback"]++;
    }

    /// @dev Buybacks that must be refused and change nothing: over the pot, too high a minimum, zero minimum, a past
    ///      deadline, a wrong nonce, a stranger, or the wrong launch type.
    function buybackRefused(uint256 tokenSeed, uint256 kind, uint256 strangerSeed) external {
        if (tokens.length == 0) return;
        address token = _token(tokenSeed);
        uint256 pot = vault.coinOwed(token);
        bool isBuyback = vault.launchTypeOf(token) == LaunchType.Buyback;
        address d = vault.distributor();
        uint256 nonce = vault.potNonce(token);
        uint256 c0 = _claims(vault.quoteOf(token));
        if (!isBuyback) {
            vm.prank(d);
            vm.expectRevert(StealthFeeVault.WrongLaunchType.selector);
            vault.buyback(token, 1, 1, block.timestamp, nonce);
        } else if (kind % 5 == 0) {
            vm.prank(_actor(strangerSeed));
            vm.expectRevert(StealthFeeVault.NotDistributor.selector);
            vault.buyback(token, 1, 1, block.timestamp, nonce);
        } else if (kind % 5 == 1) {
            vm.prank(d);
            vm.expectRevert(StealthFeeVault.StaleNonce.selector);
            vault.buyback(token, 1, 1, block.timestamp, nonce + 1);
        } else if (kind % 5 == 2) {
            vm.prank(d);
            vm.expectRevert(StealthFeeVault.ZeroAmount.selector);
            vault.buyback(token, 1, 0, block.timestamp, nonce);
        } else if (kind % 5 == 3) {
            vm.warp(block.timestamp + 1);
            vm.prank(d);
            vm.expectRevert(StealthFeeVault.Expired.selector);
            vault.buyback(token, 1, 1, block.timestamp - 1, nonce);
        } else if (block.timestamp >= hook.sniperWindowEnd(token)) {
            vm.prank(d);
            vm.expectRevert(StealthFeeVault.AmountTooHigh.selector);
            vault.buyback(token, pot + 1, 1, block.timestamp, nonce);
            if (pot != 0) {
                (bool ok,, uint256 out) = _quote(token, true, -int256(pot));
                if (ok) {
                    vm.prank(d);
                    vm.expectRevert(StealthFeeVault.Slippage.selector);
                    vault.buyback(token, pot, out + 1, block.timestamp, nonce);
                }
            }
        } else {
            vm.prank(d);
            vm.expectRevert(StealthFeeVault.SniperWindowOpen.selector);
            vault.buyback(token, 1, 1, block.timestamp, nonce);
        }
        require(vault.coinOwed(token) == pot && vault.potNonce(token) == nonce, "a refused buyback changed the pot");
        require(_claims(vault.quoteOf(token)) == c0, "a refused buyback moved claims");
        calls["buybackRefused"]++;
    }

    /// @dev A second or two at a time: stays inside the sniper window of a fresh launch.
    function warpShort(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 3));
        vm.roll(block.number + 1);
        calls["warpShort"]++;
    }

    /// @dev Occasionally jumps hours to days ahead, so takeover notices run out and proposals expire.
    function warpLong(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 10 days));
        vm.roll(block.number + 1);
        calls["warpLong"]++;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 90));
        vm.roll(block.number + 1);
        calls["warp"]++;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev One router swap from `who`; returns the trader's delta and the fee credited (the vault's claim increase).
    function _swapFee(address who, address token, bool zeroForOne, int256 amountSpecified, uint256 value)
        internal
        returns (BalanceDelta d, uint256 fee)
    {
        Currency q = vault.quoteOf(token);
        PoolKey memory key = locker.poolKey(token); // before the prank: an external call would consume it
        uint256 c0 = _claims(q);
        vm.startPrank(who);
        if (!zeroForOne) IERC20(token).approve(address(swapRouter), type(uint256).max);
        d = swapRouter.swap{value: value}(key, _params(zeroForOne, amountSpecified), _settings(), "");
        vm.stopPrank();
        fee = _claims(q) - c0;
    }

    /// @dev The token at `seed`, or the next one with any legacy balance.
    function _tokenWithLegacy(uint256 seed) internal view returns (address) {
        for (uint256 i; i < tokens.length; ++i) {
            address t = tokens[(seed % tokens.length + i) % tokens.length];
            if (vault.legacyTotal(t) != 0) return t;
        }
        return _token(seed);
    }

    function _unit(Currency q) internal view returns (uint256) {
        if (Dex.isNative(q)) return 1 ether;
        (bool ok, bytes memory ret) = Currency.unwrap(q).staticcall(abi.encodeWithSignature("decimals()"));
        require(ok, "decimals");
        return 10 ** abi.decode(ret, (uint8));
    }

    function _quoteIndex(Currency q) internal view returns (uint256) {
        for (uint256 j; j < quotes.length; ++j) {
            if (quotes[j] == q) return j;
        }
        revert("unknown quote");
    }

    function _bal(Currency q, address who) internal view returns (uint256) {
        return Dex.isNative(q) ? who.balance : IERC20(Currency.unwrap(q)).balanceOf(who);
    }

    function _claims(Currency q) internal view returns (uint256) {
        return _dexClaimOf(address(vault), q);
    }

    /// @dev Books a fee as the design splits it: 70% of the coin's tier is the coin's (marketing's on the Marketing type,
    ///      nobody else's share), the rest of the fee the platform's.
    function _credit(address token, Currency q, uint256 fee, uint24 rate) internal {
        credited[q] += fee;
        uint256 coin = fee * _coinShare(token) / rate;
        uint256 mkt = vault.launchTypeOf(token) == LaunchType.Marketing ? coin : 0;
        creditedPlatform[token] += fee - coin;
        creditedMarketing[token] += mkt;
        creditedCoin[token] += coin - mkt;
    }

    /// @dev 70% of the coin's tier, in pips, from the design.
    function _coinShare(address token) internal view returns (uint256) {
        return uint256(hook.getConfig(token).taxFee) * 7 / 10;
    }

    /// @dev After a swap with gross quote leg `gross`: the coin's part is 70% of its tier on that leg, to within one
    ///      unit, at any rate.
    function _trade(address token, Currency q, uint256 fee, uint24 rate, uint256 gross) internal {
        uint256 coin = fee * _coinShare(token) / rate;
        uint256 exact = gross * _coinShare(token) / PIPS;
        if ((coin > exact ? coin - exact : exact - coin) > 1) feeViolations++;
        if (rate > hook.getConfig(token).taxFee) calls["sniperTrade"]++;
        _credit(token, q, fee, rate);
        _after(token);
    }

    function _up(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    function _check(bool ok, uint256 qIn, uint256 qOut, uint256 actualIn, uint256 actualOut) internal {
        if (!ok || qIn != actualIn || qOut != actualOut) quoteMismatches++;
    }

    function _after(address token) internal {
        uint160 p = _price(token);
        if (p < lowestPrice[token]) lowestPrice[token] = p;
    }

    function _price(address token) internal view returns (uint160 p) {
        (p,,,) = _getSlot0(Dex.id(locker.poolKey(token)));
    }

    function _quote(address token, bool zeroForOne, int256 amountSpecified)
        internal
        returns (bool, uint256 amountIn, uint256 amountOut)
    {
        if (amountSpecified > int256(type(int128).max) || amountSpecified < -int256(type(int128).max)) {
            return (false, 0, 0);
        }
        try quoter.quote(locker.poolKey(token), _params(zeroForOne, amountSpecified)) returns (uint256 i, uint256 o) {
            return (true, i, o);
        } catch {
            return (false, 0, 0);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _token(uint256 seed) internal view returns (address) {
        return tokens[seed % tokens.length];
    }

    function _params(bool zeroForOne, int256 amountSpecified)
        internal
        pure
        returns (IDexManager.SwapParams memory)
    {
        return IDexManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
    }

    function _settings() internal pure returns (TestRouter.TestSettings memory) {
        return TestRouter.TestSettings({takeClaims: false, settleUsingBurn: false});
    }
}
