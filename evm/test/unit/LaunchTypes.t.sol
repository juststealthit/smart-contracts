// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, DexBase} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockERC20} from "../utils/MockTokens.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthHook} from "../../src/StealthHook.sol";
import {LaunchType, TeamShare} from "../../src/interfaces/IStealth.sol";

/// @notice The launch types and the five tiers: the coin gets 70% of its tier, the platform wallet the rest, and the
///         coin's part goes by type (all to marketing on the Marketing type, no marketing share on any other). Also the
///         holders pot, which only the distributor pays out, with a nonce. Buyback spending is in Buyback.t.sol, the
///         general pot in FeeModel.t.sol.
contract LaunchTypesTest is BaseTest {
    uint16[5] internal tiers = [125, 225, 325, 425, 575];

    /// @dev One buy of 1 native coin after the sniper window. The fee is `taxBps` of it, to the unit.
    function _tradeFee(address token, uint16 taxBps) internal returns (uint256 fee) {
        _skipSniperWindow(token);
        uint256 c0 = _vaultClaims();
        _buy(traders[0], token, 1 ether);
        fee = _vaultClaims() - c0;
        assertEq(fee, uint256(taxBps) * 1e14, "the tier of the trade");
    }

    function _assertBooks() internal view {
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "claims == owed");
    }

    function _holders() internal returns (address token) {
        token = _launchOpts(creator, TAX, 0, _typed(LaunchType.Holders));
        _tradeFee(token, TAX);
    }

    function _payList(address a, uint256 amount) internal pure returns (address[] memory to, uint256[] memory amt) {
        to = new address[](1);
        amt = new uint256[](1);
        to[0] = a;
        amt[0] = amount;
    }

    // ---------------------------------------------------------------------
    // The split, every type at every tier
    // ---------------------------------------------------------------------

    function test_creatorType_everyTier() public {
        for (uint256 i; i < tiers.length; ++i) {
            address token = _launchOpts(creator, tiers[i], 0, _typed(LaunchType.Creator));
            _tradeFee(token, tiers[i]);
            assertEq(vault.platformOwed(token), uint256(tiers[i]) * 3e13, "platform: 30% of the tier");
            assertEq(vault.marketingOwed(token), 0, "no marketing share");
            assertEq(vault.coinOwed(token), uint256(tiers[i]) * 7e13, "creator: 70% of the tier");
            assertEq(uint8(vault.launchTypeOf(token)), uint8(LaunchType.Creator));
            assertEq(hook.getConfig(token).taxFee, uint24(tiers[i]) * 100, "the tier is locked in the hook");
            _assertBooks();
        }
    }

    function test_marketingType_everyTier() public {
        for (uint256 i; i < tiers.length; ++i) {
            address token = _launchOpts(creator, tiers[i], 0, _typed(LaunchType.Marketing));
            _tradeFee(token, tiers[i]);
            assertEq(vault.platformOwed(token), uint256(tiers[i]) * 3e13);
            assertEq(vault.marketingOwed(token), uint256(tiers[i]) * 7e13, "marketing: all of the coin's part");
            assertEq(vault.coinOwed(token), 0, "nothing else");
            assertEq(vault.claimable(token, creator), 0);
            _assertBooks();
        }
    }

    function test_potTypes_everyTier() public {
        LaunchType[3] memory types = [LaunchType.Holders, LaunchType.Buyback, LaunchType.Pot];
        for (uint256 t; t < types.length; ++t) {
            for (uint256 i; i < tiers.length; ++i) {
                address token = _launchOpts(creator, tiers[i], 0, _typed(types[t]));
                _tradeFee(token, tiers[i]);
                assertEq(vault.platformOwed(token), uint256(tiers[i]) * 3e13);
                assertEq(vault.marketingOwed(token), 0, "no marketing share");
                assertEq(vault.coinOwed(token), uint256(tiers[i]) * 7e13, "pot: 70% of the tier");
                assertEq(vault.claimable(token, creator), 0, "the pot is not the creator's");
                _assertBooks();
            }
        }
    }

    function test_teamType_everyTier() public {
        address[] memory wallets = new address[](2);
        wallets[0] = makeAddr("w0");
        wallets[1] = makeAddr("w1");
        uint16[] memory bps = new uint16[](2);
        bps[0] = 6_000;
        bps[1] = 4_000;
        for (uint256 i; i < tiers.length; ++i) {
            address token = _launchOpts(creator, tiers[i], 0, _teamOf(wallets, bps));
            _tradeFee(token, tiers[i]);
            assertEq(vault.platformOwed(token), uint256(tiers[i]) * 3e13);
            assertEq(vault.marketingOwed(token), 0);
            assertEq(vault.coinOwed(token), uint256(tiers[i]) * 7e13);
            assertEq(vault.teamAccrued(token), uint256(tiers[i]) * 7e13);
            _assertBooks();
        }
    }

    /// @notice Whatever the fee, type and tier, every unit is booked, and 70% of it is the coin's.
    function testFuzz_everyTypeEveryTier_booksEveryUnit(uint128 fee, uint8 typeSeed, uint8 tierSeed) public {
        LaunchType[5] memory types =
            [LaunchType.Creator, LaunchType.Marketing, LaunchType.Holders, LaunchType.Buyback, LaunchType.Pot];
        LaunchType t = types[typeSeed % 5];
        uint16 tier = tiers[tierSeed % 5];
        address token = _launchOpts(creator, tier, 0, _typed(t));
        uint24 rate = uint24(tier) * 100;
        vm.prank(address(hook));
        vault.credit(token, NATIVE, fee, rate);
        uint256 coin = _coinPart(fee, rate, rate);
        assertEq(vault.platformOwed(token), uint256(fee) - coin, "platform: the rest");
        assertEq(vault.marketingOwed(token) + vault.coinOwed(token), coin, "the coin's part");
        assertEq(vault.tokenOwed(token), fee, "every unit booked");
        assertEq(vault.totalOwed(NATIVE), fee);
        if (t == LaunchType.Marketing) assertEq(vault.coinOwed(token), 0);
        else assertEq(vault.marketingOwed(token), 0);
    }

    /// @notice In the sniper window the coin still gets only 70% of its tier: what the fee adds goes to the platform.
    function test_sniperFee_theExcessGoesToThePlatform() public {
        address token = _launchOpts(creator, TAX, 0, _typed(LaunchType.Creator));
        uint256 c0 = _vaultClaims();
        _buy(sniper, token, 1 ether);
        assertEq(_vaultClaims() - c0, 0.9 ether, "90% at launch");
        assertEq(vault.platformOwed(token), 0.87025 ether, "90% less the coin's 2.975%");
        assertEq(vault.marketingOwed(token), 0);
        assertEq(vault.coinOwed(token), 0.02975 ether, "70% of 4.25%");
    }

    function test_defaults_creatorTypeLowestTier() public {
        vm.prank(creator);
        address token = factory.launch(_params(0, 4 ether, 0));
        assertEq(uint8(vault.launchTypeOf(token)), uint8(LaunchType.Creator));
        assertEq(hook.getConfig(token).taxFee, 12_500, "1.25%");
        _tradeFee(token, 125);
    }

    function test_revert_taxOutsideTheTiers() public {
        uint16[6] memory bad = [1, 124, 126, 500, 574, 1000];
        for (uint256 i; i < bad.length; ++i) {
            StealthFactory.LaunchParams memory p = _params(bad[i], 4 ether, 0);
            vm.prank(creator);
            vm.expectRevert(StealthFactory.InvalidTax.selector);
            factory.launch(p);
        }
        vm.prank(address(locker));
        vm.expectRevert(StealthHook.InvalidFee.selector);
        hook.register(address(7), _reg(50_000, 1, 1));
    }

    // ---------------------------------------------------------------------
    // What each type can claim
    // ---------------------------------------------------------------------

    function test_nonCreatorTypes_nobodyClaims() public {
        LaunchType[4] memory types = [LaunchType.Marketing, LaunchType.Holders, LaunchType.Buyback, LaunchType.Pot];
        for (uint256 i; i < types.length; ++i) {
            address token = _launchOpts(creator, TAX, 0, _typed(types[i]));
            _tradeFee(token, TAX);
            (address[] memory wallets,) = vault.team(token);
            assertEq(wallets.length, 0, "no team");
            vm.prank(creator);
            vm.expectRevert(StealthFeeVault.NotCreator.selector);
            vault.claimCreator(token);
            vm.prank(creator);
            vm.expectRevert(StealthFeeVault.NotCreator.selector);
            vault.claimCreatorAmount(token, 1, creator);
            vm.prank(distributor);
            vm.expectRevert(StealthFeeVault.NotCreator.selector);
            vault.claimCreator(token);
        }
    }

    function test_sweep_leavesTheCoinsPart() public {
        address token = _holders();
        uint256 pot = vault.coinOwed(token);
        vault.sweep(_one(token));
        assertEq(vault.coinOwed(token), pot, "sweeping pays marketing and platform only");
        assertEq(marketing.balance - ACTOR_BALANCE, 0, "no marketing share on a Holders coin");
        assertEq(platform.balance - ACTOR_BALANCE, 12.75e15, "30% of 4.25%");
        _assertBooks();
    }

    // ---------------------------------------------------------------------
    // Holders pot
    // ---------------------------------------------------------------------

    function test_holdersPot_paidOnlyByTheDistributor() public {
        address token = _holders();
        assertEq(vault.coinOwed(token), 29.75e15);

        address[] memory to = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        to[0] = makeAddr("holderA");
        to[1] = makeAddr("holderB");
        to[2] = makeAddr("holderC");
        amounts[0] = 15e15;
        amounts[1] = 10e15;
        amounts[2] = 4.75e15;
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotDistributor.selector);
        vault.withdrawPot(token, to, amounts, 0);
        vm.prank(creator);
        vm.expectRevert(StealthFeeVault.NotDistributor.selector);
        vault.withdrawPot(token, to, amounts, 0);
        vm.prank(admin);
        vm.expectRevert(StealthFeeVault.NotDistributor.selector);
        vault.withdrawPot(token, to, amounts, 0);

        amounts[2] = 4.75e15 + 1;
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.AmountTooHigh.selector);
        vault.withdrawPot(token, to, amounts, 0);
        amounts[2] = 4.75e15;
        vm.prank(distributor);
        assertEq(vault.withdrawPot(token, to, amounts, 0), 29.75e15);
        assertEq(to[0].balance, 15e15);
        assertEq(to[1].balance, 10e15);
        assertEq(to[2].balance, 4.75e15);
        assertEq(vault.coinOwed(token), 0);
        assertEq(vault.potPaid(token), 29.75e15);
        _assertBooks();
    }

    function test_withdrawPot_inputChecks() public {
        address token = _holders();
        address[] memory to = new address[](1);
        uint256[] memory two = new uint256[](2);
        vm.startPrank(distributor);
        vm.expectRevert(StealthFeeVault.LengthMismatch.selector);
        vault.withdrawPot(token, to, two, 0);
        uint256[] memory one = new uint256[](1);
        one[0] = 1;
        vm.expectRevert(DexBase.ZeroAddress.selector);
        vault.withdrawPot(token, to, one, 0);
        to[0] = makeAddr("h");
        one[0] = 0;
        vm.expectRevert(StealthFeeVault.NothingToClaim.selector);
        vault.withdrawPot(token, to, one, 0);
        vm.stopPrank();
    }

    /// @notice Only Holders and Pot coins have a pot to withdraw. A Buyback pot can only be spent by `buyback`.
    function test_revert_withdrawPot_otherTypes() public {
        (address[] memory to, uint256[] memory amt) = _payList(makeAddr("h"), 1);
        LaunchType[3] memory types = [LaunchType.Creator, LaunchType.Marketing, LaunchType.Buyback];
        for (uint256 i; i < types.length; ++i) {
            address token = _launchOpts(creator, TAX, 0, _typed(types[i]));
            _tradeFee(token, TAX);
            uint256 owed = vault.coinOwed(token);
            vm.prank(distributor);
            vm.expectRevert(StealthFeeVault.WrongLaunchType.selector);
            vault.withdrawPot(token, to, amt, 0);
            assertEq(vault.coinOwed(token), owed);
        }
        address[] memory wallets = new address[](2);
        wallets[0] = makeAddr("w0");
        wallets[1] = makeAddr("w1");
        uint16[] memory bps = new uint16[](2);
        bps[0] = 5_000;
        bps[1] = 5_000;
        address teamCoin = _launchOpts(creator, TAX, 0, _teamOf(wallets, bps));
        _tradeFee(teamCoin, TAX);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.WrongLaunchType.selector);
        vault.withdrawPot(teamCoin, to, amt, 0);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.WrongLaunchType.selector);
        vault.withdrawPot(makeAddr("notAToken"), to, amt, 0);
    }

    /// @notice A payout that landed cannot run again; one that reverted can.
    function test_withdrawPot_nonce_safeToRetry() public {
        address token = _holders();
        address h = makeAddr("holder");
        (address[] memory to, uint256[] memory amt) = _payList(h, 1e15);
        assertEq(vault.potNonce(token), 0);

        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.StaleNonce.selector);
        vault.withdrawPot(token, to, amt, 1);

        vm.prank(distributor);
        vault.withdrawPot(token, to, amt, 0);
        assertEq(vault.potNonce(token), 1);
        assertEq(h.balance, 1e15);

        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.StaleNonce.selector);
        vault.withdrawPot(token, to, amt, 0);
        assertEq(h.balance, 1e15, "resending the same payout pays nothing");

        amt[0] = vault.coinOwed(token) + 1;
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.AmountTooHigh.selector);
        vault.withdrawPot(token, to, amt, 1);
        assertEq(vault.potNonce(token), 1, "a revert uses no nonce");

        amt[0] = vault.coinOwed(token);
        vm.prank(distributor);
        vault.withdrawPot(token, to, amt, 1);
        assertEq(vault.coinOwed(token), 0);
        assertEq(vault.potNonce(token), 2);
        _assertBooks();
    }

    /// @notice A pot's nonce is its own: one token's payouts do not touch another's.
    function test_withdrawPot_noncePerToken() public {
        address a = _holders();
        address b = _holders();
        (address[] memory to, uint256[] memory amt) = _payList(makeAddr("h"), 1e15);
        vm.prank(distributor);
        vault.withdrawPot(a, to, amt, 0);
        assertEq(vault.potNonce(b), 0);
        vm.prank(distributor);
        vault.withdrawPot(b, to, amt, 0);
    }

    function test_holdersPotInErc20() public {
        MockERC20 q = _listedQuote("QT", 6, 1, 1_000);
        StealthFactory.LaunchParams memory p = _paramsQ(address(q), TAX, 4e6, 0, 0);
        p.options.launchType = LaunchType.Holders;
        q.mint(creator, 1e6);
        vm.startPrank(creator);
        q.approve(address(factory), type(uint256).max);
        address token = factory.launch(p);
        vm.stopPrank();
        _skipSniperWindow(token);
        _fundQuote(token, traders[0], 10e6);
        _buy(traders[0], token, 1e6);
        assertEq(vault.coinOwed(token), 29_750, "70% of 4.25% of 1 unit");
        (address[] memory to, uint256[] memory amt) = _payList(makeAddr("holder"), 29_750);
        vm.prank(distributor);
        vault.withdrawPot(token, to, amt, 0);
        assertEq(q.balanceOf(to[0]), 29_750);
        assertEq(_vaultClaims(Currency.wrap(address(q))), vault.totalOwed(Currency.wrap(address(q))));
    }

    /// @notice A rotated distributor takes the right with it.
    function test_setDistributor_adminOnly() public {
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotAuthorized.selector);
        vault.setDistributor(attacker);
        vm.prank(admin);
        vm.expectRevert(DexBase.ZeroAddress.selector);
        vault.setDistributor(address(0));
        vm.prank(admin);
        vault.setDistributor(creator2);
        assertEq(vault.distributor(), creator2);

        address token = _holders();
        (address[] memory to, uint256[] memory amt) = _payList(makeAddr("h"), 1);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.NotDistributor.selector);
        vault.withdrawPot(token, to, amt, 0);
        vm.prank(creator2);
        vault.withdrawPot(token, to, amt, 0);
    }

    // ---------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------

    function test_revert_registerToken_onlyFactoryOnce() public {
        address token = _launchOpts(creator, TAX, 0, _typed(LaunchType.Holders));
        TeamShare[] memory none = new TeamShare[](0);
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotAuthorized.selector);
        vault.registerToken(address(7), attacker, NATIVE, LaunchType.Buyback, none, 125);
        vm.prank(address(factory));
        vm.expectRevert(StealthFeeVault.AlreadyRegistered.selector);
        vault.registerToken(token, attacker, NATIVE, LaunchType.Creator, none, 125);
        assertEq(uint8(vault.launchTypeOf(token)), uint8(LaunchType.Holders), "the type is locked");
    }
}
