// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockERC20} from "../utils/MockTokens.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {LaunchType} from "../../src/interfaces/IStealth.sol";

/// @notice The fee model: 70% of the tier to the coin, the rest to the platform wallet, in every tier, type, swap mode and
///         second of the sniper window; the Marketing type; the general pot; rounding; the packed `Coin` slot.
contract FeeModelTest is BaseTest {
    uint16[5] internal tiers = [125, 225, 325, 425, 575];

    /// @dev `_coins` in StealthFeeVault's storage layout. test_coin_slotIsWhereTheLayoutSaysItIs fails if it moves.
    uint256 internal constant COINS_SLOT = 4;
    uint256 internal constant SNIPER_SECONDS = 15;

    address internal teamA = makeAddr("teamA");
    address internal teamB = makeAddr("teamB");

    struct Books {
        uint256 claims;
        uint256 platform;
        uint256 marketing;
        uint256 coin;
    }

    function _books(address token) internal view returns (Books memory) {
        return Books(
            _vaultClaims(vault.quoteOf(token)), vault.platformOwed(token), vault.marketingOwed(token), vault.coinOwed(token)
        );
    }

    function _options(LaunchType t) internal view returns (StealthFactory.LaunchOptions memory) {
        if (t != LaunchType.Team) return _typed(t);
        address[] memory wallets = new address[](2);
        wallets[0] = teamA;
        wallets[1] = teamB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 7_000;
        bps[1] = 3_000;
        return _teamOf(wallets, bps);
    }

    function _coin(uint16 tier, LaunchType t) internal returns (address token) {
        token = _launchOpts(creator, tier, 0, _options(t));
    }

    function _pot(uint16 tier) internal returns (address token) {
        token = _coin(tier, LaunchType.Pot);
        _skipSniperWindow(token);
        _buy(traders[0], token, 1 ether);
    }

    function _pay(address to, uint256 amount) internal pure returns (address[] memory a, uint256[] memory b) {
        a = new address[](1);
        b = new uint256[](1);
        a[0] = to;
        b[0] = amount;
    }

    /// @dev Checks one trade against the rule, given the books before it and its gross quote leg.
    function _checkTrade(address token, Books memory b, uint24 tier, uint24 rate, uint256 gross, string memory label)
        internal
        view
    {
        Books memory a = _books(token);
        uint256 fee = a.claims - b.claims;
        uint256 coin = a.coin - b.coin + a.marketing - b.marketing;
        assertApproxEqAbs(fee, gross * rate / 1_000_000, 1, string.concat(label, ": the trade paid the rate"));
        assertEq(coin, _coinPart(fee, tier, rate), string.concat(label, ": the coin's part"));
        assertApproxEqAbs(coin, gross * tier * 7 / 10 / 1_000_000, 1, string.concat(label, ": 70% of the tier"));
        assertEq(a.platform - b.platform, fee - coin, string.concat(label, ": the platform takes all the rest"));
    }

    // ---------------------------------------------------------------------
    // 70 / 30
    // ---------------------------------------------------------------------

    /// @notice The numbers themselves, written out, for a 1 native trade at each tier.
    function test_7030_theTable() public {
        uint256[5] memory coin = [uint256(8.75e15), 15.75e15, 22.75e15, 29.75e15, 40.25e15];
        uint256[5] memory rest = [uint256(3.75e15), 6.75e15, 9.75e15, 12.75e15, 17.25e15];
        for (uint256 i; i < 5; ++i) {
            address token = _coin(tiers[i], LaunchType.Creator);
            _skipSniperWindow(token);
            _buy(traders[0], token, 1 ether);
            assertEq(vault.coinOwed(token), coin[i], "coin");
            assertEq(vault.platformOwed(token), rest[i], "platform");
            assertEq(vault.marketingOwed(token), 0, "marketing");
        }
    }

    function test_7030_everyTierEveryType() public {
        for (uint256 i; i < tiers.length; ++i) {
            for (uint8 t; t < 6; ++t) {
                LaunchType launchType = LaunchType(t);
                address token = _coin(tiers[i], launchType);
                _skipSniperWindow(token);
                _buy(traders[0], token, 1 ether);
                uint256 fee = uint256(tiers[i]) * 1e14;
                bool toMarketing = launchType == LaunchType.Marketing;
                assertEq(vault.platformOwed(token), fee * 3 / 10, "30% to the platform");
                assertEq(vault.coinOwed(token), toMarketing ? 0 : fee * 7 / 10, "70% to the coin");
                assertEq(vault.marketingOwed(token), toMarketing ? fee * 7 / 10 : 0, "marketing");
                assertEq(vault.tokenOwed(token), fee, "every unit booked");
                assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "claims == owed");
            }
        }
    }

    /// @notice The first buy is the launcher's own trade, in the launch: it pays the tier and splits like any other.
    function test_7030_firstBuy_everyTier() public {
        for (uint256 i; i < tiers.length; ++i) {
            uint256 c0 = _vaultClaims();
            address token = _launchOpts(creator, tiers[i], 0.01 ether, _typed(LaunchType.Creator));
            uint256 fee = _vaultClaims() - c0;
            assertEq(fee, _feeOnInput(0.01 ether, uint24(tiers[i]) * 100), "the first buy pays the tier");
            assertEq(vault.coinOwed(token), fee * 7 / 10);
            assertEq(vault.platformOwed(token), fee - fee * 7 / 10);
        }
    }

    /// @notice `taxBps = 0` means the default tier. The vault must store the tier, not the 0: a 0 would pay the coin nothing.
    function test_7030_aLaunchNamingNoTierStoresTheDefault() public {
        vm.prank(creator);
        address token = factory.launch(_params(0, TARGET, 0));
        (, uint256 word) = _coinWord(token);
        assertEq((word >> 168) & 0xffff, 125, "the vault stored the tier");
        _skipSniperWindow(token);
        _buy(traders[0], token, 1 ether);
        assertEq(vault.coinOwed(token), 8.75e15, "70% of 1.25%");
        assertEq(vault.platformOwed(token), 3.75e15);
    }

    function test_noMarketingShareOnAnyOtherType() public {
        LaunchType[5] memory types =
            [LaunchType.Creator, LaunchType.Team, LaunchType.Holders, LaunchType.Buyback, LaunchType.Pot];
        for (uint256 i; i < types.length; ++i) {
            address token = _coin(575, types[i]);
            _buy(traders[0], token, 1 ether); // in the window
            _skipSniperWindow(token);
            _buy(traders[0], token, 1 ether);
            assertEq(vault.marketingOwed(token), 0);
            uint256 before = marketing.balance;
            vault.sweep(_one(token));
            assertEq(marketing.balance, before, "a sweep pays marketing nothing");
            assertEq(vault.marketingPaid(token), 0);
        }
    }

    // ---------------------------------------------------------------------
    // Marketing type
    // ---------------------------------------------------------------------

    function test_marketingType_getsTheCoinsWholePart() public {
        for (uint256 i; i < tiers.length; ++i) {
            address token = _coin(tiers[i], LaunchType.Marketing);
            _skipSniperWindow(token);
            _buy(traders[0], token, 1 ether);
            uint256 part = uint256(tiers[i]) * 7e13;
            assertEq(vault.marketingOwed(token), part);
            assertEq(vault.coinOwed(token), 0);
            assertEq(vault.claimable(token, creator), 0);

            uint256 m0 = marketing.balance;
            uint256 p0 = platform.balance;
            vault.sweep(_one(token));
            assertEq(marketing.balance - m0, part, "paid by sweep");
            assertEq(platform.balance - p0, uint256(tiers[i]) * 3e13);
            vm.prank(creator);
            vm.expectRevert(StealthFeeVault.NotCreator.selector);
            vault.claimCreator(token);
            assertEq(vault.tokenOwed(token), 0, "nothing left");
        }
    }

    function test_marketingType_inTheSniperWindowGetsOnly70PercentOfTheTier() public {
        address token = _coin(575, LaunchType.Marketing);
        Books memory b = _books(token);
        _buy(sniper, token, 1 ether);
        _checkTrade(token, b, 57_500, 900_000, 1 ether, "marketing type");
        assertEq(vault.marketingOwed(token), 0.04025 ether);
    }

    // ---------------------------------------------------------------------
    // Sniper window
    // ---------------------------------------------------------------------

    function test_sniper_everyTierEverySecond_coinGetsOnly70PercentOfTheTier() public {
        for (uint256 i; i < tiers.length; ++i) {
            uint24 tier = uint24(tiers[i]) * 100;
            for (uint256 elapsed; elapsed < SNIPER_SECONDS; ++elapsed) {
                uint256 launched = block.timestamp;
                address token = _coin(tiers[i], LaunchType.Creator);
                vm.warp(launched + elapsed);
                uint24 rate = hook.currentFee(token);
                assertGt(rate, tier, "above the tier for all of the window");
                Books memory b = _books(token);
                _buy(sniper, token, 0.1 ether);
                _checkTrade(token, b, tier, rate, 0.1 ether, "sniper");
                vm.warp(launched + SNIPER_SECONDS);
            }
        }
    }

    /// @notice All four swap modes, at any tier, type and second of the window.
    function testFuzz_sniper_allFourModes(uint8 tierSeed, uint8 typeSeed, uint8 elapsedSeed) public {
        uint16 taxBps = tiers[tierSeed % 5];
        uint24 tier = uint24(taxBps) * 100;
        uint256 launched = block.timestamp;
        address token = _coin(taxBps, LaunchType(typeSeed % 6));
        vm.warp(launched + elapsedSeed % SNIPER_SECONDS);
        uint24 rate = hook.currentFee(token);
        address t = traders[0];

        Books memory b = _books(token);
        uint256 tokens = _buy(t, token, 1 ether);
        _checkTrade(token, b, tier, rate, 1 ether, "exact-in buy");

        b = _books(token);
        uint256 q0 = t.balance;
        _buyExactOut(t, token, tokens / 4, 10 ether);
        _checkTrade(token, b, tier, rate, q0 - t.balance, "exact-out buy");

        b = _books(token);
        q0 = t.balance;
        _sell(t, token, tokens / 4);
        _checkTrade(token, b, tier, rate, t.balance - q0 + (_vaultClaims() - b.claims), "exact-in sell");

        b = _books(token);
        q0 = t.balance;
        _sellExactOut(t, token, 0.001 ether);
        assertEq(t.balance - q0, 0.001 ether);
        _checkTrade(token, b, tier, rate, 0.001 ether + (_vaultClaims() - b.claims), "exact-out sell");
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "claims == owed");
    }

    /// @notice The rule's point: sniping earns the coin nothing more than the same trade at the tier.
    function test_sniper_earnsTheCoinNoMoreThanATradeAtTheTier() public {
        address sniped = _coin(575, LaunchType.Creator);
        _buy(sniper, sniped, 1 ether);
        address normal = _coin(575, LaunchType.Creator);
        _skipSniperWindow(normal);
        _buy(traders[0], normal, 1 ether);
        assertEq(vault.coinOwed(sniped), vault.coinOwed(normal), "the same part");
        assertEq(vault.platformOwed(sniped), 0.9 ether - 0.04025 ether, "the platform keeps the whole surplus");
    }

    /// @notice A launcher sniping their own coin through a second wallet, then selling straight back and claiming what
    ///         the coin earned: they end with less, by at least the surplus above 70% of the tier on the buy alone.
    function testFuzz_selfSnipe_losesMoney(uint8 tierSeed, uint8 teamSeed, uint8 elapsedSeed, uint96 amount) public {
        uint16 taxBps = tiers[tierSeed % 5];
        uint24 tier = uint24(taxBps) * 100;
        bool asTeam = teamSeed % 2 == 0;
        uint256 gross = bound(amount, 0.001 ether, 2 ether);
        address alt = makeAddr("creatorAlt");
        vm.deal(alt, gross);

        uint256 launched = block.timestamp;
        address token = _launchOpts(creator, taxBps, 0, _options(asTeam ? LaunchType.Team : LaunchType.Creator));
        vm.warp(launched + elapsedSeed % SNIPER_SECONDS);
        uint24 rate = hook.currentFee(token);
        assertGt(rate, tier);

        uint256 tokens = _buy(alt, token, gross);
        _sell(alt, token, tokens);
        uint256 recovered = alt.balance;
        // Whoever the launcher is, they hold at best every wallet the coin pays.
        if (asTeam) {
            vm.prank(teamA);
            recovered += vault.claimCreator(token);
            vm.prank(teamB);
            recovered += vault.claimCreator(token);
        } else {
            vm.prank(creator);
            recovered += vault.claimCreator(token);
        }
        assertLt(recovered, gross, "a self-snipe loses money");
        assertGe(gross - recovered, gross * (rate - uint256(tier) * 7 / 10) / 1_000_000 - 1, "at least the surplus");
        assertEq(vault.tokenOwed(token), vault.platformOwed(token), "only the platform's share is left");
    }

    /// @notice The closest a self-snipe comes to paying: the top tier, in the window's last second.
    function test_selfSnipe_bestCaseStillLoses() public {
        uint256 launched = block.timestamp;
        address token = _coin(575, LaunchType.Creator);
        vm.warp(launched + SNIPER_SECONDS - 1);
        uint24 rate = hook.currentFee(token);
        assertEq(rate, 900_000 - uint256(900_000 - 57_500) * 14 / 15, "the line's last step");
        assertGt(_feeOnInput(1 ether, rate), 0.04025 ether * 2, "the fee is over twice what comes back");
        _buy(creator, token, 1 ether);
        vm.prank(creator);
        assertEq(vault.claimCreator(token), 0.04025 ether, "4.025% of the trade comes back");
    }

    function test_everyRateOfTheWindowCoversTheCoinsPart() public {
        for (uint256 i; i < tiers.length; ++i) {
            uint256 launched = block.timestamp;
            address token = _coin(tiers[i], LaunchType.Creator);
            uint256 share = uint256(tiers[i]) * 70;
            for (uint256 elapsed; elapsed <= SNIPER_SECONDS + 1; ++elapsed) {
                vm.warp(launched + elapsed);
                uint24 rate = hook.currentFee(token);
                assertGe(rate, uint24(tiers[i]) * 100, "never under the tier");
                assertLt(share, rate, "so the coin's part is below the fee, and fee - coin cannot underflow");
            }
        }
    }

    // ---------------------------------------------------------------------
    // Pot
    // ---------------------------------------------------------------------

    function test_enumOrderIsFixed() public pure {
        assertEq(uint8(LaunchType.Creator), 0);
        assertEq(uint8(LaunchType.Team), 1);
        assertEq(uint8(LaunchType.Marketing), 2);
        assertEq(uint8(LaunchType.Holders), 3);
        assertEq(uint8(LaunchType.Buyback), 4);
        assertEq(uint8(LaunchType.Pot), 5);
        assertEq(uint8(StealthFeeVault.Role.Creator), 0);
        assertEq(uint8(StealthFeeVault.Role.Marketing), 1);
        assertEq(uint8(StealthFeeVault.Role.Platform), 2);
        assertEq(uint8(StealthFeeVault.Role.Legacy), 3);
        assertEq(uint8(StealthFeeVault.Role.Holders), 4);
        assertEq(uint8(StealthFeeVault.Role.Buyback), 5);
        assertEq(uint8(StealthFeeVault.Role.Team), 6);
        assertEq(uint8(StealthFeeVault.Role.Pot), 7);
    }

    function test_pot_accruesOnEveryTier() public {
        for (uint256 i; i < tiers.length; ++i) {
            address token = _pot(tiers[i]);
            assertEq(vault.coinOwed(token), uint256(tiers[i]) * 7e13);
            assertEq(vault.platformOwed(token), uint256(tiers[i]) * 3e13);
            assertEq(vault.teamAccrued(token), 0);
            assertEq(vault.claimable(token, creator), 0, "not the creator's");
        }
    }

    function test_pot_paysThroughWithdrawPotWithItsNonce() public {
        address token = _pot(TAX);
        uint256 pot = vault.coinOwed(token);
        address to = makeAddr("recipient");
        (address[] memory a, uint256[] memory b) = _pay(to, pot / 4);

        vm.expectEmit(true, true, true, true, address(vault));
        emit StealthFeeVault.Paid(token, StealthFeeVault.Role.Pot, to, pot / 4);
        vm.prank(distributor);
        assertEq(vault.withdrawPot(token, a, b, 0), pot / 4);
        assertEq(to.balance, pot / 4);
        assertEq(vault.potNonce(token), 1);
        assertEq(vault.potPaid(token), pot / 4);
        assertEq(vault.coinOwed(token), pot - pot / 4);
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "claims == owed");

        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.StaleNonce.selector);
        vault.withdrawPot(token, a, b, 0);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.StaleNonce.selector);
        vault.withdrawPot(token, a, b, 2);
        assertEq(to.balance, pot / 4, "a resend pays nothing");

        vm.prank(distributor);
        vault.withdrawPot(token, a, b, 1);
        assertEq(vault.potNonce(token), 2);
        assertEq(to.balance, pot / 2);
    }

    function test_pot_cannotPayMoreThanThePot() public {
        address token = _pot(TAX);
        address other = _pot(TAX);
        assertEq(vault.coinOwed(other), vault.coinOwed(token), "a second coin holds the same again");
        (address[] memory a, uint256[] memory b) = _pay(makeAddr("r"), vault.coinOwed(token) + 1);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.AmountTooHigh.selector);
        vault.withdrawPot(token, a, b, 0);
    }

    function test_pot_inAnErc20Quote() public {
        MockERC20 q = _listedQuote("QT", 6, 1, 1_000);
        StealthFactory.LaunchParams memory p = _paramsQ(address(q), TAX, 4e6, 0, 0);
        p.options.launchType = LaunchType.Pot;
        q.mint(creator, 1e6);
        vm.startPrank(creator);
        q.approve(address(factory), type(uint256).max);
        address token = factory.launch(p);
        vm.stopPrank();
        _skipSniperWindow(token);
        _fundQuote(token, traders[0], 10e6);
        _buy(traders[0], token, 1e6);
        assertEq(vault.coinOwed(token), 29_750);
        (address[] memory a, uint256[] memory b) = _pay(makeAddr("r"), 29_750);
        vm.prank(distributor);
        vault.withdrawPot(token, a, b, 0);
        assertEq(q.balanceOf(a[0]), 29_750);
        assertEq(_vaultClaims(Currency.wrap(address(q))), vault.totalOwed(Currency.wrap(address(q))));
    }

    function testFuzz_pot_onlyTheDistributorPays(address who) public {
        vm.assume(who != distributor);
        address token = _pot(TAX);
        (address[] memory a, uint256[] memory b) = _pay(who == address(0) ? attacker : who, 1);
        vm.prank(who);
        vm.expectRevert(StealthFeeVault.NotDistributor.selector);
        vault.withdrawPot(token, a, b, 0);
    }

    function test_pot_namedRolesCannotPay() public {
        address token = _pot(TAX);
        (address[] memory a, uint256[] memory b) = _pay(attacker, 1);
        address[6] memory roles = [creator, admin, platform, marketing, creatorManager, attacker];
        for (uint256 i; i < roles.length; ++i) {
            vm.prank(roles[i]);
            vm.expectRevert(StealthFeeVault.NotDistributor.selector);
            vault.withdrawPot(token, a, b, 0);
        }
    }

    function test_pot_aRotatedDistributorTakesTheRightWithIt() public {
        address token = _pot(TAX);
        address fresh = makeAddr("freshDistributor");
        vm.prank(admin);
        vault.setDistributor(fresh);
        (address[] memory a, uint256[] memory b) = _pay(makeAddr("r"), 1);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.NotDistributor.selector);
        vault.withdrawPot(token, a, b, 0);
        vm.prank(fresh);
        vault.withdrawPot(token, a, b, 0);
        assertEq(a[0].balance, 1);
    }

    function test_pot_cannotBeSpentByBuyback() public {
        address token = _pot(TAX);
        uint256 pot = vault.coinOwed(token);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.WrongLaunchType.selector);
        vault.buyback(token, pot, 1, block.timestamp, 0);
        assertEq(vault.coinOwed(token), pot);
        assertEq(vault.potNonce(token), 0);
    }

    function test_pot_cannotBeClaimedAsCreator() public {
        address token = _pot(TAX);
        uint256 pot = vault.coinOwed(token);
        assertEq(vault.claimable(token, creator), 0);
        vm.startPrank(creator);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreator(token);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreatorAmount(token, 1, creator);
        vm.expectRevert(StealthFeeVault.NothingToClaim.selector);
        vault.claimLegacy(token, creator);
        vm.stopPrank();

        // Nor does taking over the role bring it.
        vm.prank(creator);
        vault.offerCreator(token, handoff);
        vm.prank(handoff);
        vault.acceptCreator(token);
        vm.prank(handoff);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreator(token);

        vm.prank(creatorManager);
        vault.proposeReassign(token, attacker);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(attacker);
        vault.acceptReassign(token);
        assertEq(vault.legacyOwed(token, handoff), 0, "no legacy balance");
        assertEq(vault.legacyTotal(token), 0);
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreator(token);
        assertEq(vault.coinOwed(token), pot, "the pot did not move");
    }

    function test_pot_sweepLeavesIt() public {
        address token = _pot(TAX);
        uint256 pot = vault.coinOwed(token);
        vault.sweep(_one(token));
        assertEq(vault.coinOwed(token), pot);
        assertEq(vault.tokenOwed(token), pot);
    }

    function test_withdrawPot_keepsTheHoldersRole() public {
        address token = _coin(TAX, LaunchType.Holders);
        _skipSniperWindow(token);
        _buy(traders[0], token, 1 ether);
        address to = makeAddr("holder");
        (address[] memory a, uint256[] memory b) = _pay(to, 1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit StealthFeeVault.Paid(token, StealthFeeVault.Role.Holders, to, 1);
        vm.prank(distributor);
        vault.withdrawPot(token, a, b, 0);
    }

    // ---------------------------------------------------------------------
    // Rounding and overflow
    // ---------------------------------------------------------------------

    /// @notice `credit` at any fee, any rate the hook can charge, any tier and type: the floor of the rule, to the unit.
    function testFuzz_credit_acrossRates(uint128 fee, uint8 tierSeed, uint8 typeSeed, uint24 rateSeed) public {
        uint16 taxBps = tiers[tierSeed % 5];
        LaunchType t = LaunchType(typeSeed % 6);
        uint256 share = uint256(taxBps) * 70;
        uint24 rate = uint24(bound(rateSeed, uint256(taxBps) * 100, 900_000));
        address token = _coin(taxBps, t);

        vm.prank(address(hook));
        vault.credit(token, NATIVE, fee, rate);

        uint256 coin = vault.coinOwed(token) + vault.marketingOwed(token);
        uint256 platformPart = vault.platformOwed(token);
        assertEq(coin + platformPart, fee, "parts sum to the fee");
        assertLe(coin, fee, "the coin never exceeds the fee");
        assertLe(coin * rate, uint256(fee) * share, "rounded down: never over the rule");
        assertGt((coin + 1) * rate, uint256(fee) * share, "and by less than one unit");
        assertEq(vault.tokenOwed(token), fee);
        assertEq(vault.totalOwed(NATIVE), fee);
        if (t == LaunchType.Marketing) assertEq(vault.coinOwed(token), 0);
        else assertEq(vault.marketingOwed(token), 0);
        if (t == LaunchType.Team) assertEq(vault.teamAccrued(token), coin);
        else assertEq(vault.teamAccrued(token), 0);
    }

    function test_credit_oneUnitFeeIsThePlatforms() public {
        for (uint256 i; i < tiers.length; ++i) {
            address token = _coin(tiers[i], LaunchType.Creator);
            vm.prank(address(hook));
            vault.credit(token, NATIVE, 1, uint24(tiers[i]) * 100);
            assertEq(vault.coinOwed(token), 0, "70% of one unit rounds to nothing");
            assertEq(vault.platformOwed(token), 1);
        }
    }

    /// @notice The largest fee the hook's int128 delta can carry, at the top tier's own rate and at the bottom of the
    ///         range: `fee * share` stays far inside 256 bits, and the books take it.
    function test_credit_largestFeeDoesNotOverflow() public {
        uint256 fee = uint256(uint128(type(int128).max));
        address a = _coin(575, LaunchType.Creator);
        vm.prank(address(hook));
        vault.credit(a, NATIVE, fee, 57_500);
        assertEq(vault.coinOwed(a), fee * 7 / 10);
        assertEq(vault.platformOwed(a), fee - fee * 7 / 10);
        address b = _coin(125, LaunchType.Marketing);
        vm.prank(address(hook));
        vault.credit(b, NATIVE, fee, 900_000);
        assertEq(vault.marketingOwed(b), fee * 8_750 / 900_000);
    }

    /// @notice The hook cannot charge under the tier (test_everyRateOfTheWindowCoversTheCoinsPart). If a rate under 70% of
    ///         the tier ever reached `credit`, it would revert: no path books a coin part above the fee.
    function test_credit_aRateUnderTheShareCannotOverpay() public {
        address token = _coin(575, LaunchType.Creator);
        vm.prank(address(hook));
        vm.expectRevert();
        vault.credit(token, NATIVE, 1 ether, 40_249);
        assertEq(vault.tokenOwed(token), 0);
    }

    /// @notice Dust trades in and out of the window, then every role paid out: the vault ends with exactly nothing, so
    ///         rounding neither strands a unit nor spends one that was not collected.
    function testFuzz_rounding_payingEveryoneLeavesExactlyNothing(
        uint8 tierSeed,
        uint8 typeSeed,
        uint8 elapsedSeed,
        uint40 a,
        uint40 b
    ) public {
        uint16 taxBps = tiers[tierSeed % 5];
        LaunchType t = LaunchType(typeSeed % 6);
        uint256 launched = block.timestamp;
        address token = _coin(taxBps, t);
        vm.warp(launched + elapsedSeed % (SNIPER_SECONDS + 5));
        address trader = traders[0];
        uint256 tokens = _buy(trader, token, bound(a, 1, type(uint40).max));
        tokens += _buy(trader, token, bound(b, 1, 1e6));
        if (tokens > 1) _sell(trader, token, tokens / 2);

        Currency q = vault.quoteOf(token);
        assertEq(_vaultClaims(q), vault.tokenOwed(token), "the coin's books are the whole claim");
        vault.sweep(_one(token));

        uint256 owed = vault.coinOwed(token);
        if (owed != 0) {
            if (t == LaunchType.Creator) {
                vm.prank(creator);
                vault.claimCreator(token);
            } else if (t == LaunchType.Team) {
                uint256 share = vault.claimable(token, teamA);
                if (share != 0) {
                    vm.prank(teamA);
                    vault.claimCreator(token);
                }
                share = vault.claimable(token, teamB);
                if (share != 0) {
                    vm.prank(teamB);
                    vault.claimCreator(token);
                }
            } else if (t != LaunchType.Buyback) {
                (address[] memory to, uint256[] memory amt) = _pay(makeAddr("r"), owed);
                vm.prank(distributor);
                vault.withdrawPot(token, to, amt, 0);
            }
        }
        uint256 left = t == LaunchType.Buyback ? owed : 0;
        assertEq(_vaultClaims(q), left, "nothing left, nothing short");
        assertEq(vault.totalOwed(q), left, "and nothing owed");
    }

    // ---------------------------------------------------------------------
    // The Coin slot
    // ---------------------------------------------------------------------

    function _coinWord(address token) internal view returns (bytes32 slot, uint256 word) {
        slot = keccak256(abi.encode(token, COINS_SLOT));
        word = uint256(vm.load(address(vault), slot));
    }

    function test_coin_slotIsWhereTheLayoutSaysItIs() public {
        address token = _coin(TAX, LaunchType.Creator);
        (, uint256 word) = _coinWord(token);
        assertEq(address(uint160(word)), creator, "the mapping's slot is COINS_SLOT");
    }

    function test_coin_packsIntoOneSlot_everyTierEveryType() public {
        for (uint256 i; i < tiers.length; ++i) {
            for (uint8 t; t < 6; ++t) {
                address token = _coin(tiers[i], LaunchType(t));
                (bytes32 slot, uint256 word) = _coinWord(token);
                assertEq(address(uint160(word)), creator, "creator: bytes 0-19");
                assertEq((word >> 160) & 0xff, t, "launchType: byte 20");
                assertEq((word >> 168) & 0xffff, tiers[i], "taxBps: bytes 21-22");
                assertEq(word >> 184, 0, "the rest of the word is free");
                assertEq(vm.load(address(vault), bytes32(uint256(slot) + 1)), bytes32(0), "no second slot");
            }
        }
    }

    function test_coin_aDefaultLaunchWritesOneVaultSlot() public {
        StealthFactory.LaunchParams memory p = _params(TAX, TARGET, 0);
        vm.record();
        vm.prank(creator);
        address token = factory.launch(p);
        (, bytes32[] memory writes) = vm.accesses(address(vault));
        (bytes32 slot,) = _coinWord(token);
        for (uint256 i; i < writes.length; ++i) {
            assertEq(writes[i], slot, "the Coin slot is all a default launch writes");
        }
        assertGt(writes.length, 0);
    }

    /// @notice The creator shares the word with the tier and the type: changing it must keep both.
    function test_coin_changingTheCreatorKeepsTheTierAndType() public {
        address token = _coin(575, LaunchType.Creator);
        _skipSniperWindow(token);
        vm.prank(creator);
        vault.offerCreator(token, handoff);
        vm.prank(handoff);
        vault.acceptCreator(token);
        (, uint256 word) = _coinWord(token);
        assertEq(address(uint160(word)), handoff);
        assertEq((word >> 160) & 0xff, uint8(LaunchType.Creator));
        assertEq((word >> 168) & 0xffff, 575);

        vm.prank(creatorManager);
        vault.proposeReassign(token, attacker);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(attacker);
        vault.acceptReassign(token);
        (, word) = _coinWord(token);
        assertEq(address(uint160(word)), attacker);
        assertEq((word >> 168) & 0xffff, 575);

        _buy(traders[0], token, 1 ether);
        assertEq(vault.coinOwed(token), 0.04025 ether, "the next trade still splits by the tier");
    }

    /// @notice Tokens never move during a split: the sum of the wallets of a Team coin is the coin's part, to the unit.
    function testFuzz_team_earningsSumToTheCoinsPart(uint8 tierSeed, uint64 amount) public {
        uint16 taxBps = tiers[tierSeed % 5];
        address token = _coin(taxBps, LaunchType.Team);
        _skipSniperWindow(token);
        uint256 gross = bound(amount, 1e6, 5 ether);
        uint256 c0 = _vaultClaims();
        _buy(traders[0], token, gross);
        uint256 fee = _vaultClaims() - c0;
        uint256 part = _coinPart(fee, uint24(taxBps) * 100, uint24(taxBps) * 100);
        assertEq(vault.teamAccrued(token), part);
        assertEq(vault.claimable(token, teamA) + vault.claimable(token, teamB), part);
        assertEq(IERC20(token).balanceOf(address(vault)), 0);
    }
}
