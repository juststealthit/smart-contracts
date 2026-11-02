// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DexBase, DexCallback, IDexManager, Currency} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";
import {LaunchType, TeamShare} from "../../src/interfaces/IStealth.sol";

/// @dev Sends ETH by self-destructing, bypassing any receive.
contract ForceSender {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

/// @dev Creator wallet that tries to claim again while being paid.
contract ReentrantCreator {
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

    function claim(address token_) external returns (uint256) {
        return vault.claimCreator(token_);
    }

    receive() external payable {
        if (reenter) {
            reenter = false;
            vault.claimCreator(token);
        }
    }
}

/// @dev Calls the fee vault from inside its own settlement lock.
contract LockedCaller is DexCallback {
    StealthFeeVault internal immutable vault;

    constructor(IDexManager manager_, StealthFeeVault vault_) DexBase(manager_) {
        vault = vault_;
    }

    function sweepInside(address[] calldata tokens) external {
        _lockRaw(abi.encode(tokens));
    }

    function _onLock(bytes calldata data) internal override returns (bytes memory) {
        vault.sweep(abi.decode(data, (address[])));
        return "";
    }
}

contract FeeVaultTest is BaseTest {
    event FeeCredited(address indexed token, uint256 platform, uint256 marketing, uint256 coin);
    event WalletsSet(address platform, address marketing);
    event LaunchFeePaid(address indexed token, address indexed to, uint256 amount);
    event Paid(address indexed token, StealthFeeVault.Role indexed role, address indexed to, uint256 amount);
    event CreatorOffered(address indexed token, address indexed from, address indexed to);
    event CreatorAccepted(address indexed token, address indexed to);

    address internal token;

    function setUp() public override {
        super.setUp();
        token = _launch(TAX, 4 ether);
    }

    /// @dev Real fees: trading through the pool.
    function _trade(address t) internal {
        uint256 got = _buy(traders[0], t, 1 ether);
        _sell(traders[0], t, got / 2);
    }

    function _assertBooks() internal view {
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "claims == owed");
        assertEq(address(vault).balance, 0, "no native coin held");
    }

    // ---------------------------------------------------------------------
    // Construction and wiring
    // ---------------------------------------------------------------------

    function test_wiring() public view {
        assertEq(address(vault.settlement()), settlementAddr);
        assertEq(address(vault.poolManager()), address(manager));
        assertEq(vault.platform(), platform);
        assertEq(vault.marketing(), marketing);
        assertEq(vault.hook(), address(hook));
        assertEq(vault.factory(), address(factory));
    }

    function test_revert_zeroAddresses() public {
        address h = address(hook);
        address f = address(factory);
        vm.expectRevert(DexBase.ZeroAddress.selector);
        new StealthFeeVault(IDexManager(address(0)), platform, marketing, h, f, creatorManager, distributor, 1 days);
        vm.expectRevert(DexBase.ZeroAddress.selector);
        new StealthFeeVault(manager, address(0), marketing, h, f, creatorManager, distributor, 1 days);
        vm.expectRevert(DexBase.ZeroAddress.selector);
        new StealthFeeVault(manager, platform, address(0), h, f, creatorManager, distributor, 1 days);
        vm.expectRevert(DexBase.ZeroAddress.selector);
        new StealthFeeVault(manager, platform, marketing, address(0), f, creatorManager, distributor, 1 days);
        vm.expectRevert(DexBase.ZeroAddress.selector);
        new StealthFeeVault(manager, platform, marketing, h, address(0), creatorManager, distributor, 1 days);
        vm.expectRevert(DexBase.ZeroAddress.selector);
        new StealthFeeVault(manager, platform, marketing, h, f, address(0), distributor, 1 days);
        vm.expectRevert(DexBase.ZeroAddress.selector);
        new StealthFeeVault(manager, platform, marketing, h, f, creatorManager, address(0), 1 days);
    }

    function test_revert_invalidNotice() public {
        address h = address(hook);
        address f = address(factory);
        vm.expectRevert(StealthFeeVault.InvalidNotice.selector);
        new StealthFeeVault(manager, platform, marketing, h, f, creatorManager, distributor, 0);
        vm.expectRevert(StealthFeeVault.InvalidNotice.selector);
        new StealthFeeVault(manager, platform, marketing, h, f, creatorManager, distributor, 7 days + 1);
        StealthFeeVault v = new StealthFeeVault(manager, platform, marketing, h, f, creatorManager, distributor, 7 days);
        assertEq(v.reassignNotice(), 7 days);
        assertEq(v.creatorManager(), creatorManager);
    }

    // ---------------------------------------------------------------------
    // Crediting
    // ---------------------------------------------------------------------

    function test_registerCreator_onlyFactoryOnce() public {
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotAuthorized.selector);
        vault.registerToken(address(1), attacker, NATIVE, LaunchType.Creator, new TeamShare[](0), 125);
        vm.startPrank(address(factory));
        vm.expectRevert(DexBase.ZeroAddress.selector);
        vault.registerToken(address(1), address(0), NATIVE, LaunchType.Creator, new TeamShare[](0), 125);
        vm.expectRevert(StealthFeeVault.AlreadyRegistered.selector);
        vault.registerToken(token, attacker, NATIVE, LaunchType.Creator, new TeamShare[](0), 125);
        vm.stopPrank();
        assertEq(vault.creatorOf(token), creator);
    }

    function test_credit_onlyHook() public {
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotAuthorized.selector);
        vault.credit(token, NATIVE, 1 ether, TAX_PIPS);
        vm.prank(address(locker));
        vm.expectRevert(StealthFeeVault.NotAuthorized.selector);
        vault.credit(token, NATIVE, 1 ether, TAX_PIPS);
    }

    function testFuzz_credit_splitsExactly(uint128 fee) public {
        vm.prank(address(hook));
        vault.credit(token, NATIVE, fee, TAX_PIPS);
        uint256 coin = _coinPart(fee, TAX_PIPS, TAX_PIPS);
        assertEq(vault.platformOwed(token), uint256(fee) - coin, "platform: the rest of the tier");
        assertEq(vault.marketingOwed(token), 0, "no marketing share on a Creator coin");
        assertEq(vault.coinOwed(token), coin, "the creator gets the coin's part");
        assertEq(vault.totalOwed(NATIVE), fee);
    }

    /// @dev Creator type at 4.25%: 70% of the fee is the coin's, 30% the platform's, nothing marketing's.
    function test_tradingFeesArriveAsClaimsSplitByTheTier() public {
        uint256 c0 = _vaultClaims();
        _trade(token);
        uint256 fees = _vaultClaims() - c0;
        assertGt(fees, 0);
        assertEq(vault.coinOwed(token) + vault.marketingOwed(token) + vault.platformOwed(token), fees);
        assertApproxEqAbs(vault.coinOwed(token), fees * 70 / 100, 4);
        assertEq(vault.marketingOwed(token), 0);
        assertApproxEqAbs(vault.platformOwed(token), fees * 30 / 100, 4);
        _assertBooks();
    }

    function test_creditLaunchFee_onlyFactory_paidToPlatform() public {
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotAuthorized.selector);
        vault.creditLaunchFee{value: 1 ether}(token);

        vm.prank(admin);
        factory.setLaunchFee(0.01 ether);
        _syncConfig();
        uint256 c0 = _vaultClaims();
        uint256 tb = platform.balance;
        vm.expectEmit(true, true, false, true, address(vault));
        emit LaunchFeePaid(factory.predictTokenAddress(creator2, _params(TAX, 4 ether, 0)), platform, 0.01 ether);
        vm.prank(creator2);
        address t2 = factory.launch{value: 0.01 ether}(_params(TAX, 4 ether, 0));
        assertEq(vault.launchFeePaid(t2), 0.01 ether);
        assertEq(platform.balance - tb, 0.01 ether, "the platform has it at once");
        assertEq(_vaultClaims(), c0, "no claim held for it");
        _assertBooks();

        vm.prank(address(factory));
        vault.creditLaunchFee{value: 0}(t2); // zero is a no-op
        assertEq(vault.launchFeePaid(t2), 0.01 ether);
    }

    function test_revert_credit_wrongCurrency() public {
        vm.prank(address(hook));
        vm.expectRevert(StealthFeeVault.WrongCurrency.selector);
        vault.credit(token, Currency.wrap(address(0x1234)), 1 ether, TAX_PIPS);
    }

    // ---------------------------------------------------------------------
    // Creator claims
    // ---------------------------------------------------------------------

    function test_claimCreator_paysNativeToTheCreator() public {
        _trade(token);
        uint256 owed = vault.coinOwed(token);
        uint256 before = creator.balance;
        vm.expectEmit(true, true, true, true, address(vault));
        emit Paid(token, StealthFeeVault.Role.Creator, creator, owed);
        vm.prank(creator);
        assertEq(vault.claimCreator(token), owed);
        assertEq(creator.balance - before, owed, "paid in the native coin");
        assertEq(vault.coinOwed(token), 0);
        assertEq(vault.creatorClaimed(token), owed);
        _assertBooks();

        vm.prank(creator);
        vm.expectRevert(StealthFeeVault.NothingToClaim.selector);
        vault.claimCreator(token);
    }

    function test_revert_claimCreator_notCreator() public {
        _trade(token);
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreator(token);
    }

    function test_handoff_twoStep() public {
        _trade(token);
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.offerCreator(token, attacker);

        vm.expectEmit(true, true, true, false, address(vault));
        emit CreatorOffered(token, creator, handoff);
        vm.prank(creator);
        vault.offerCreator(token, handoff);
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotPendingCreator.selector);
        vault.acceptCreator(token);

        vm.expectEmit(true, true, false, false, address(vault));
        emit CreatorAccepted(token, handoff);
        vm.prank(handoff);
        vault.acceptCreator(token);
        assertEq(vault.creatorOf(token), handoff);
        assertEq(vault.pendingCreator(token), address(0));

        vm.prank(creator);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreator(token);
        uint256 owed = vault.coinOwed(token);
        uint256 before = handoff.balance;
        vm.prank(handoff);
        vault.claimCreator(token);
        assertEq(handoff.balance - before, owed, "unclaimed fees move with the role");
    }

    function test_handoff_cancel() public {
        vm.startPrank(creator);
        vault.offerCreator(token, handoff);
        vault.offerCreator(token, address(0));
        vm.stopPrank();
        vm.prank(handoff);
        vm.expectRevert(StealthFeeVault.NotPendingCreator.selector);
        vault.acceptCreator(token);
    }

    function test_claimCreator_reentryIsBlocked() public {
        ReentrantCreator bad = new ReentrantCreator(vault);
        vm.prank(address(bad));
        address t2 = factory.launch(_params(TAX, 4 ether, 0));
        _skipSniperWindow(t2);
        _trade(t2);
        uint256 owed = vault.coinOwed(t2);
        bad.arm(t2);
        vm.expectRevert();
        bad.claim(t2);
        assertEq(vault.coinOwed(t2), owed, "nothing moved");
        _assertBooks();
    }

    // ---------------------------------------------------------------------
    // Sweep
    // ---------------------------------------------------------------------

    function test_sweep_anyonePaysTheWallets() public {
        _trade(token);
        uint256 p = vault.platformOwed(token);
        uint256 mb = marketing.balance;
        uint256 tb = platform.balance;
        uint256 ab = attacker.balance;
        assertEq(vault.marketingOwed(token), 0, "a Creator coin has no marketing share");
        vm.expectEmit(true, true, true, true, address(vault));
        emit Paid(token, StealthFeeVault.Role.Platform, platform, p);
        vm.prank(attacker);
        (uint256 mt, uint256 pt) = vault.sweep(_one(token));
        assertEq(mt, 0);
        assertEq(pt, p);
        assertEq(marketing.balance - mb, 0);
        assertEq(platform.balance - tb, p);
        assertEq(attacker.balance, ab, "the caller gets nothing");
        assertEq(vault.platformOwed(token), 0);
        assertEq(vault.marketingPaid(token), 0);
        assertEq(vault.platformPaid(token), p);
        assertGt(vault.coinOwed(token), 0, "the creator's share stays for the creator");
        _assertBooks();
    }

    function test_sweep_anyonePaysBothWalletsOnAMarketingCoin() public {
        address coin = _launchOpts(creator, TAX, 0, _typed(LaunchType.Marketing));
        _skipSniperWindow(coin);
        _trade(coin);
        uint256 m = vault.marketingOwed(coin);
        uint256 p = vault.platformOwed(coin);
        assertGt(m, 0);
        uint256 mb = marketing.balance;
        uint256 tb = platform.balance;
        uint256 ab = attacker.balance;
        vm.expectEmit(true, true, true, true, address(vault));
        emit Paid(coin, StealthFeeVault.Role.Marketing, marketing, m);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Paid(coin, StealthFeeVault.Role.Platform, platform, p);
        vm.prank(attacker);
        (uint256 mt, uint256 pt) = vault.sweep(_one(coin));
        assertEq(mt, m);
        assertEq(pt, p);
        assertEq(marketing.balance - mb, m);
        assertEq(platform.balance - tb, p);
        assertEq(attacker.balance, ab, "the caller gets nothing");
        assertEq(vault.marketingOwed(coin), 0);
        assertEq(vault.platformOwed(coin), 0);
        assertEq(vault.marketingPaid(coin), m);
        assertEq(vault.platformPaid(coin), p);
        _assertBooks();
    }

    function test_sweep_manyTokensSkipsEmptyOnesAndDuplicates() public {
        address t2 = _launch(575, 4 ether);
        address t3 = _launch(125, 4 ether); // never traded
        _trade(token);
        _trade(t2);
        address[] memory list = new address[](5);
        list[0] = token;
        list[1] = t3;
        list[2] = t2;
        list[3] = token; // already swept above in this same call
        list[4] = address(0xdead); // unknown
        uint256 expectM = vault.marketingOwed(token) + vault.marketingOwed(t2);
        uint256 expectP = vault.platformOwed(token) + vault.platformOwed(t2);
        (uint256 mt, uint256 pt) = vault.sweep(list);
        assertEq(mt, expectM);
        assertEq(pt, expectP);
        _assertBooks();
        (mt, pt) = vault.sweep(list);
        assertEq(mt + pt, 0, "nothing left: returns zero, no revert");
    }

    function test_sweep_insideAnotherLock() public {
        _trade(token);
        LockedCaller c = new LockedCaller(manager, vault);
        uint256 m = vault.marketingOwed(token);
        uint256 mb = marketing.balance;
        c.sweepInside(_one(token));
        assertEq(marketing.balance - mb, m);
        _assertBooks();
    }

    function test_skim_onlyTheExcess_toThePlatform() public {
        _trade(token);
        uint256 owed = vault.totalOwed(NATIVE);
        (uint256 c0, uint256 n0) = vault.skim(NATIVE);
        assertEq(c0 + n0, 0, "nothing to skim: owed balances are never touched");
        assertEq(_vaultClaims(), owed);

        new ForceSender{value: 0.5 ether}(payable(address(vault)));
        uint256 tb = platform.balance;
        vm.prank(attacker);
        (uint256 c1, uint256 n1) = vault.skim(NATIVE);
        assertEq(c1, 0);
        assertEq(n1, 0.5 ether, "forced native skimmed");
        assertEq(platform.balance - tb, 0.5 ether);
        assertEq(_vaultClaims(), owed, "owed untouched");
        assertEq(vault.coinOwed(token) + vault.marketingOwed(token) + vault.platformOwed(token), owed);
    }

    /// @notice A platform that refuses native makes skim revert and changes nothing.
    function test_revert_skim_platformRefusesNative() public {
        StealthFeeVault v = new StealthFeeVault(
            manager, address(tokenDeployer), marketing, address(hook), address(factory), creatorManager, distributor, 1 days
        ); // no receive()
        new ForceSender{value: 1 ether}(payable(address(v)));
        vm.expectRevert(StealthFeeVault.SkimFailed.selector);
        v.skim(NATIVE);
        assertEq(address(v).balance, 1 ether);
    }

    function test_settlementCallback_onlySettlement() public {
        bytes memory data = keccak256(bytes(DEX_NAME)) == keccak256("v4")
            ? abi.encodeWithSignature("unlockCallback(bytes)", bytes(""))
            : abi.encodeWithSignature("lockAcquired(bytes)", bytes(""));
        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(vault).call(data);
        assertFalse(ok);
        assertEq(bytes4(ret), DexCallback.NotSettlement.selector);
    }

    // ---------------------------------------------------------------------
    // Wallets
    // ---------------------------------------------------------------------

    function test_setWallets_adminOnly_nextSweepPaysTheNewWallets() public {
        _trade(token);
        address newPlatform = makeAddr("newPlatform");
        address newMarketing = makeAddr("newMarketing");
        vm.prank(attacker);
        vm.expectRevert(StealthFeeVault.NotAuthorized.selector);
        vault.setWallets(attacker, attacker);
        vm.startPrank(admin);
        vm.expectRevert(DexBase.ZeroAddress.selector);
        vault.setWallets(address(0), newMarketing);
        vm.expectRevert(DexBase.ZeroAddress.selector);
        vault.setWallets(newPlatform, address(0));
        vm.expectEmit(false, false, false, true, address(vault));
        emit WalletsSet(newPlatform, newMarketing);
        vault.setWallets(newPlatform, newMarketing);
        vm.stopPrank();
        uint256 m = vault.marketingOwed(token);
        uint256 p = vault.platformOwed(token);
        uint256 owedCoin = vault.coinOwed(token);
        vault.sweep(_one(token));
        assertEq(newMarketing.balance, m);
        assertEq(newPlatform.balance, p);
        assertEq(vault.coinOwed(token), owedCoin, "the rotation cannot touch the coin's part");
        _assertBooks();
    }

    function test_balancesView() public {
        _trade(token);
        vm.prank(creator);
        vault.claimCreator(token);
        _trade(token);
        vault.sweep(_one(token));
        (uint256 cu, uint256 mu, uint256 pu, uint256 cp, uint256 mp, uint256 pp) = vault.balances(token);
        assertEq(cu, vault.coinOwed(token));
        assertEq(mu + pu, 0);
        assertEq(cp, vault.creatorClaimed(token));
        assertEq(mp, vault.marketingPaid(token));
        assertEq(pp, vault.platformPaid(token));
        assertGt(cp, 0);
        assertGt(pp, 0);
        assertEq(mp, 0, "no marketing share on a Creator coin");

        address coin = _launchOpts(creator, TAX, 0, _typed(LaunchType.Marketing));
        _skipSniperWindow(coin);
        _trade(coin);
        (cu, mu,,, mp,) = vault.balances(coin);
        assertEq(cu, 0);
        assertGt(mu, 0);
        assertEq(mp, 0);
        vault.sweep(_one(coin));
        (,,,, mp,) = vault.balances(coin);
        assertEq(mp, vault.marketingPaid(coin));
        assertEq(mp, mu);
    }
}
