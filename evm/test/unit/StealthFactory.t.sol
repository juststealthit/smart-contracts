// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthHook} from "../../src/StealthHook.sol";
import {StealthConstants as C} from "../../src/libraries/StealthConstants.sol";
import {LaunchType, TeamShare} from "../../src/interfaces/IStealth.sol";
import {StealthDeploy} from "../../script/lib/StealthDeploy.sol";
import {RejectingCreator} from "../utils/Harnesses.sol";

contract StealthFactoryTest is BaseTest {
    event ConfigChanged(bytes32 indexed key, uint256 oldValue, uint256 newValue);
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

    // ---------------------------------------------------------------------
    // Launch
    // ---------------------------------------------------------------------

    function test_launch_storesSnapshot() public {
        address token = _launchWith(creator, TAX, 5 ether, 0);
        StealthLocker.PoolInfo memory info = locker.getPool(token);
        assertEq(info.launcher, creator);
        assertEq(info.taxBps, TAX);
        assertEq(info.target, 5 ether);
        assertEq(info.launchTime, block.timestamp);
        StealthHook.PoolConfig memory cfg = hook.getConfig(token);
        assertEq(cfg.taxFee, TAX_PIPS);
        assertEq(hook.sniperWindowEnd(token), block.timestamp + 15);
        assertEq(hook.currentFee(token), 900_000, "opens at the sniper fee");
        assertEq(cfg.launchTime, block.timestamp);
        assertEq(vault.creatorOf(token), creator);
        assertEq(_sqrtPrice(token), info.startSqrtPriceX96, "pool opens at the start price");
    }

    function test_launch_emitsLaunched_andPredictsAddress() public {
        StealthFactory.LaunchParams memory p = _params(325, 4 ether, 0);
        address predicted = factory.predictTokenAddress(creator, p);
        vm.expectEmit(true, true, false, true, address(factory));
        emit Launched(
            predicted, creator, bytes32(0), creator, address(0), "Stealth Test", "MKT", 325, LaunchType.Creator, 4 ether
        );
        address token = _launchWith(creator, 325, 4 ether, 0);
        assertEq(token, predicted, "CREATE2 address known before launch");
    }

    function test_launch_nonceMakesAddressesUnique() public {
        address a = _launchWith(creator, 325, 4 ether, 0);
        address b = _launchWith(creator, 325, 4 ether, 0);
        assertTrue(a != b);
        assertEq(factory.launchNonce(creator), 2);
    }

    function test_revert_launch_paused() public {
        vm.prank(admin);
        factory.setLaunchesPaused(true);
        vm.expectRevert(StealthFactory.LaunchesPaused.selector);
        factory.launch(_params(325, 4 ether, 0));
    }

    function test_revert_launch_badStrings() public {
        StealthFactory.LaunchParams memory p = _params(325, 4 ether, 0);
        p.name = "";
        vm.expectRevert(StealthFactory.InvalidName.selector);
        factory.launch(p);
        p.name = string(new bytes(C.MAX_NAME_LENGTH + 1));
        vm.expectRevert(StealthFactory.InvalidName.selector);
        factory.launch(p);
        p.name = "ok";
        p.symbol = "";
        vm.expectRevert(StealthFactory.InvalidSymbol.selector);
        factory.launch(p);
        p.symbol = string(new bytes(C.MAX_SYMBOL_LENGTH + 1));
        vm.expectRevert(StealthFactory.InvalidSymbol.selector);
        factory.launch(p);
        p.symbol = "OK";

        p.logo = string(new bytes(C.MAX_LOGO_LENGTH + 1));
        vm.expectRevert(StealthFactory.InvalidMetadata.selector);
        factory.launch(p);
        p.logo = "";
        p.description = string(new bytes(C.MAX_DESCRIPTION_LENGTH + 1));
        vm.expectRevert(StealthFactory.InvalidMetadata.selector);
        factory.launch(p);
        p.description = "";
        string memory longSocial = string(new bytes(C.MAX_SOCIAL_LENGTH + 1));
        for (uint256 i; i < 5; ++i) {
            StealthFactory.LaunchParams memory q = _params(325, 4 ether, 0);
            if (i == 0) q.socials.twitter = longSocial;
            if (i == 1) q.socials.telegram = longSocial;
            if (i == 2) q.socials.discord = longSocial;
            if (i == 3) q.socials.website = longSocial;
            if (i == 4) q.socials.farcaster = longSocial;
            vm.expectRevert(StealthFactory.InvalidMetadata.selector);
            factory.launch(q);
        }
        // Everything at the limit is fine.
        p.name = string(new bytes(C.MAX_NAME_LENGTH));
        p.symbol = string(new bytes(C.MAX_SYMBOL_LENGTH));
        p.logo = string(new bytes(C.MAX_LOGO_LENGTH));
        p.description = string(new bytes(C.MAX_DESCRIPTION_LENGTH));
        factory.launch(p);
    }

    function test_revert_launch_taxNotATier() public {
        uint16[8] memory notTiers = [uint16(1), 100, 124, 126, 300, 500, 576, 1000];
        for (uint256 i; i < notTiers.length; ++i) {
            vm.expectRevert(StealthFactory.InvalidTax.selector);
            factory.launch(_params(notTiers[i], 4 ether, 0));
        }
    }

    function test_launch_everyTier_andTheDefault() public {
        uint16[5] memory tiers = [uint16(125), 225, 325, 425, 575];
        for (uint256 i; i < tiers.length; ++i) {
            address token = factory.launch(_params(tiers[i], 4 ether, 0));
            assertEq(hook.getConfig(token).taxFee, uint24(tiers[i]) * 100);
            assertEq(locker.getPool(token).taxBps, tiers[i]);
        }
        address byDefault = factory.launch(_params(0, 4 ether, 0));
        assertEq(hook.getConfig(byDefault).taxFee, 12_500, "no tier named: 1.25%");
    }

    function test_revert_launch_targetOutOfRange() public {
        vm.expectRevert(StealthFactory.InvalidTarget.selector);
        factory.launch(_params(325, 4 ether - 1, 0));
        vm.expectRevert(StealthFactory.InvalidTarget.selector);
        factory.launch(_params(325, 10 ether + 1, 0));
        factory.launch(_params(325, 4 ether, 0));
        factory.launch(_params(325, 10 ether, 0));
    }

    /// @dev Launch fees are native whatever the quote, and go straight to the platform (v3 held them as a claim).
    function test_launchFee_paidToPlatform() public {
        vm.prank(admin);
        factory.setLaunchFee(0.01 ether);
        _syncConfig();
        vm.prank(creator);
        vm.expectRevert(StealthFactory.InsufficientLaunchFee.selector);
        factory.launch{value: 0.01 ether - 1}(_params(325, 4 ether, 0));

        uint256 tb = platform.balance;
        address token = _launchWith(creator, 325, 4 ether, 0.01 ether);
        assertEq(platform.balance - tb, 0.01 ether, "paid to the platform in the launch");
        assertEq(vault.launchFeePaid(token), 0.01 ether);
        assertEq(vault.platformOwed(token), 0, "not booked as a trading fee");
        assertEq(_vaultClaims(), 0, "nothing held");
        assertEq(address(vault).balance, 0);
    }

    function test_revert_launchFee_platformRejects() public {
        vm.prank(admin);
        factory.setLaunchFee(0.01 ether);
        _syncConfig();
        vm.etch(platform, hex"fe"); // platform that rejects native
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSignature("LaunchFeeFailed()"));
        factory.launch{value: 0.01 ether}(_params(325, 4 ether, 0));
    }

    function test_revert_nativeLaunchWithQuoteAmount() public {
        StealthFactory.LaunchParams memory p = _params(325, 4 ether, 0);
        p.quoteAmount = 1;
        vm.expectRevert(StealthFactory.InvalidValue.selector);
        factory.launch(p);
    }

    // ---------------------------------------------------------------------
    // First buy
    // ---------------------------------------------------------------------

    function test_devBuy_underCap_matchesQuote() public {
        (uint256 quotedTokens, uint256 quotedEth) = locker.quoteLaunchBuy(4 ether, 325, 0.05 ether);
        assertEq(quotedEth, 0.05 ether, "all native used under the cap");
        uint256 before = creator.balance;
        address token = _launchWith(creator, 325, 4 ether, 0.05 ether);
        assertEq(IERC20(token).balanceOf(creator), quotedTokens, "tokens match the quote");
        assertEq(before - creator.balance, 0.05 ether);
    }

    function test_devBuy_overCap_refundsToCreator() public {
        (uint256 quotedTokens, uint256 quotedEth) = locker.quoteLaunchBuy(4 ether, 325, 3 ether);
        assertLe(quotedTokens, C.LAUNCH_ALLOWANCE);
        assertApproxEqRel(quotedTokens, C.LAUNCH_ALLOWANCE, 1e12, "capped at 5% of supply");
        uint256 before = creator.balance;
        address token = _launchWith(creator, 325, 4 ether, 3 ether);
        assertEq(IERC20(token).balanceOf(creator), quotedTokens, "exact quote at the cap too");
        assertEq(before - creator.balance, quotedEth, "only the native for 5% was kept");
        assertFalse(hook.graduated(token), "a first buy never graduates");
        // 5% costs about 1.6% of the target, plus the fee.
        assertApproxEqRel(quotedEth, uint256(4 ether) * 50 / 3050 * 10_000 / 9_675, 1e16);
    }

    function test_devBuy_paysCreatorFeeNotSniperFee() public {
        _launchWith(creator, 575, 4 ether, 0.02 ether);
        // 5.75% of 0.02 native, not 90%, credited to the vault in the launch transaction.
        assertEq(_vaultClaims(), 0.00115 ether);
    }

    function test_revert_devBuy_slippage() public {
        vm.prank(creator);
        vm.expectRevert(StealthLocker.Slippage.selector);
        factory.launch{value: 10 ether}(_params(325, 4 ether, C.LAUNCH_ALLOWANCE + 1));
    }

    function test_revert_devBuy_dust() public {
        // 1 wei: the fee takes it all, so nothing would be bought. The launch refuses rather than charge for nothing.
        vm.prank(creator);
        vm.expectRevert(StealthLocker.ZeroAmount.selector);
        factory.launch{value: 1}(_params(325, 4 ether, 0));
    }

    function test_devBuy_creatorCannotReceiveRefund_revertsWholeLaunch() public {
        RejectingCreator rc = new RejectingCreator();
        vm.deal(address(rc), 10 ether);
        vm.expectRevert();
        rc.launch(factory, _params(325, 4 ether, 0), 5 ether);
        assertEq(address(rc).balance, 10 ether);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function test_revert_settersNotAdmin() public {
        vm.startPrank(attacker);
        vm.expectRevert(StealthFactory.NotAdmin.selector);
        factory.setTargetRange(4 ether, 4 ether, 10 ether);
        vm.expectRevert(StealthFactory.NotAdmin.selector);
        factory.listQuote(address(0), 0, 0, 0);
        vm.expectRevert(StealthFactory.NotAdmin.selector);
        factory.delistQuote(address(0));
        vm.expectRevert(StealthFactory.NotAdmin.selector);
        factory.setUnlistedQuotesAllowed(true);
        vm.expectRevert(StealthFactory.NotAdmin.selector);
        factory.setLaunchFee(0);
        vm.expectRevert(StealthFactory.NotAdmin.selector);
        factory.setLaunchesPaused(true);
        vm.expectRevert(StealthFactory.NotAdmin.selector);
        factory.proposeAdmin(attacker);
        vm.stopPrank();
    }

    function test_revert_settersPastHardCaps() public {
        vm.startPrank(admin);
        vm.expectRevert(StealthFactory.OutOfRange.selector);
        factory.setTargetRange(4 ether - 1, 4 ether, 10 ether);
        vm.expectRevert(StealthFactory.OutOfRange.selector);
        factory.setTargetRange(4 ether, 4 ether, 10 ether + 1);
        vm.expectRevert(StealthFactory.OutOfRange.selector);
        factory.setTargetRange(5 ether, 4 ether, 10 ether);
        vm.expectRevert(StealthFactory.OutOfRange.selector);
        factory.setLaunchFee(0.1 ether + 1);
        vm.stopPrank();
    }

    /// @notice The tiers and the sniper fee are constants: the admin has no function that could move them.
    function test_tiersAndSniperFeeHaveNoSetter() public {
        bytes[3] memory calls = [
            abi.encodeWithSignature("setTaxRange(uint16,uint16)", 100, 1000),
            abi.encodeWithSignature("setSniperTax(uint16)", 9000),
            abi.encodeWithSignature("setSniperWindow(uint16)", 0)
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(admin);
            (bool ok,) = address(factory).call(calls[i]);
            assertFalse(ok, "no such setter");
        }
    }

    function test_settersEmitOldAndNew() public {
        vm.startPrank(admin);
        vm.expectEmit(true, false, false, true, address(factory));
        emit ConfigChanged("launchFee", 0, 0.05 ether);
        factory.setLaunchFee(0.05 ether);
        vm.expectEmit(true, false, false, true, address(factory));
        emit ConfigChanged("minTarget", 4 ether, 5 ether);
        vm.expectEmit(true, false, false, true, address(factory));
        emit ConfigChanged("defaultTarget", 4 ether, 6 ether);
        vm.expectEmit(true, false, false, true, address(factory));
        emit ConfigChanged("maxTarget", 10 ether, 9 ether);
        factory.setTargetRange(5 ether, 6 ether, 9 ether);
        vm.stopPrank();
        StealthFactory.Config memory cfg = factory.config();
        assertEq(cfg.launchFee, 0.05 ether);
        assertEq(cfg.defaultTarget, 6 ether);
        assertEq(cfg.minTarget, 5 ether);
        assertEq(cfg.maxTarget, 9 ether);
    }

    function test_configChangeAppliesToNextLaunchOnly() public {
        address before = _launch(325, 4 ether);
        StealthLocker.PoolInfo memory snap = locker.getPool(before);
        StealthHook.PoolConfig memory hookSnap = hook.getConfig(before);

        vm.startPrank(admin);
        factory.setLaunchFee(0.05 ether);
        factory.setTargetRange(6 ether, 6 ether, 8 ether);
        vm.stopPrank();
        _syncConfig();

        assertEq(abi.encode(locker.getPool(before)), abi.encode(snap), "live pool untouched");
        assertEq(abi.encode(hook.getConfig(before)), abi.encode(hookSnap), "live fees untouched");
        uint256 c0 = _vaultClaims();
        _buy(traders[0], before, 0.1 ether);
        assertEq(hook.currentFee(before), 32_500, "still the tier its launcher chose");
        assertEq(_vaultClaims() - c0, 0.00325 ether);

        address next = _launchWith(creator2, 425, 6 ether, 0.05 ether);
        StealthLocker.PoolInfo memory info = locker.getPool(next);
        assertEq(info.target, 6 ether);
        assertEq(info.taxBps, 425);
        assertEq(vault.launchFeePaid(next), 0.05 ether);
    }

    /// @notice A launch names the config version it saw, so the admin can't change its terms between signing and
    ///         execution.
    function test_revert_launch_staleConfig() public {
        StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
        vm.prank(admin);
        factory.setLaunchFee(0.01 ether);
        vm.expectRevert(StealthFactory.StaleConfig.selector);
        factory.launch{value: 0.01 ether}(p);
    }

    // ---------------------------------------------------------------------
    // Launch options
    // ---------------------------------------------------------------------

    function test_revert_launchOptions_team() public {
        StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
        // Team coins need 2-10 wallets.
        p.options.launchType = LaunchType.Team;
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        p.options.team = new TeamShare[](1);
        p.options.team[0] = TeamShare(traders[0], 10_000);
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        p.options.team = new TeamShare[](11);
        for (uint256 i; i < 11; ++i) {
            p.options.team[i] = TeamShare(address(uint160(i + 1)), i == 0 ? 9_000 : 100);
        }
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        // Bps must sum to 10,000, none zero, no wallet twice, no zero wallet.
        p.options.team = new TeamShare[](2);
        p.options.team[0] = TeamShare(traders[0], 6_000);
        p.options.team[1] = TeamShare(traders[1], 3_999);
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        p.options.team[0] = TeamShare(traders[0], 10_000);
        p.options.team[1] = TeamShare(traders[1], 0);
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        p.options.team[0] = TeamShare(traders[0], 6_000);
        p.options.team[1] = TeamShare(traders[0], 4_000);
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        p.options.team[1] = TeamShare(address(0), 4_000);
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        // A system contract could never claim.
        p.options.team[1] = TeamShare(address(vault), 4_000);
        vm.expectRevert(StealthFactory.InvalidCreator.selector);
        factory.launch(p);
        // A team list on another type is refused, not ignored.
        p.options.team[1] = TeamShare(traders[1], 4_000);
        p.options.launchType = LaunchType.Creator;
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        p.options.launchType = LaunchType.Team;
        factory.launch(p);
    }

    function test_revert_launchOptions_limits() public {
        StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
        p.options.maxWalletBps = 49;
        p.options.limitsWindow = 60;
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        p.options.maxWalletBps = 501;
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        p.options.maxWalletBps = 0;
        p.options.maxBuyBps = 9;
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        p.options.maxBuyBps = 501;
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        p.options.maxBuyBps = 100;
        p.options.limitsWindow = 0;
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        p.options.limitsWindow = 3601;
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        p.options.maxBuyBps = 0;
        p.options.limitsWindow = 60; // a window with no limit
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
        p.options.limitsWindow = 0;
        p.options.firstBuyLock = 90 days + 1;
        vm.expectRevert(StealthFactory.InvalidOptions.selector);
        factory.launch(p);
    }

    function test_adminTransferIsTwoStep() public {
        vm.prank(admin);
        factory.proposeAdmin(creator2);
        assertEq(factory.admin(), admin, "proposal alone changes nothing");
        vm.prank(attacker);
        vm.expectRevert(StealthFactory.NotPendingAdmin.selector);
        factory.acceptAdmin();
        vm.prank(creator2);
        factory.acceptAdmin();
        assertEq(factory.admin(), creator2);
        assertEq(factory.pendingAdmin(), address(0));
        vm.prank(admin);
        vm.expectRevert(StealthFactory.NotAdmin.selector);
        factory.setLaunchesPaused(true);
    }

    function test_adminProposalCanBeCancelled() public {
        vm.startPrank(admin);
        factory.proposeAdmin(creator2);
        factory.proposeAdmin(address(0));
        vm.stopPrank();
        vm.prank(creator2);
        vm.expectRevert(StealthFactory.NotPendingAdmin.selector);
        factory.acceptAdmin();
    }

    function test_pauseOnlyAffectsNewLaunches() public {
        address token = _launch(325, 4 ether);
        vm.prank(admin);
        factory.setLaunchesPaused(true);
        uint256 got = _buy(traders[0], token, 1 ether);
        _sell(traders[0], token, got);
        _graduate(token, traders[1]);
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    function test_revert_constructorBounds() public {
        StealthFactory.Config memory cfg = StealthDeploy.config(4 ether, 4 ether, 10 ether);
        address l = address(locker);
        address v = address(vault);
        address d = address(tokenDeployer);
        vm.expectRevert(StealthFactory.InvalidBounds.selector);
        new StealthFactory(admin, l, v, d, C.MIN_TARGET_FLOOR - 1, 10 ether, cfg);
        vm.expectRevert(StealthFactory.InvalidBounds.selector);
        new StealthFactory(admin, l, v, d, 4 ether, C.MAX_TARGET_CEILING + 1, cfg);
        vm.expectRevert(StealthFactory.InvalidBounds.selector);
        new StealthFactory(admin, l, v, d, 10 ether, 4 ether, cfg);
        vm.expectRevert(StealthFactory.ZeroAddress.selector);
        new StealthFactory(address(0), l, v, d, 4 ether, 10 ether, cfg);
        vm.expectRevert(StealthFactory.WiringMismatch.selector);
        new StealthFactory(admin, l, v, d, 4 ether, 10 ether, cfg);
    }
}
