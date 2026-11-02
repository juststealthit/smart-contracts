// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DexBase, DexCallback, IDexManager, Currency} from "@dex/Dex.sol";
import {DexTestLib} from "@dex/DexTest.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {LaunchType} from "../../src/interfaces/IStealth.sol";

/// @notice Mints an ERC-6909 native claim straight to any address (here: the fee vault), paying for it with its own native.
contract ClaimDonor is DexCallback {
    constructor(IDexManager manager_) DexBase(manager_) {}

    function donate(address to) external payable {
        _lockRaw(abi.encode(to, msg.value));
    }

    function _onLock(bytes calldata data) internal override returns (bytes memory) {
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        _settleNative(amount);
        _mintClaim(to, Currency.wrap(address(0)), amount);
        return "";
    }
}

contract PlainToken is ERC20 {
    constructor() ERC20("Plain", "PLN") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @notice A flash-accounting caller (router / smart wallet) that has a pending ERC-20 `sync` + payment open when it
///         calls `StealthFactory.launch` inside its own unlock.
contract SyncThenLaunch is DexCallback {
    StealthFactory public immutable factory;
    IERC20 public immutable erc20;
    StealthFactory.LaunchParams internal _params;
    uint256 public paidAfterLaunch;
    address public syncedAfterLaunch;

    constructor(IDexManager manager_, StealthFactory factory_, IERC20 erc20_) DexBase(manager_) {
        factory = factory_;
        erc20 = erc20_;
    }

    function go(StealthFactory.LaunchParams calldata p) external payable {
        _params = p;
        _lockRaw(abi.encode(msg.value));
    }

    function _onLock(bytes calldata data) internal override returns (bytes memory) {
        // Pay 100 PLN into the settlement contract the canonical way: sync, transfer, (settle later).
        _sync(Currency.wrap(address(erc20)));
        erc20.transfer(address(settlement), 100e18);
        factory.launch{value: abi.decode(data, (uint256))}(_params);
        syncedAfterLaunch = Currency.unwrap(DexTestLib.syncedCurrency(poolManager));
        paidAfterLaunch = _settle(); // credits whatever the settlement contract thinks was paid
        if (paidAfterLaunch != 0) _take(Currency.wrap(address(erc20)), address(this), paidAfterLaunch);
        return "";
    }

    receive() external payable {}
}

/// @notice Proofs of concept for the findings in REVIEW.md. Each test PASSES when the issue is present.
contract ReviewFindingsTest is BaseTest {
    // ---------------------------------------------------------------------
    // L-01: the vault's claim balance can be pushed above totalOwed by anyone; the excess is stranded forever
    //       and the spec's "claims == owed, to the wei" invariant (and any monitor built on it) breaks.
    // ---------------------------------------------------------------------

    function test_poc_L01_anyoneCanGiftClaims_skimRecoversThem() public {
        address token = _launch(TAX, 4 ether);
        _buy(traders[0], token, 1 ether);
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "exact before");

        // 1 wei is enough; no permission needed.
        ClaimDonor donor = new ClaimDonor(manager);
        vm.prank(attacker);
        donor.donate{value: 1}(address(vault));
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE) + 1, "claims != owed: spec invariant 9.1 broken");

        // A plain ERC-6909 transfer does the same (attacker already holds a claim).
        vm.prank(attacker);
        donor.donate{value: 5}(attacker);
        vm.prank(attacker);
        _dexTransferClaims(address(vault), NATIVE, 5);
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE) + 6);

        // Pay everybody everything; the 6 wei are the only thing left.
        vm.prank(creator);
        vault.claimCreator(token);
        vault.sweep(_one(token));
        assertEq(vault.totalOwed(NATIVE), 0, "nothing owed");
        assertEq(_vaultClaims(), 6, "6 wei of excess claims");

        // Fix: anyone can skim the excess to the platform, and only the excess.
        uint256 tb = platform.balance;
        vm.prank(attacker);
        (uint256 claims,) = vault.skim(NATIVE);
        assertEq(claims, 6);
        assertEq(platform.balance - tb, 6, "the gift goes to the platform");
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "exact again");
    }

    // ---------------------------------------------------------------------
    // I-01: launch inside an outer unlock with a pending ERC-20 sync
    // ---------------------------------------------------------------------

    /// @notice v3 reverted here (the vault deposited the launch fee with `settle{value}` on top of the caller's
    ///         pending ERC-20 sync). Here the launch fee goes straight to the platform and the locker syncs
    ///         before every settle, so a launch with a fee and a first buy succeeds inside such a lock; the caller's
    ///         own pending sync is still clobbered (I-01b), which only hurts the caller.
    function test_poc_I01a_pendingSync_plusLaunchFee_launchStillWorks() public {
        vm.prank(admin);
        factory.setLaunchFee(0.01 ether);
        _syncConfig();
        PlainToken pln = new PlainToken();
        SyncThenLaunch c = new SyncThenLaunch(manager, factory, IERC20(address(pln)));
        pln.transfer(address(c), 1_000e18);
        vm.deal(address(c), 1 ether);
        c.go{value: 0.06 ether}(_params(TAX, 4 ether, 0));
        assertEq(c.syncedAfterLaunch(), address(0), "pending sync reset by the launch");
        assertEq(pln.balanceOf(settlementAddr), 100e18, "the caller's 100 PLN stranded in the settlement contract");
    }

    /// @notice Without a launch fee the launch succeeds, but the locker's own `sync(token)`/`sync(ETH)` silently
    ///         wipes the caller's pending sync: the 100 PLN it had already transferred can no longer be settled
    ///         and stays in the settlement contract, credited to nobody.
    function test_poc_I01b_pendingSync_silentlyClobberedByLauncher() public {
        PlainToken pln = new PlainToken();
        SyncThenLaunch c = new SyncThenLaunch(manager, factory, IERC20(address(pln)));
        pln.transfer(address(c), 1_000e18);
        c.go(_params(TAX, 4 ether, 0));
        assertEq(c.syncedAfterLaunch(), address(0), "pending sync reset by the launch");
        assertEq(c.paidAfterLaunch(), 0, "caller's 100 PLN payment was never credited");
        assertEq(pln.balanceOf(settlementAddr), 100e18, "100 PLN stranded in the settlement contract");
    }

    // ---------------------------------------------------------------------
    // I-02: sweep is all-or-nothing across both fixed destinations
    // ---------------------------------------------------------------------

    function test_poc_I02_revertingMarketingFreezesPlatformShareToo() public {
        // Only the Marketing type has a marketing share any more: on any other coin a sweep does not call that wallet.
        address token = _launchOpts(creator, TAX, 0, _typed(LaunchType.Marketing));
        _skipSniperWindow(token);
        _buy(traders[0], token, 1 ether);
        uint256 platformOwed = vault.platformOwed(token);
        assertGt(platformOwed, 0);
        assertGt(vault.marketingOwed(token), 0);
        // The marketing wallet turns out to be a contract that cannot receive native.
        vm.etch(marketing, hex"5f5ffd"); // PUSH0 PUSH0 REVERT
        vm.expectRevert();
        vault.sweep(_one(token));
        assertEq(vault.platformOwed(token), platformOwed, "platform can't be paid either");
        // New with Stealth's wallet rotation: the admin can get out of it, and nobody's money moved.
        address fresh = makeAddr("freshMarketing");
        vm.prank(admin);
        vault.setWallets(platform, fresh);
        vault.sweep(_one(token));
        assertEq(vault.platformOwed(token), 0, "paid after the rotation");
        assertGt(fresh.balance, 0);
    }

    /// @notice A coin with no marketing share never touches the marketing wallet, so it cannot be held up by it.
    function test_revertingMarketing_cannotFreezeACoinWithNoMarketingShare() public {
        address token = _launch(TAX, 4 ether);
        _buy(traders[0], token, 1 ether);
        vm.etch(marketing, hex"5f5ffd"); // PUSH0 PUSH0 REVERT
        vault.sweep(_one(token));
        assertEq(vault.platformOwed(token), 0, "the platform is paid");
    }

    // ---------------------------------------------------------------------
    // I-03: the creator gets the coin's 70% of the tier back, including on its own trades and its first buy. In the
    //       source engine that was half the fee (half of a 99% sniper fee); here it is 70% of the tier at any rate, so
    //       self-sniping does not pay.
    // ---------------------------------------------------------------------

    function test_poc_I03_creatorGetsBackOnlyItsCoinPart_onItsOwnTrades() public {
        // First buy inside the launch transaction at the 5.75% tier.
        vm.prank(creator);
        address token = factory.launch{value: 0.05 ether}(_params(575, 4 ether, 0)); // under the 5% cap
        uint256 feeFirstBuy = _vaultClaims();
        assertEq(feeFirstBuy, 0.002875 ether, "5.75% of 0.05 native");
        uint256 before = creator.balance;
        vm.prank(creator);
        vault.claimCreator(token);
        assertEq(creator.balance - before, 0.0020125 ether, "4.025% of the first buy comes back");

        // Inside the sniper window from a second wallet the creator controls: 90% nominal, 85.975% effective.
        address alt = makeAddr("creatorAlt");
        vm.deal(alt, 1 ether);
        _buy(alt, token, 1 ether);
        before = creator.balance;
        vm.prank(creator);
        vault.claimCreator(token);
        assertEq(creator.balance - before, 0.04025 ether, "creator recovers 70% of the tier, not half the fee");
    }

    // ---------------------------------------------------------------------
    // I-04 (carried from v2 L-01): the one-way `graduated` flag can be flash-touched; for the creator the
    //       round trip costs the fees less the 70% of the tier that comes back on each leg.
    // ---------------------------------------------------------------------

    function test_poc_I04_creatorFlashGraduatesForThirtyPercentOfTheFees() public {
        address t = _launch(125, 4 ether);
        StealthLocker.PoolInfo memory info = locker.getPool(t);
        uint256 budget = info.graduationQuote * 102 / 100;
        vm.deal(creator, budget);
        uint256 start = creator.balance;
        _buy(creator, t, budget);
        _sell(creator, t, IERC20(t).balanceOf(creator));
        assertTrue(hook.graduated(t), "flag set forever");
        vm.prank(creator);
        vault.claimCreator(t);
        uint256 cost = start - creator.balance;
        emit log_named_decimal_uint("creator's net cost to flip graduated on a 4 native / 1.25% token (native)", cost, 18);
        assertGt(cost, info.graduationQuote * 70 / 10_000, "about 0.6 x fee x target");
        assertLt(cost, info.graduationQuote * 80 / 10_000, "about 0.6 x fee x target, not 2x");
    }
}
