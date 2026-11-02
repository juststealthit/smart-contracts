// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, DexBase} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockERC20} from "../utils/MockTokens.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {LaunchType, TeamShare} from "../../src/interfaces/IStealth.sol";

/// @dev A team wallet with no way to receive the native coin, which can still send its balance elsewhere.
contract RejectingWallet {
    function claim(StealthFeeVault vault, address token) external returns (uint256) {
        return vault.claimCreator(token);
    }

    function claimTo(StealthFeeVault vault, address token, uint256 amount, address to) external {
        vault.claimCreatorAmount(token, amount, to);
    }
}

/// @dev A team wallet that tries to claim again while being paid.
contract ReentrantWallet {
    StealthFeeVault internal immutable vault;
    address internal token;

    constructor(StealthFeeVault vault_) {
        vault = vault_;
    }

    function claim(address token_) external returns (uint256) {
        token = token_;
        return vault.claimCreator(token_);
    }

    receive() external payable {
        vault.claimCreator(token);
    }
}

/// @notice Team launches: 2-10 wallets by bps, fixed at launch. A wallet's earnings follow from the team's lifetime
///         total, so what one wallet does never moves another's, and swaps never loop over wallets.
contract TeamTest is BaseTest {
    event TeamSet(address indexed token, address[] wallets, uint16[] bps);
    event Paid(address indexed token, StealthFeeVault.Role indexed role, address indexed to, uint256 amount);

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function _two(address a, address b, uint16 aBps, uint16 bBps)
        internal
        pure
        returns (address[] memory w, uint16[] memory bps)
    {
        w = new address[](2);
        bps = new uint16[](2);
        (w[0], w[1], bps[0], bps[1]) = (a, b, aBps, bBps);
    }

    function _three(uint16 aBps, uint16 bBps, uint16 cBps)
        internal
        view
        returns (address[] memory w, uint16[] memory bps)
    {
        w = new address[](3);
        bps = new uint16[](3);
        (w[0], w[1], w[2], bps[0], bps[1], bps[2]) = (alice, bob, carol, aBps, bBps, cBps);
    }

    function _launchTeam(address[] memory w, uint16[] memory bps) internal returns (address token) {
        token = _launchOpts(creator, TAX, 0, _teamOf(w, bps));
        _skipSniperWindow(token);
    }

    function _wallets(uint256 n) internal returns (address[] memory w, uint16[] memory bps) {
        w = new address[](n);
        bps = new uint16[](n);
        uint256 left = 10_000;
        for (uint256 i; i < n; ++i) {
            w[i] = makeAddr(string.concat("wallet", vm.toString(i)));
            bps[i] = uint16(i == n - 1 ? left : 10_000 / n);
            left -= bps[i];
        }
    }

    function _revertsLaunch(StealthFactory.LaunchOptions memory o, bytes4 err) internal {
        StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
        p.options = o;
        vm.prank(creator);
        vm.expectRevert(err);
        factory.launch(p);
    }

    /// @dev One buy of 1 native coin at 4.25%: 0.02975 to the team.
    function _trade(address token) internal {
        _buy(traders[0], token, 1 ether);
    }

    function _assertBooks(address token) internal view {
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "claims == owed");
        assertEq(vault.tokenOwed(token), vault.totalOwed(NATIVE), "the only token here");
    }

    // ---------------------------------------------------------------------
    // Launch
    // ---------------------------------------------------------------------

    function test_team_isStoredAndEmitted() public {
        (address[] memory w, uint16[] memory bps) = _three(5_000, 3_000, 2_000);
        StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
        p.options = _teamOf(w, bps);
        address predicted = factory.predictTokenAddress(creator, p);
        vm.expectEmit(true, false, false, true, address(vault));
        emit TeamSet(predicted, w, bps);
        vm.prank(creator);
        address token = factory.launch(p);
        (address[] memory wallets, uint16[] memory split) = vault.team(token);
        assertEq(wallets, w);
        assertEq(split.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(split[i], bps[i]);
        }
        assertEq(uint8(vault.launchTypeOf(token)), uint8(LaunchType.Team));
        assertEq(vault.creatorOf(token), creator, "the creator is attribution here");
    }

    function test_teamSizes_twoToTen() public {
        for (uint256 n = 2; n <= 10; ++n) {
            (address[] memory w, uint16[] memory bps) = _wallets(n);
            address token = _launchTeam(w, bps);
            _trade(token);
            (address[] memory wallets,) = vault.team(token);
            assertEq(wallets.length, n);
            uint256 sum;
            for (uint256 i; i < n; ++i) {
                sum += vault.claimable(token, w[i]);
            }
            assertEq(sum, vault.coinOwed(token), "the wallets' parts add up to the team's");
        }
    }

    function test_revert_teamSize() public {
        address[] memory w = new address[](1);
        uint16[] memory bps = new uint16[](1);
        (w[0], bps[0]) = (alice, 10_000);
        _revertsLaunch(_teamOf(w, bps), StealthFactory.InvalidOptions.selector);
        (w, bps) = _wallets(11);
        _revertsLaunch(_teamOf(w, bps), StealthFactory.InvalidOptions.selector);
        w = new address[](0);
        bps = new uint16[](0);
        _revertsLaunch(_teamOf(w, bps), StealthFactory.InvalidOptions.selector);
    }

    function test_revert_teamBpsMustSumTo10000() public {
        (address[] memory w, uint16[] memory bps) = _three(5_000, 3_000, 1_999);
        _revertsLaunch(_teamOf(w, bps), StealthFactory.InvalidOptions.selector);
        (w, bps) = _three(5_000, 3_000, 2_001);
        _revertsLaunch(_teamOf(w, bps), StealthFactory.InvalidOptions.selector);
    }

    function test_revert_teamZeroBpsOrZeroWallet() public {
        (address[] memory w, uint16[] memory bps) = _three(10_000, 0, 0);
        _revertsLaunch(_teamOf(w, bps), StealthFactory.InvalidOptions.selector);
        (w, bps) = _two(alice, address(0), 5_000, 5_000);
        _revertsLaunch(_teamOf(w, bps), StealthFactory.InvalidOptions.selector);
        (w, bps) = _two(address(0), alice, 5_000, 5_000);
        _revertsLaunch(_teamOf(w, bps), StealthFactory.InvalidOptions.selector);
    }

    function test_revert_teamDuplicateWallet() public {
        (address[] memory w, uint16[] memory bps) = _two(alice, alice, 5_000, 5_000);
        _revertsLaunch(_teamOf(w, bps), StealthFactory.InvalidOptions.selector);
        (w, bps) = _three(4_000, 3_000, 3_000);
        w[2] = alice;
        _revertsLaunch(_teamOf(w, bps), StealthFactory.InvalidOptions.selector);
    }

    /// @notice A system contract could never claim, stranding its part.
    function test_revert_teamSystemContract() public {
        address[7] memory sys = [
            address(factory),
            address(locker),
            address(vault),
            address(hook),
            address(tokenDeployer),
            address(manager),
            settlementAddr
        ];
        for (uint256 i; i < sys.length; ++i) {
            (address[] memory w, uint16[] memory bps) = _two(alice, sys[i], 5_000, 5_000);
            _revertsLaunch(_teamOf(w, bps), StealthFactory.InvalidCreator.selector);
        }
    }

    function test_revert_teamOnOtherTypes() public {
        LaunchType[5] memory types =
            [LaunchType.Creator, LaunchType.Marketing, LaunchType.Holders, LaunchType.Buyback, LaunchType.Pot];
        (address[] memory w, uint16[] memory bps) = _two(alice, bob, 5_000, 5_000);
        for (uint256 i; i < types.length; ++i) {
            StealthFactory.LaunchOptions memory o = _teamOf(w, bps);
            o.launchType = types[i];
            _revertsLaunch(o, StealthFactory.InvalidOptions.selector);
        }
    }

    // ---------------------------------------------------------------------
    // Earnings
    // ---------------------------------------------------------------------

    function test_earningsFollowTheBps() public {
        (address[] memory w, uint16[] memory bps) = _three(5_000, 3_000, 2_000);
        address token = _launchTeam(w, bps);
        _trade(token);
        assertEq(vault.teamAccrued(token), 29.75e15);
        assertEq(vault.claimable(token, alice), 14.875e15);
        assertEq(vault.claimable(token, bob), 8.925e15);
        assertEq(vault.claimable(token, carol), 5.95e15);
        assertEq(vault.claimable(token, creator), 0, "the launcher is not on the team");
        assertEq(vault.claimable(token, attacker), 0);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Paid(token, StealthFeeVault.Role.Team, bob, 8.925e15);
        vm.prank(bob);
        assertEq(vault.claimCreator(token), 8.925e15);
        assertEq(bob.balance, 8.925e15);
        assertEq(vault.memberPaid(token, bob), 8.925e15);
        assertEq(vault.coinOwed(token), 29.75e15 - 8.925e15);
        assertEq(vault.creatorClaimed(token), 8.925e15);
        assertEq(vault.claimable(token, alice), 14.875e15, "one wallet's claim moves nobody else's");
        assertEq(vault.claimable(token, bob), 0);
        _assertBooks(token);

        vm.prank(bob);
        vm.expectRevert(StealthFeeVault.NothingToClaim.selector);
        vault.claimCreator(token);
    }

    function test_claimsAcrossRounds_payOnlyWhatIsNew() public {
        (address[] memory w, uint16[] memory bps) = _two(alice, bob, 8_000, 2_000);
        address token = _launchTeam(w, bps);
        _trade(token);
        vm.prank(alice);
        vault.claimCreator(token);
        assertEq(alice.balance, 23.8e15);
        _trade(token);
        _trade(token);
        vm.prank(alice);
        assertEq(vault.claimCreator(token), 47.6e15, "two more rounds, only those");
        assertEq(alice.balance, 71.4e15);
        vm.prank(bob);
        assertEq(vault.claimCreator(token), 17.85e15, "three rounds, in one claim");
        assertEq(vault.teamAccrued(token), 89.25e15);
        assertEq(vault.coinOwed(token), 0);
        assertEq(vault.totalOwed(NATIVE), vault.marketingOwed(token) + vault.platformOwed(token));
        _assertBooks(token);
    }

    /// @notice A team claim pays that wallet and nobody else, like a creator's.
    function test_claim_paysOnlyTheClaimant() public {
        (address[] memory w, uint16[] memory bps) = _two(alice, bob, 5_000, 5_000);
        address token = _launchTeam(w, bps);
        _trade(token);
        uint256 m = vault.marketingOwed(token);
        uint256 p = vault.platformOwed(token);
        uint256 mb = marketing.balance;
        uint256 pb = platform.balance;
        vm.prank(alice);
        vault.claimCreator(token);
        assertEq(marketing.balance - mb, 0);
        assertEq(platform.balance - pb, 0);
        assertEq(vault.marketingOwed(token), m);
        assertEq(vault.platformOwed(token), p);
        _assertBooks(token);
    }

    function test_partialClaim_toAnotherAddress() public {
        (address[] memory w, uint16[] memory bps) = _two(alice, bob, 5_000, 5_000);
        address token = _launchTeam(w, bps);
        _trade(token);
        uint256 mine = vault.claimable(token, alice);
        address cold = makeAddr("cold");
        vm.prank(alice);
        vault.claimCreatorAmount(token, mine / 4, cold);
        assertEq(cold.balance, mine / 4);
        assertEq(alice.balance, 0);
        assertEq(vault.memberPaid(token, alice), mine / 4);
        assertEq(vault.claimable(token, alice), mine - mine / 4, "the rest stays");
        assertEq(vault.claimable(token, bob), mine, "the other wallet untouched");

        vm.startPrank(alice);
        vm.expectRevert(StealthFeeVault.AmountTooHigh.selector);
        vault.claimCreatorAmount(token, mine - mine / 4 + 1, cold);
        vm.expectRevert(StealthFeeVault.NothingToClaim.selector);
        vault.claimCreatorAmount(token, 0, cold);
        vm.expectRevert(DexBase.ZeroAddress.selector);
        vault.claimCreatorAmount(token, 1, address(0));
        vault.claimCreatorAmount(token, mine - mine / 4, alice);
        vm.stopPrank();
        assertEq(vault.claimable(token, alice), 0);
        _assertBooks(token);
    }

    /// @notice Claims that exceed a wallet's own part fail, however much the team as a whole is owed.
    function test_revert_walletClaimsMoreThanItsPart() public {
        (address[] memory w, uint16[] memory bps) = _two(alice, bob, 9_000, 1_000);
        address token = _launchTeam(w, bps);
        _trade(token);
        uint256 mine = vault.claimable(token, bob);
        assertLt(mine, vault.coinOwed(token));
        vm.prank(bob);
        vm.expectRevert(StealthFeeVault.AmountTooHigh.selector);
        vault.claimCreatorAmount(token, mine + 1, bob);
    }

    function test_revert_notATeamWallet() public {
        (address[] memory w, uint16[] memory bps) = _two(alice, bob, 5_000, 5_000);
        address token = _launchTeam(w, bps);
        _trade(token);
        address[2] memory outsiders = [creator, attacker];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(StealthFeeVault.NotCreator.selector);
            vault.claimCreator(token);
            vm.prank(outsiders[i]);
            vm.expectRevert(StealthFeeVault.NotCreator.selector);
            vault.claimCreatorAmount(token, 1, outsiders[i]);
        }
    }

    // ---------------------------------------------------------------------
    // Rounding
    // ---------------------------------------------------------------------

    /// @notice 74 units by 33.33 / 33.33 / 33.34: 24 each, and wallet 0 takes the 2 left over.
    function test_rounding_goesToWalletZero() public {
        (address[] memory w, uint16[] memory bps) = _three(3_333, 3_333, 3_334);
        address token = _launchTeam(w, bps);
        vm.prank(address(hook));
        vault.credit(token, NATIVE, 1_000, TAX_PIPS);
        assertEq(vault.teamAccrued(token), 700);
        assertEq(vault.claimable(token, bob), 233);
        assertEq(vault.claimable(token, carol), 233);
        assertEq(vault.claimable(token, alice), 234);
    }

    /// @notice Rounding is on the lifetime total, so it never builds up over many small credits, and the wallets' parts
    ///         always add up to the team's total.
    function testFuzz_earningsAlwaysSumToTheTotal(uint96[8] memory fees, uint16 aBps, uint16 bBps) public {
        aBps = uint16(bound(aBps, 1, 9_998));
        bBps = uint16(bound(bBps, 1, 9_999 - aBps));
        (address[] memory w, uint16[] memory bps) = _three(aBps, bBps, 10_000 - aBps - bBps);
        address token = _launchTeam(w, bps);
        uint256 accrued;
        for (uint256 i; i < fees.length; ++i) {
            vm.prank(address(hook));
            vault.credit(token, NATIVE, fees[i], TAX_PIPS);
            accrued = vault.teamAccrued(token);
            assertEq(
                vault.claimable(token, alice) + vault.claimable(token, bob) + vault.claimable(token, carol),
                accrued,
                "parts add up"
            );
            assertEq(vault.claimable(token, bob), accrued * bBps / 10_000, "bps of the lifetime total");
            assertLe(vault.claimable(token, alice) - accrued * aBps / 10_000, 2, "wallet 0: at most the rounding");
        }
    }

    /// @notice Whatever order the wallets claim in, across trades, everyone ends with exactly their part.
    function testFuzz_claimOrderDoesNotMatter(uint8 rounds, uint256 seed) public {
        rounds = uint8(bound(rounds, 1, 6));
        (address[] memory w, uint16[] memory bps) = _three(3_333, 3_333, 3_334);
        address token = _launchTeam(w, bps);
        uint256[3] memory got;
        for (uint256 r; r < rounds; ++r) {
            _trade(token);
            uint256 i = uint256(keccak256(abi.encode(seed, r))) % 3;
            if (vault.claimable(token, w[i]) == 0) continue;
            vm.prank(w[i]);
            got[i] += vault.claimCreator(token);
        }
        for (uint256 i; i < 3; ++i) {
            uint256 left = vault.claimable(token, w[i]);
            if (left == 0) continue;
            vm.prank(w[i]);
            got[i] += vault.claimCreator(token);
        }
        uint256 accrued = vault.teamAccrued(token);
        assertEq(got[0] + got[1] + got[2], accrued);
        assertEq(got[1], accrued * 3_333 / 10_000);
        assertEq(got[2], accrued * 3_334 / 10_000);
        assertEq(vault.coinOwed(token), 0);
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE));
    }

    // ---------------------------------------------------------------------
    // Hostile or broken wallets
    // ---------------------------------------------------------------------

    /// @notice A wallet that cannot receive the native coin hurts only itself: its balance stays its own, the others
    ///         claim as usual, and it can still send its balance to another address.
    function test_rejectingWallet_hurtsOnlyItself() public {
        RejectingWallet stuck = new RejectingWallet();
        (address[] memory w, uint16[] memory bps) = _two(address(stuck), alice, 5_000, 5_000);
        address token = _launchTeam(w, bps);
        _trade(token);
        uint256 mine = vault.claimable(token, address(stuck));
        assertGt(mine, 0);

        vm.expectRevert();
        stuck.claim(vault, token);
        assertEq(vault.claimable(token, address(stuck)), mine, "still owed");
        assertEq(vault.memberPaid(token, address(stuck)), 0);

        vm.prank(alice);
        assertEq(vault.claimCreator(token), mine, "the other wallet is paid");
        vault.sweep(_one(token));

        address rescue = makeAddr("rescue");
        stuck.claimTo(vault, token, mine, rescue);
        assertEq(rescue.balance, mine);
        assertEq(vault.coinOwed(token), 0);
        _assertBooks(token);
    }

    function test_reentrantWallet_isBlocked() public {
        ReentrantWallet bad = new ReentrantWallet(vault);
        (address[] memory w, uint16[] memory bps) = _two(address(bad), alice, 5_000, 5_000);
        address token = _launchTeam(w, bps);
        _trade(token);
        uint256 owed = vault.coinOwed(token);
        vm.expectRevert();
        bad.claim(token);
        assertEq(vault.coinOwed(token), owed, "nothing moved");
        assertEq(vault.memberPaid(token, address(bad)), 0);
        _assertBooks(token);
    }

    // ---------------------------------------------------------------------
    // The wallets are fixed
    // ---------------------------------------------------------------------

    function test_handoff_movesNoTeamWalletNorMoney() public {
        (address[] memory w, uint16[] memory bps) = _two(alice, bob, 6_000, 4_000);
        address token = _launchTeam(w, bps);
        _trade(token);
        uint256 a = vault.claimable(token, alice);
        vm.prank(creator);
        vault.offerCreator(token, handoff);
        vm.prank(handoff);
        vault.acceptCreator(token);
        assertEq(vault.creatorOf(token), handoff);
        assertEq(vault.claimable(token, alice), a, "still alice's");
        assertEq(vault.claimable(token, handoff), 0);
        (address[] memory wallets,) = vault.team(token);
        assertEq(wallets, w, "the wallets did not change");
        vm.prank(handoff);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreator(token);
    }

    function test_teamInErc20Quote() public {
        MockERC20 q = _listedQuote("QT", 6, 1, 1_000);
        (address[] memory w, uint16[] memory bps) = _two(alice, bob, 6_000, 4_000);
        StealthFactory.LaunchParams memory p = _paramsQ(address(q), TAX, 4e6, 0, 0);
        p.options = _teamOf(w, bps);
        q.mint(creator, 1e6);
        vm.startPrank(creator);
        q.approve(address(factory), type(uint256).max);
        address token = factory.launch(p);
        vm.stopPrank();
        _skipSniperWindow(token);
        _fundQuote(token, traders[0], 10e6);
        _buy(traders[0], token, 1e6);
        assertEq(vault.coinOwed(token), 29_750);
        vm.prank(alice);
        assertEq(vault.claimCreator(token), 17_850);
        vm.prank(bob);
        assertEq(vault.claimCreator(token), 11_900);
        assertEq(q.balanceOf(alice), 17_850);
        assertEq(q.balanceOf(bob), 11_900);
        Currency qc = Currency.wrap(address(q));
        assertEq(_vaultClaims(qc), vault.totalOwed(qc));
    }

    /// @notice A launch with a first buy books the team's part of the first buy's fee too.
    function test_firstBuyFee_reachesTheTeam() public {
        (address[] memory w, uint16[] memory bps) = _two(alice, bob, 5_000, 5_000);
        address token = _launchOpts(creator, TAX, 0.1 ether, _teamOf(w, bps));
        assertGt(vault.teamAccrued(token), 0);
        assertEq(vault.teamAccrued(token), vault.coinOwed(token));
        assertEq(vault.claimable(token, alice) + vault.claimable(token, bob), vault.coinOwed(token));
    }

    /// @dev The vault packs a wallet and its bps into one slot: both come back whole.
    function test_registerToken_storesBpsExactly() public {
        TeamShare[] memory t = new TeamShare[](2);
        t[0] = TeamShare(address(type(uint160).max), 9_999);
        t[1] = TeamShare(address(1), 1);
        vm.prank(address(factory));
        vault.registerToken(address(9), creator, NATIVE, LaunchType.Team, t, 125);
        (address[] memory wallets, uint16[] memory split) = vault.team(address(9));
        assertEq(wallets[0], address(type(uint160).max));
        assertEq(wallets[1], address(1));
        assertEq(split[0], 9_999);
        assertEq(split[1], 1);
    }
}
