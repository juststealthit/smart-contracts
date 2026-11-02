// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {DexBase, DexCallback, IDexManager} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthToken} from "../../src/StealthToken.sol";
import {LaunchType} from "../../src/interfaces/IStealth.sol";

/// @notice A creator contract that can call the vault but cannot receive native (no receive/fallback), e.g. a
///         misconfigured multisig module or a contract wallet whose fallback reverts.
contract NoReceiveCreator {
    StealthFeeVault internal immutable vault;

    constructor(StealthFeeVault vault_) {
        vault = vault_;
    }

    function offer(address token, address to) external {
        vault.offerCreator(token, to);
    }

    function claim(address token) external {
        vault.claimCreator(token);
    }

    function claimLegacy(address token) external {
        vault.claimLegacy(token, address(this));
    }

    function claimLegacyTo(address token, address to) external {
        vault.claimLegacy(token, to);
    }
}

/// @notice A creator contract that claims from inside its own settlement lock (the vault's `_run` then settles
///         directly), and tries to re-enter the vault from `receive` while the vault is mid-payout.
contract OuterUnlockCreator is DexCallback {
    StealthFeeVault internal immutable vault;
    address internal token;
    uint256 internal amount;
    bool public reenterLegacyReverted;
    bool public reenterSweepReverted;
    bool public reenterClaimReverted;
    bool internal inside;

    constructor(IDexManager manager_, StealthFeeVault vault_) DexBase(manager_) {
        vault = vault_;
    }

    function go(address token_, uint256 amount_) external {
        token = token_;
        amount = amount_;
        _lockRaw("");
    }

    function _onLock(bytes calldata) internal override returns (bytes memory) {
        inside = true;
        if (amount == 0) vault.claimCreator(token);
        else vault.claimCreatorAmount(token, amount, address(this));
        inside = false;
        return "";
    }

    receive() external payable {
        if (!inside) return;
        try vault.claimLegacy(token, address(this)) {} catch { reenterLegacyReverted = true; }
        address[] memory t = new address[](1);
        t[0] = token;
        try vault.sweep(t) {} catch { reenterSweepReverted = true; }
        try vault.claimCreatorAmount(token, 1, address(this)) {} catch { reenterClaimReverted = true; }
    }
}

/// @notice Independent review of v3.1 (creator field, takeovers, sweeping claims), reports/security-review-v3.1.md.
///         `test_fixed_*` pin the fix for a reported finding; `test_accepted_*` pin behaviour kept by design;
///         `test_attempt_*` pass because the defence holds.
contract ReviewV31Test is BaseTest {
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

    address internal team = makeAddr("ctoTeam");
    address internal launcher = makeAddr("launcher");

    function setUp() public override {
        super.setUp();
        vm.deal(launcher, ACTOR_BALANCE);
    }

    function _launchFor(address who, address feeTo, uint256 value) internal returns (address token) {
        StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
        p.creator = feeTo;
        vm.prank(who);
        token = factory.launch{value: value}(p);
    }

    function _trade(address token) internal {
        _skipSniperWindow(token);
        uint256 got = _buy(traders[0], token, 1 ether);
        _sell(traders[0], token, got / 2);
    }

    function _propose(address token, address to) internal {
        address m = vault.creatorManager();
        vm.prank(m);
        vault.proposeReassign(token, to);
    }

    function _warpToEta(address token) internal {
        (, uint64 eta,) = vault.reassignment(token);
        vm.warp(eta);
    }

    function _assertBooks(address[] memory tokens) internal view {
        assertEq(_vaultClaims(), _vaultOwed(tokens), "claims != owed");
        assertEq(vault.totalOwed(NATIVE), _vaultOwed(tokens), "totalOwed != owed");
    }

    // =====================================================================
    // L-01: replacing a (compromised) creator manager does not invalidate its open proposals
    // =====================================================================

    /// @notice L-01 fixed: replacing the manager voids every proposal it made (manager epoch), so one admin call
    ///         neutralises a stolen manager key, however many tokens it targeted.
    function test_fixed_L01_replacingManagerVoidsItsProposals() public {
        uint256 n = 5;
        address[] memory tokens = new address[](n);
        for (uint256 i; i < n; ++i) {
            tokens[i] = _launchWith(i % 2 == 0 ? creator : creator2, TAX, 4 ether, 0);
        }
        // Stolen manager key: propose the attacker on every token.
        for (uint256 i; i < n; ++i) {
            vm.prank(creatorManager);
            vault.proposeReassign(tokens[i], attacker);
        }
        // The admin notices and rotates the manager. It cancels only some proposals in time.
        address fresh = makeAddr("freshManager");
        vm.prank(admin);
        vault.setCreatorManager(fresh);
        vm.prank(admin);
        vault.cancelReassign(tokens[0]);

        // The old manager has no power any more...
        vm.prank(creatorManager);
        vm.expectRevert(StealthFeeVault.NotCreatorManager.selector);
        vault.proposeReassign(tokens[0], attacker);

        // ...and its remaining proposals are void.
        _warpToEta(tokens[1]);
        for (uint256 i = 1; i < n; ++i) {
            vm.prank(attacker);
            vm.expectRevert(StealthFeeVault.StaleReassign.selector);
            vault.acceptReassign(tokens[i]);
            assertEq(vault.creatorOf(tokens[i]), i % 2 == 0 ? creator : creator2, "creator unchanged");
        }
        // The new manager's proposals work normally.
        vm.prank(fresh);
        vault.proposeReassign(tokens[1], team);
        _warpToEta(tokens[1]);
        vm.prank(team);
        vault.acceptReassign(tokens[1]);
        assertEq(vault.creatorOf(tokens[1]), team);
    }

    // =====================================================================
    // L-02: the launch `creator` field is unauthenticated
    // =====================================================================

    /// @notice Any launcher can name any wallet as a token's creator without that wallet's consent. The named
    ///         wallet is what `Launched.creator` (indexed topic) and `TokenRegistered` show, so a scam token can be
    ///         attributed on-chain to a well-known dev wallet. Only `StealthToken.deployer` and `Launched.launcher`
    ///         reveal the real sender.
    /// @dev Accepted by design (the platform labels tokens by launcher; social recipients are shown as "not
    ///      affiliated" until they claim). Pinned so the behaviour is explicit.
    function test_accepted_L02_launcherAttributesTokenToAnyWallet() public {
        address famousDev = makeAddr("famousDev");
        StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
        p.name = "Famous Dev Official";
        p.creator = famousDev;
        address predicted = factory.predictTokenAddress(attacker, p);

        vm.expectEmit(true, true, false, true, address(factory));
        emit Launched(predicted, famousDev, bytes32(0), attacker, address(0), "Famous Dev Official", "MKT", TAX, LaunchType.Creator, 4 ether);
        vm.prank(attacker);
        address token = factory.launch{value: 0.1 ether}(p);

        assertEq(vault.creatorOf(token), famousDev, "fees (and 'creator' attribution) go to a wallet that never signed");
        assertEq(StealthToken(token).deployer(), attacker, "only the token's deployer field shows the real launcher");
        assertEq(locker.getPool(token).launcher, attacker, "the locker records the launcher, not the fee creator");
        assertGt(IERC20(token).balanceOf(attacker), 0, "launcher holds the first-buy bag");
    }

    /// @notice I-03 fixed: the system's own contracts can never be named creator (they could never claim).
    function test_fixed_I03_systemContractsRejectedAsCreator() public {
        address[7] memory sys = [
            address(vault),
            address(locker),
            address(hook),
            address(factory),
            address(tokenDeployer),
            address(manager),
            settlementAddr
        ];
        for (uint256 i; i < sys.length; ++i) {
            StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
            p.creator = sys[i];
            vm.prank(launcher);
            vm.expectRevert(StealthFactory.InvalidCreator.selector);
            factory.launch{value: 0.05 ether}(p);
        }
    }

    // =====================================================================
    // I-01: creator claims no longer depend on marketing and platform accepting the native coin
    // =====================================================================

    /// @notice v3.1 accepted this: claims also swept, so a rejecting wallet blocked every creator. Stealth's claims pay
    ///         the claimant only, and the admin can rotate the wallets, so only sweeps can be held up.
    function test_fixed_I01_revertingWallet_cannotBlockCreatorClaims() public {
        address token = _launch(TAX, 4 ether);
        _trade(token);
        uint256 owed = vault.coinOwed(token);
        vm.etch(platform, hex"5f5ffd"); // PUSH0 PUSH0 REVERT

        vm.prank(claimer);
        vm.expectRevert();
        vault.sweep(_one(token));

        uint256 cb = creator.balance;
        vm.startPrank(creator);
        vault.claimCreatorAmount(token, 1, creator);
        vault.claimCreator(token);
        vm.stopPrank();
        assertEq(creator.balance - cb, owed, "the claim does not touch the platform wallet");
    }

    // =====================================================================
    // I-02: legacy balances cannot be redirected or partially claimed
    // =====================================================================

    /// @notice I-02 fixed: `claimLegacy(token, to)` lets a replaced creator that cannot receive ETH (or a platform
    ///         escrow) pay its legacy balance to another address.
    function test_fixed_I02_legacyCanBePaidElsewhere() public {
        NoReceiveCreator c = new NoReceiveCreator(vault);
        address token = _launchFor(launcher, address(c), 0);
        _trade(token);

        vm.expectRevert();
        c.claim(token); // cannot receive ETH

        _propose(token, team);
        _warpToEta(token);
        vm.prank(team);
        vault.acceptReassign(token);
        uint256 legacy = vault.legacyOwed(token, address(c));
        assertGt(legacy, 0);
        vm.expectRevert();
        c.claimLegacy(token); // paying itself still fails...
        address safeWallet = makeAddr("safeWallet");
        c.claimLegacyTo(token, safeWallet); // ...but it can pay elsewhere
        assertEq(safeWallet.balance, legacy);
        assertEq(vault.legacyOwed(token, address(c)), 0);
        vm.prank(creator);
        vm.expectRevert(DexBase.ZeroAddress.selector);
        vault.claimLegacy(token, address(0));
    }

    // =====================================================================
    // Attempts that failed (defences hold)
    // =====================================================================

    /// @notice A creator contract claims (whole and partial) from inside its own unlock, so the vault's `_run`
    ///         settles directly, and re-enters the vault from `receive` mid-payout. All money-moving re-entries
    ///         revert (shared transient guard); payouts and books are exact.
    function test_attempt_claimInsideOuterUnlock_andReenterMidPayout() public {
        OuterUnlockCreator c = new OuterUnlockCreator(manager, vault);
        address token = _launchFor(launcher, address(c), 0);
        _trade(token);
        uint256 owed = vault.coinOwed(token);
        uint256 m = vault.marketingOwed(token);
        uint256 p = vault.platformOwed(token);
        uint256 mb = marketing.balance;
        uint256 tb = platform.balance;

        c.go(token, owed / 3);
        assertEq(address(c).balance, owed / 3);
        assertEq(marketing.balance - mb, 0, "a claim pays the claimant only");
        assertEq(platform.balance - tb, 0);
        assertEq(vault.marketingOwed(token), m);
        assertEq(vault.platformOwed(token), p);
        assertTrue(c.reenterLegacyReverted() && c.reenterSweepReverted() && c.reenterClaimReverted());
        _assertBooks(_one(token));

        _trade(token);
        uint256 rest = vault.coinOwed(token);
        c.go(token, 0);
        assertEq(address(c).balance, owed / 3 + rest);
        _assertBooks(_one(token));
    }

    /// @notice Creator equal to marketing or platform: each payout lands, no double counting.
    function test_attempt_creatorIsMarketingOrPlatform() public {
        address t1 = _launchFor(launcher, marketing, 0);
        address t2 = _launchFor(launcher, platform, 0);
        _trade(t1);
        _trade(t2);
        uint256 c1 = vault.coinOwed(t1);
        uint256 m1 = vault.marketingOwed(t1);
        uint256 p1 = vault.platformOwed(t1);
        uint256 mb = marketing.balance;
        uint256 tb = platform.balance;
        vm.prank(marketing);
        vault.claimCreator(t1);
        assertEq(marketing.balance - mb, c1, "its creator balance, not its marketing share");
        assertEq(platform.balance - tb, 0);
        assertEq(vault.marketingOwed(t1), m1);
        assertEq(vault.platformOwed(t1), p1);
        uint256 c2 = vault.coinOwed(t2);
        uint256 m2 = vault.marketingOwed(t2);
        uint256 p2 = vault.platformOwed(t2);
        mb = marketing.balance;
        tb = platform.balance;
        vm.prank(platform);
        vault.claimCreator(t2);
        assertEq(platform.balance - tb, c2);
        assertEq(marketing.balance - mb, 0);
        assertEq(vault.marketingOwed(t2), m2);
        assertEq(vault.platformOwed(t2), p2);
        address[] memory list = new address[](2);
        list[0] = t1;
        list[1] = t2;
        _assertBooks(list);
        vm.prank(claimer);
        vault.sweep(list);
        assertEq(marketing.balance - mb, m1 + m2, "the sweep pays the shares, once");
        assertEq(platform.balance - tb, c2 + p1 + p2);
        assertEq(vault.totalOwed(NATIVE), 0);
    }

    /// @notice Launching with the creator set to a contract that rejects ETH, or to a system contract, leaves
    ///         refund and first-buy tokens with the launcher and the launch succeeds.
    function test_attempt_creatorField_doesNotAffectRefundOrFirstBuy() public {
        NoReceiveCreator c = new NoReceiveCreator(vault);
        uint256 before = launcher.balance;
        address token = _launchFor(launcher, address(c), 5 ether); // way over the 5% cap: big refund
        uint256 spent = before - launcher.balance;
        assertLt(spent, 5 ether, "refund went to the launcher");
        assertGt(IERC20(token).balanceOf(launcher), 0);
        assertEq(IERC20(token).balanceOf(address(c)), 0);
    }

    /// @notice A proposal can never be accepted by anyone but `to`, before the notice, or after the window; the
    ///         old creator cannot block or front-run it into moving money; a pending offer to `to` (not accepted)
    ///         is superseded by the takeover and the old creator keeps the backlog.
    function test_attempt_takeoverWhileOfferPendingToSameWallet() public {
        address token = _launch(TAX, 4 ether);
        _trade(token);
        _propose(token, team);
        vm.prank(creator);
        vault.offerCreator(token, team);
        uint256 backlog = vault.coinOwed(token);
        _warpToEta(token);
        vm.prank(team);
        vault.acceptReassign(token); // team picks the takeover, not the voluntary offer
        assertEq(vault.pendingCreator(token), address(0));
        assertEq(vault.legacyOwed(token, creator), backlog);
        vm.prank(team);
        vm.expectRevert(StealthFeeVault.NotPendingCreator.selector);
        vault.acceptCreator(token); // the stale offer cannot be replayed
    }

    /// @notice The replaced creator cannot use a stale voluntary offer, or re-enter the role, after a takeover;
    ///         a later voluntary hand-off from the new creator moves only coinOwed, never legacy.
    function test_attempt_legacyAndCurrentAreSeparate() public {
        address token = _launch(TAX, 4 ether);
        _trade(token);
        uint256 first = vault.coinOwed(token);
        _propose(token, team);
        _warpToEta(token);
        vm.prank(team);
        vault.acceptReassign(token);
        _trade(token);
        uint256 teamOwed = vault.coinOwed(token);
        // Team hands the role back to the old creator voluntarily.
        vm.prank(team);
        vault.offerCreator(token, creator);
        vm.prank(creator);
        vault.acceptCreator(token);
        assertEq(vault.coinOwed(token), teamOwed, "voluntary hand-off moves the current share");
        assertEq(vault.legacyOwed(token, creator), first, "legacy untouched");
        uint256 cb = creator.balance;
        vm.startPrank(creator);
        vault.claimCreator(token);
        vault.claimLegacy(token, creator);
        vm.stopPrank();
        assertEq(creator.balance - cb, first + teamOwed);
        _assertBooks(_one(token));
        vm.prank(claimer);
        vault.sweep(_one(token));
        assertEq(vault.totalOwed(NATIVE), 0);
    }

    /// @notice Repeated 1-wei partial claims: no rounding, books exact, and the final claim empties the share.
    function test_attempt_partialClaimDust() public {
        address token = _launch(TAX, 4 ether);
        _trade(token);
        uint256 owed = vault.coinOwed(token);
        vm.startPrank(creator);
        for (uint256 i; i < 5; ++i) {
            vault.claimCreatorAmount(token, 1, creator);
        }
        vault.claimCreatorAmount(token, owed - 5, creator);
        vm.expectRevert(StealthFeeVault.NothingToClaim.selector);
        vault.claimCreator(token);
        vm.stopPrank();
        assertEq(vault.creatorClaimed(token), owed);
        _assertBooks(_one(token));
    }

    /// @notice Expired proposals: cannot be accepted, linger in storage until replaced or cancelled, and can still
    ///         be cancelled after expiry (the spec says "while a proposal is open"; harmless).
    function test_attempt_expiredProposal() public {
        address token = _launch(TAX, 4 ether);
        _propose(token, team);
        (, uint64 eta,) = vault.reassignment(token);
        vm.warp(uint256(eta) + 7 days + 1);
        vm.prank(team);
        vm.expectRevert(StealthFeeVault.ReassignExpired.selector);
        vault.acceptReassign(token);
        (address to,,) = vault.reassignment(token);
        assertEq(to, team, "stale proposal still readable: UIs must check the window");
        vm.prank(admin);
        vault.cancelReassign(token);
        _propose(token, team);
        _warpToEta(token);
        vm.prank(team);
        vault.acceptReassign(token);
        assertEq(vault.creatorOf(token), team);
    }

    /// @notice I-04 fixed: a takeover that clears a pending voluntary offer emits CreatorOffered(token, from, 0)
    ///         before CreatorReassigned, and a legacy payout is its own role.
    function test_fixed_I04_takeoverEvents_forIndexers() public {
        address token = _launch(TAX, 4 ether);
        vm.prank(creator);
        vault.offerCreator(token, makeAddr("friend"));
        _propose(token, team);
        _warpToEta(token);
        vm.recordLogs();
        vm.prank(team);
        vault.acceptReassign(token);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[0], StealthFeeVault.CreatorOffered.selector);
        assertEq(logs[0].topics[3], bytes32(0), "offer cancelled");
        assertEq(logs[1].topics[0], StealthFeeVault.CreatorReassigned.selector);
        assertEq(vault.pendingCreator(token), address(0));
    }

    /// @notice I-05 fixed: the caller is checked first.
    function test_fixed_I05_errorOrder_claimCreatorAmount() public {
        address token = _launch(TAX, 4 ether);
        _trade(token);
        uint256 owed = vault.coinOwed(token);
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreatorAmount(token, owed + 1, attacker);
        vm.prank(creator);
        vm.expectRevert(DexBase.ZeroAddress.selector);
        vault.claimCreatorAmount(token, 1, address(0));
    }
}
