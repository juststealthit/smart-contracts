// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DexBase} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {RejectingCreator} from "../utils/Harnesses.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {LaunchType} from "../../src/interfaces/IStealth.sol";

/// @dev Old creator wallet that tries to claim its legacy balance again while being paid.
contract ReentrantLegacy {
    StealthFeeVault internal immutable vault;
    address internal token;
    bool internal reenter;

    constructor(StealthFeeVault vault_) {
        vault = vault_;
    }

    function arm(address token_) external {
        token = token_;
        reenter = true;
    }

    function claimLegacy(address token_) external returns (uint256) {
        return vault.claimLegacy(token_, address(this));
    }

    receive() external payable {
        if (reenter) {
            reenter = false;
            vault.claimLegacy(token, address(this));
        }
    }
}

/// @notice v3.1: launching for someone else, claims that also sweep, partial claims, and takeovers (creator manager
///         proposes, 24 h notice, admin cancel, new creator accepts, old creator keeps its backlog).
contract TakeoverTest is BaseTest {
    event Launched(
        address indexed token,
        address indexed creator,
        bytes32 indexed poolId,
        address launcher,
        address quote,
        string name,
        string symbol,
        uint16 taxBps,
        LaunchType launchType,
        uint256 target
    );
    event Paid(address indexed token, StealthFeeVault.Role indexed role, address indexed to, uint256 amount);
    event CreatorManagerSet(address indexed previous, address indexed current);
    event ReassignProposed(address indexed token, address indexed from, address indexed to, uint256 eta);
    event ReassignCancelled(address indexed token, address indexed to, address indexed by);
    event CreatorReassigned(address indexed token, address indexed from, address indexed to, uint256 legacy);

    address internal escrow = makeAddr("socialEscrow");
    address internal team = makeAddr("ctoTeam");
    address internal launcher = makeAddr("launcher");

    function setUp() public override {
        super.setUp();
        vm.deal(launcher, ACTOR_BALANCE);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _launchFor(address who, address feeTo, uint256 value) internal returns (address token) {
        StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
        p.creator = feeTo;
        vm.prank(who);
        token = factory.launch{value: value}(p);
    }

    /// @dev Some trading after the sniper window, so every role has fees owed.
    function _trade(address token) internal {
        _skipSniperWindow(token);
        uint256 got = _buy(traders[0], token, 1 ether);
        _sell(traders[0], token, got / 2);
    }

    function _propose(address token, address to) internal {
        vm.prank(creatorManager);
        vault.proposeReassign(token, to);
    }

    function _acceptAfterNotice(address token, address to) internal {
        (, uint64 eta,) = vault.reassignment(token);
        vm.warp(eta);
        vm.prank(to);
        vault.acceptReassign(token);
    }

    function _assertBooks(address token) internal view {
        address[] memory list = new address[](1);
        list[0] = token;
        assertEq(_vaultClaims(), _vaultOwed(list), "claims != owed");
        assertEq(vault.totalOwed(NATIVE), _vaultOwed(list), "totalOwed != owed");
    }

    // ---------------------------------------------------------------------
    // Launching for someone else
    // ---------------------------------------------------------------------

    function test_launch_creatorFieldRoutesFees_launcherKeepsTokens() public {
        StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
        p.creator = escrow;
        address predicted = factory.predictTokenAddress(launcher, p);
        vm.expectEmit(true, true, false, true, address(factory));
        emit Launched(
            predicted, escrow, bytes32(0), launcher, address(0), "Stealth Test", "MKT", TAX, LaunchType.Creator, 4 ether
        );
        uint256 before = launcher.balance;
        vm.prank(launcher);
        address token = factory.launch{value: 1 ether}(p);

        assertEq(vault.creatorOf(token), escrow, "fees go to the named creator");
        StealthLocker.PoolInfo memory info = locker.getPool(token);
        assertEq(info.launcher, launcher, "locker records the launcher");
        assertGt(IERC20(token).balanceOf(launcher), 0, "first-buy tokens go to the launcher");
        assertEq(IERC20(token).balanceOf(escrow), 0);
        assertEq(escrow.balance, 0);
        assertLt(before - launcher.balance, 1 ether + 1, "launcher paid, refund came back to the launcher");

        _trade(token);
        assertGt(vault.coinOwed(token), 0);
        vm.prank(launcher);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreator(token);
        uint256 owed = vault.coinOwed(token);
        vm.prank(escrow);
        vault.claimCreator(token);
        assertEq(escrow.balance, owed);
    }

    function test_launch_zeroCreatorMeansCaller() public {
        address token = _launchFor(launcher, address(0), 0);
        assertEq(vault.creatorOf(token), launcher);
    }

    // ---------------------------------------------------------------------
    // A claim pays the claimant and nobody else
    // ---------------------------------------------------------------------

    function test_claimCreator_paysOnlyTheClaimant() public {
        address token = _launch(TAX, 4 ether);
        _trade(token);
        uint256 c = vault.coinOwed(token);
        uint256 m = vault.marketingOwed(token);
        uint256 p = vault.platformOwed(token);
        assertEq(m, 0, "no marketing share on a Creator coin");
        assertGt(p, 0);
        uint256 cb = creator.balance;
        uint256 mb = marketing.balance;
        uint256 tb = platform.balance;
        vm.expectEmit(true, true, true, true, address(vault));
        emit Paid(token, StealthFeeVault.Role.Creator, creator, c);
        vm.prank(creator);
        assertEq(vault.claimCreator(token), c);
        assertEq(creator.balance - cb, c);
        assertEq(marketing.balance - mb, 0, "marketing waits for a sweep");
        assertEq(platform.balance - tb, 0, "platform waits for a sweep");
        assertEq(vault.marketingOwed(token), m);
        assertEq(vault.platformOwed(token), p);
        assertEq(vault.totalOwed(NATIVE), m + p);
        _assertBooks(token);
    }

    /// @notice Rotating the wallets to something that rejects payment freezes sweeps only. No wallet can hold a
    ///         creator's money up: the reason claims stopped sweeping.
    function test_claim_survivesRejectingPlatformAndMarketingWallets() public {
        address token = _launch(TAX, 4 ether);
        _trade(token);
        address rejecting = address(new RejectingCreator());
        vm.prank(admin);
        vault.setWallets(rejecting, rejecting);
        uint256 c = vault.coinOwed(token);
        vm.prank(claimer);
        vm.expectRevert();
        vault.sweep(_one(token));
        vm.prank(creator);
        assertEq(vault.claimCreator(token), c);
        _assertBooks(token);
    }

    function test_claimCreatorAmount_partial() public {
        address token = _launch(TAX, 4 ether);
        _trade(token);
        uint256 c = vault.coinOwed(token);
        uint256 part = c / 3;
        vm.prank(creator);
        vault.claimCreatorAmount(token, part, creator);
        assertEq(vault.coinOwed(token), c - part, "rest stays owed");
        assertEq(vault.creatorClaimed(token), part);
        assertGt(vault.platformOwed(token), 0, "a claim sweeps nothing");
        _assertBooks(token);

        vm.startPrank(creator);
        vm.expectRevert(StealthFeeVault.AmountTooHigh.selector);
        vault.claimCreatorAmount(token, c - part + 1, creator);
        vm.expectRevert(StealthFeeVault.NothingToClaim.selector);
        vault.claimCreatorAmount(token, 0, creator);
        vault.claimCreatorAmount(token, c - part, creator);
        vm.stopPrank();
        assertEq(vault.coinOwed(token), 0);
        assertEq(vault.totalOwed(NATIVE), vault.marketingOwed(token) + vault.platformOwed(token));
    }

    function test_revert_claimCreatorAmount_notCreator() public {
        address token = _launch(TAX, 4 ether);
        _trade(token);
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreatorAmount(token, 1, attacker);
    }

    // ---------------------------------------------------------------------
    // Creator manager
    // ---------------------------------------------------------------------

    function test_setCreatorManager_adminOnly_followsAdminHandover() public {
        address next = makeAddr("nextManager");
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotAuthorized.selector);
        vault.setCreatorManager(next);
        vm.prank(creatorManager);
        vm.expectRevert(StealthFeeVault.NotAuthorized.selector);
        vault.setCreatorManager(next);
        vm.prank(admin);
        vm.expectRevert(DexBase.ZeroAddress.selector);
        vault.setCreatorManager(address(0));

        vm.expectEmit(true, true, false, false, address(vault));
        emit CreatorManagerSet(creatorManager, next);
        vm.prank(admin);
        vault.setCreatorManager(next);
        assertEq(vault.creatorManager(), next);

        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        factory.proposeAdmin(newAdmin);
        vm.prank(newAdmin);
        factory.acceptAdmin();
        vm.prank(admin);
        vm.expectRevert(StealthFeeVault.NotAuthorized.selector);
        vault.setCreatorManager(creatorManager);
        vm.prank(newAdmin);
        vault.setCreatorManager(creatorManager);
        assertEq(vault.creatorManager(), creatorManager);
    }

    // ---------------------------------------------------------------------
    // Proposing and cancelling
    // ---------------------------------------------------------------------

    function test_propose_storesAndEmits() public {
        address token = _launch(TAX, 4 ether);
        uint256 eta = block.timestamp + 24 hours;
        vm.expectEmit(true, true, true, true, address(vault));
        emit ReassignProposed(token, creator, team, eta);
        _propose(token, team);
        (address to, uint64 e,) = vault.reassignment(token);
        assertEq(to, team);
        assertEq(e, eta);
    }

    function test_revert_propose_rules() public {
        address token = _launch(TAX, 4 ether);
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotCreatorManager.selector);
        vault.proposeReassign(token, team);
        vm.prank(admin);
        vm.expectRevert(StealthFeeVault.NotCreatorManager.selector);
        vault.proposeReassign(token, team);
        vm.prank(creator);
        vm.expectRevert(StealthFeeVault.NotCreatorManager.selector);
        vault.proposeReassign(token, team);

        vm.startPrank(creatorManager);
        vm.expectRevert(StealthFeeVault.UnknownToken.selector);
        vault.proposeReassign(makeAddr("notAToken"), team);
        vm.expectRevert(StealthFeeVault.InvalidReassign.selector);
        vault.proposeReassign(token, address(0));
        vm.expectRevert(StealthFeeVault.InvalidReassign.selector);
        vault.proposeReassign(token, creator);
        vm.stopPrank();
    }

    function test_propose_replacesAndRestartsNotice() public {
        address token = _launch(TAX, 4 ether);
        _propose(token, team);
        vm.warp(block.timestamp + 20 hours);
        address other = makeAddr("otherTeam");
        _propose(token, other);
        (address to, uint64 eta,) = vault.reassignment(token);
        assertEq(to, other);
        assertEq(eta, block.timestamp + 24 hours, "notice restarted");
        vm.warp(block.timestamp + 5 hours);
        vm.prank(team);
        vm.expectRevert(StealthFeeVault.NoReassign.selector);
        vault.acceptReassign(token);
    }

    function test_cancel_byAdminOrManagerOnly() public {
        address token = _launch(TAX, 4 ether);
        vm.prank(admin);
        vm.expectRevert(StealthFeeVault.NoReassign.selector);
        vault.cancelReassign(token);

        _propose(token, team);
        vm.prank(creator);
        vm.expectRevert(StealthFeeVault.NotAdminOrManager.selector);
        vault.cancelReassign(token);
        vm.prank(team);
        vm.expectRevert(StealthFeeVault.NotAdminOrManager.selector);
        vault.cancelReassign(token);

        vm.expectEmit(true, true, true, false, address(vault));
        emit ReassignCancelled(token, team, admin);
        vm.prank(admin);
        vault.cancelReassign(token);
        (address to,,) = vault.reassignment(token);
        assertEq(to, address(0));

        _propose(token, team);
        vm.prank(creatorManager);
        vault.cancelReassign(token);
        vm.warp(block.timestamp + 2 days);
        vm.prank(team);
        vm.expectRevert(StealthFeeVault.NoReassign.selector);
        vault.acceptReassign(token);
    }

    // ---------------------------------------------------------------------
    // Accepting
    // ---------------------------------------------------------------------

    function test_accept_noticeAndWindowBoundaries() public {
        address token = _launch(TAX, 4 ether);
        _propose(token, team);
        (, uint64 eta,) = vault.reassignment(token);

        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NoReassign.selector);
        vault.acceptReassign(token);

        vm.warp(eta - 1);
        vm.prank(team);
        vm.expectRevert(StealthFeeVault.NoticeRunning.selector);
        vault.acceptReassign(token);

        vm.warp(uint256(eta) + 7 days + 1);
        vm.prank(team);
        vm.expectRevert(StealthFeeVault.ReassignExpired.selector);
        vault.acceptReassign(token);

        vm.warp(uint256(eta) + 7 days);
        vm.prank(team);
        vault.acceptReassign(token);
        assertEq(vault.creatorOf(token), team, "last second of the window still accepts");
    }

    /// @notice The case that motivated no inactivity guard: the original dev keeps claiming but does nothing for
    ///         the token. After the takeover the dev can claim only what it earned before; the team gets the rest.
    function test_takeover_devKeepsBacklog_teamGetsFutureFees() public {
        address token = _launch(TAX, 4 ether);
        _trade(token);
        vm.prank(creator);
        vault.claimCreator(token); // the dev is active: it claims
        _trade(token);
        uint256 backlog = vault.coinOwed(token);
        assertGt(backlog, 0);

        _propose(token, team);
        _trade(token); // fees during the notice still belong to the dev
        backlog = vault.coinOwed(token);
        vm.prank(creator);
        vault.offerCreator(token, makeAddr("devFriend")); // a pending voluntary offer is wiped by the takeover

        vm.expectEmit(true, true, true, true, address(vault));
        emit CreatorReassigned(token, creator, team, backlog);
        _acceptAfterNotice(token, team);

        assertEq(vault.creatorOf(token), team);
        assertEq(vault.pendingCreator(token), address(0), "voluntary offer cleared");
        assertEq(vault.coinOwed(token), 0, "team starts from zero");
        assertEq(vault.legacyOwed(token, creator), backlog);
        assertEq(vault.legacyTotal(token), backlog);
        _assertBooks(token);

        vm.prank(creator);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreator(token);

        _trade(token);
        uint256 teamFees = vault.coinOwed(token);
        assertGt(teamFees, 0);
        vm.prank(team);
        vault.claimCreator(token);
        assertEq(team.balance, teamFees, "every fee after the switch went to the team");

        uint256 cb = creator.balance;
        vm.prank(creator);
        assertEq(vault.claimLegacy(token, creator), backlog);
        assertEq(creator.balance - cb, backlog);
        assertEq(vault.legacyTotal(token), 0);
        vm.prank(creator);
        vm.expectRevert(StealthFeeVault.NothingToClaim.selector);
        vault.claimLegacy(token, creator);
        _assertBooks(token);
        assertEq(vault.totalOwed(NATIVE), vault.marketingOwed(token) + vault.platformOwed(token));
    }

    function test_takeover_backAndForth_legacyAccumulates() public {
        address token = _launch(TAX, 4 ether);
        _trade(token);
        uint256 first = vault.coinOwed(token);
        _propose(token, team);
        _acceptAfterNotice(token, team);
        _trade(token);
        uint256 second = vault.coinOwed(token);
        _propose(token, creator);
        _acceptAfterNotice(token, creator);
        assertEq(vault.legacyOwed(token, creator), first);
        assertEq(vault.legacyOwed(token, team), second);
        assertEq(vault.legacyTotal(token), first + second);
        _trade(token);
        _propose(token, team);
        uint256 third = vault.coinOwed(token);
        _acceptAfterNotice(token, team);
        assertEq(vault.legacyOwed(token, creator), first + third, "same wallet replaced twice");
        _assertBooks(token);
    }

    function test_takeover_zeroBacklog() public {
        address token = _launch(TAX, 4 ether);
        _propose(token, team);
        _acceptAfterNotice(token, team);
        assertEq(vault.legacyOwed(token, creator), 0);
        assertEq(vault.creatorOf(token), team);
    }

    function test_handoffToProposedWallet_clearsProposal() public {
        address token = _launch(TAX, 4 ether);
        _propose(token, team);
        vm.prank(creator);
        vault.offerCreator(token, team);
        vm.expectEmit(true, true, true, false, address(vault));
        emit ReassignCancelled(token, team, team);
        vm.prank(team);
        vault.acceptCreator(token);
        (address to,,) = vault.reassignment(token);
        assertEq(to, address(0));
        assertEq(vault.creatorOf(token), team);
    }

    /// @notice A dev who dodges by handing off to a friend during the notice: the proposal stands, and the friend
    ///         (the creator at the moment of the switch) keeps the backlog.
    function test_handoffToOtherWallet_keepsProposal() public {
        address token = _launch(TAX, 4 ether);
        _trade(token);
        _propose(token, team);
        address friend = makeAddr("devFriend");
        vm.prank(creator);
        vault.offerCreator(token, friend);
        vm.prank(friend);
        vault.acceptCreator(token);
        (address to,,) = vault.reassignment(token);
        assertEq(to, team, "proposal survives");
        uint256 backlog = vault.coinOwed(token);
        _acceptAfterNotice(token, team);
        assertEq(vault.legacyOwed(token, friend), backlog);
        assertEq(vault.legacyOwed(token, creator), 0);
        assertEq(vault.creatorOf(token), team);
    }

    function test_revert_claimLegacy_reentry() public {
        ReentrantLegacy old = new ReentrantLegacy(vault);
        address token = _launchFor(launcher, address(old), 0);
        _trade(token);
        _propose(token, team);
        _acceptAfterNotice(token, team);
        assertGt(vault.legacyOwed(token, address(old)), 0);
        old.arm(token);
        vm.expectRevert();
        old.claimLegacy(token);
        assertGt(vault.legacyOwed(token, address(old)), 0, "nothing paid");
    }

    // ---------------------------------------------------------------------
    // Takeovers pay only the Creator type
    // ---------------------------------------------------------------------

    /// @notice On a Team coin the role is attribution: a takeover moves no money and no wallet.
    function test_takeover_teamCoin_movesNothing() public {
        address[] memory wallets = new address[](2);
        wallets[0] = makeAddr("w0");
        wallets[1] = makeAddr("w1");
        uint16[] memory bps = new uint16[](2);
        bps[0] = 7_000;
        bps[1] = 3_000;
        address token = _launchOpts(creator, TAX, 0, _teamOf(wallets, bps));
        _trade(token);
        uint256 owed = vault.coinOwed(token);
        assertGt(owed, 0);
        uint256 w0Claimable = vault.claimable(token, wallets[0]);
        _propose(token, team);
        _acceptAfterNotice(token, team);
        assertEq(vault.creatorOf(token), team, "the role moved");
        assertEq(vault.coinOwed(token), owed, "the team's balance did not");
        assertEq(vault.legacyTotal(token), 0, "nothing became legacy");
        assertEq(vault.claimable(token, wallets[0]), w0Claimable);
        assertEq(vault.claimable(token, team), 0, "the new creator is not a team wallet");
        vm.prank(team);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreator(token);
        _assertBooks(token);
    }

    /// @notice On Holders, Buyback, Marketing and Pot coins a takeover moves the role and not one unit of the pot.
    function test_takeover_potCoins_movesNothing() public {
        LaunchType[4] memory types = [LaunchType.Holders, LaunchType.Buyback, LaunchType.Marketing, LaunchType.Pot];
        for (uint256 i; i < types.length; ++i) {
            address token = _launchOpts(creator, TAX, 0, _typed(types[i]));
            _trade(token);
            uint256 pot = vault.coinOwed(token);
            _propose(token, team);
            _acceptAfterNotice(token, team);
            assertEq(vault.coinOwed(token), pot, "the pot stays");
            assertEq(vault.legacyTotal(token), 0);
            vm.prank(team);
            vm.expectRevert(StealthFeeVault.NotCreator.selector);
            vault.claimCreator(token);
            vm.prank(creator);
            vm.expectRevert(StealthFeeVault.NotCreator.selector);
            vault.claimCreator(token);
        }
    }

    /// @notice A hand-off on a pot coin moves the role only.
    function test_handoff_potCoin_movesNothing() public {
        address token = _launchOpts(creator, TAX, 0, _typed(LaunchType.Holders));
        _trade(token);
        uint256 pot = vault.coinOwed(token);
        vm.prank(creator);
        vault.offerCreator(token, handoff);
        vm.prank(handoff);
        vault.acceptCreator(token);
        assertEq(vault.creatorOf(token), handoff);
        assertEq(vault.coinOwed(token), pot);
        vm.prank(handoff);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreator(token);
    }

    // ---------------------------------------------------------------------
    // Social escrow flows (the server holds the escrow key)
    // ---------------------------------------------------------------------

    /// @notice the handle arrives, logs in, and the escrow hands the token to the wallet it connects. The handle's
    ///         wallet gets the whole backlog (voluntary hand-off moves everything).
    function test_social_claimByHandle_getsWholeBacklog() public {
        address token = _launchFor(launcher, escrow, 0);
        _trade(token);
        uint256 owed = vault.coinOwed(token);
        address handleWallet = makeAddr("handleWallet");
        vm.prank(escrow);
        vault.offerCreator(token, handleWallet);
        vm.startPrank(handleWallet);
        vault.acceptCreator(token);
        vault.claimCreator(token);
        vm.stopPrank();
        assertEq(handleWallet.balance, owed);
        assertEq(escrow.balance, 0, "nothing ever sat in the escrow");
    }

    /// @notice 30-day rule: the escrow pays only the part older than 30 days (the server works out the amount)
    ///         straight to marketing; the newer part stays in the vault for the handle. Nothing touches the escrow.
    function test_social_thirtyDayRedirect_partialClaim() public {
        address token = _launchFor(launcher, escrow, 0);
        _trade(token);
        uint256 old = vault.coinOwed(token);
        vm.warp(block.timestamp + 30 days);
        _trade(token);
        uint256 recent = vault.coinOwed(token) - old;
        uint256 mb = marketing.balance;
        vm.prank(escrow);
        vault.claimCreatorAmount(token, old, marketing);
        assertEq(marketing.balance - mb, old, "the redirect, nothing else");
        assertEq(escrow.balance, 0, "nothing sat in the escrow");
        assertEq(vault.coinOwed(token), recent, "the last 30 days stay reserved for the handle");
        _assertBooks(token);
    }

    /// @notice Takeover of a social token: the backlog stays reserved under the escrow for the handle, and is paid
    ///         straight to the handle's wallet when it shows up.
    function test_social_takeover_backlogStaysWithEscrow() public {
        address token = _launchFor(launcher, escrow, 0);
        _trade(token);
        uint256 owed = vault.coinOwed(token);
        _propose(token, team);
        _acceptAfterNotice(token, team);
        assertEq(vault.legacyOwed(token, escrow), owed);
        address handleWallet = makeAddr("handleWallet");
        vm.prank(escrow);
        vault.claimLegacy(token, handleWallet);
        assertEq(handleWallet.balance, owed);
        assertEq(escrow.balance, 0);
    }
}
