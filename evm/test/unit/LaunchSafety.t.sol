// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDexManager, PoolKey} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {TestRouter} from "../utils/TestRouter.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthHook} from "../../src/StealthHook.sol";
import {StealthToken} from "../../src/StealthToken.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthConstants as C} from "../../src/libraries/StealthConstants.sol";
import {UniversalRouterLib as UR, IUniversalRouter, IPermit2} from "@dex/UniversalRouterLib.sol";

/// @notice Buys twice in one transaction (two separate settlement locks), to test the per-transaction max buy.
contract DoubleBuyer {
    function buyTwice(TestRouter r, PoolKey calldata key, uint256 each, bool claims) external payable {
        TestRouter.TestSettings memory s = TestRouter.TestSettings({takeClaims: claims, settleUsingBurn: false});
        IDexManager.SwapParams memory p = IDexManager.SwapParams(true, int256(each), 4295128740);
        r.swap{value: address(this).balance}(key, p, s, "");
        r.swap{value: address(this).balance}(key, p, s, "");
    }

    receive() external payable {}
}

/// @notice Max wallet and max buy for the first minutes, and the launcher's first-buy lock.
contract LaunchSafetyTest is BaseTest {
    uint256 internal constant ONE_PCT = C.TOTAL_SUPPLY / 100;

    function _limits(uint16 wallet, uint16 maxBuy, uint32 window, uint32 lock)
        internal
        pure
        returns (StealthFactory.LaunchOptions memory o)
    {
        o.maxWalletBps = wallet;
        o.maxBuyBps = maxBuy;
        o.limitsWindow = window;
        o.firstBuyLock = lock;
    }

    // ---------------------------------------------------------------------
    // Max wallet
    // ---------------------------------------------------------------------

    function test_maxWallet_enforced() public {
        uint256 launchedAt = block.timestamp;
        address token = _launchOpts(creator, TAX, 0, _limits(100, 0, 30 minutes, 0)); // 1% for 30 minutes
        _skipSniperWindow(token);
        assertEq(StealthToken(token).maxWallet(), ONE_PCT);
        assertEq(StealthToken(token).limitsEnd(), launchedAt + 30 minutes);
        address t = traders[0];
        PoolKey memory key = _key(token);
        vm.prank(t);
        vm.expectRevert();
        swapRouter.swap{value: 10 ether}(
            key, IDexManager.SwapParams(true, int256(ONE_PCT + 1), MIN_PRICE_LIMIT), _settings(), ""
        );
        // Exactly 1% is fine.
        _buyExactOut(t, token, ONE_PCT, 10 ether);
        assertEq(IERC20(token).balanceOf(t), ONE_PCT);
        // Attack: pass tokens to a fresh wallet to buy again. Each wallet is still capped: topping a wallet up
        // above 1% by transfer reverts too.
        address fresh = makeAddr("fresh");
        vm.prank(t);
        IERC20(token).transfer(fresh, ONE_PCT / 2);
        _buyExactOut(t, token, ONE_PCT / 2, 10 ether);
        vm.prank(t);
        vm.expectRevert(StealthToken.MaxWalletExceeded.selector);
        IERC20(token).transfer(fresh, ONE_PCT / 2 + 1);
        // Sells to the pool are always fine; after the window the cap is gone.
        _sell(t, token, 1e18);
        vm.warp(StealthToken(token).limitsEnd());
        vm.prank(t);
        IERC20(token).transfer(fresh, ONE_PCT / 2 + 1);
        assertGt(IERC20(token).balanceOf(fresh), ONE_PCT / 2);
    }

    // ---------------------------------------------------------------------
    // Max buy per transaction (hook, pool level)
    // ---------------------------------------------------------------------

    /// @dev Each forge test function runs as one transaction, and the cap counts per transaction (transient
    ///      storage), so each case gets its own test.
    function _maxBuyToken() internal returns (address token, uint256 cap) {
        token = _launchOpts(creator, TAX, 0, _limits(0, 50, 10 minutes, 0)); // 0.5% per transaction
        _skipSniperWindow(token);
        cap = C.TOTAL_SUPPLY * 50 / 10_000;
    }

    function test_maxBuy_singleBuyOverCap() public {
        (address token, uint256 cap) = _maxBuyToken();
        assertEq(hook.limitsEnd(token), block.timestamp - 15 + 10 minutes);
        PoolKey memory key = _key(token);
        vm.prank(traders[0]);
        vm.expectRevert();
        swapRouter.swap{value: 10 ether}(
            key, IDexManager.SwapParams(true, int256(cap + 1), MIN_PRICE_LIMIT), _settings(), ""
        );
        _buyExactOut(traders[0], token, cap, 10 ether); // exactly the cap is fine
    }

    /// @notice Taking the tokens as ERC-6909 claims does not get around it: the cap is on the pool.
    function test_maxBuy_claimsRouteCapped() public {
        (address token, uint256 cap) = _maxBuyToken();
        PoolKey memory key = _key(token);
        vm.prank(traders[0]);
        vm.expectRevert();
        swapRouter.swap{value: 10 ether}(
            key,
            IDexManager.SwapParams(true, int256(cap + 1), MIN_PRICE_LIMIT),
            TestRouter.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Two buys in one transaction (even in two separate settlement locks) count together.
    function test_maxBuy_splitBuysInOneTxCountTogether() public {
        (address token, uint256 cap) = _maxBuyToken();
        PoolKey memory key = _key(token);
        DoubleBuyer db = new DoubleBuyer();
        vm.deal(address(db), 10 ether);
        vm.expectRevert();
        db.buyTwice(swapRouter, key, cap / 2 + 1, false);
        db.buyTwice(swapRouter, key, cap / 2, true);
    }

    function test_maxBuy_goneAfterWindow() public {
        (address token, uint256 cap) = _maxBuyToken();
        vm.warp(hook.limitsEnd(token));
        _buyExactOut(traders[2], token, cap * 3, 10 ether);
    }

    function test_firstBuyCappedByLimits() public {
        StealthFactory.LaunchOptions memory o = _limits(100, 50, 5 minutes, 0);
        uint256 allowance = locker.firstBuyAllowance(100, 50);
        assertEq(allowance, C.TOTAL_SUPPLY * 50 / 10_000, "min(5%, 1%, 0.5%)");
        (uint256 quoted,) = locker.quoteLaunchBuyCapped(4 ether, TAX, 1 ether, allowance);
        address token = _launchOpts(creator, TAX, 1 ether, o);
        assertEq(IERC20(token).balanceOf(creator), quoted, "first buy exactly as quoted, at the tighter cap");
        assertLe(quoted, allowance);
        assertApproxEqRel(quoted, allowance, 1e12);
    }

    // ---------------------------------------------------------------------
    // First-buy lock
    // ---------------------------------------------------------------------

    function test_firstBuyLock_holdsUntilUnlock() public {
        address token = _launchOpts(creator, TAX, 0.05 ether, _limits(0, 0, 0, 30 days));
        StealthToken t = StealthToken(token);
        uint256 locked = IERC20(token).balanceOf(creator);
        assertGt(locked, 0);
        assertEq(t.lockedAccount(), creator);
        assertEq(t.lockedAmount(), locked);
        assertEq(t.unlockTime(), block.timestamp + 30 days);
        assertEq(t.lockedBalanceOf(creator), locked);
        _skipSniperWindow(token);

        // Every way out is closed: transfer, transferFrom, burn, and selling through the pool or the router.
        vm.startPrank(creator);
        vm.expectRevert(StealthToken.FirstBuyLocked.selector);
        t.transfer(attacker, 1);
        t.approve(attacker, type(uint256).max);
        vm.expectRevert(StealthToken.FirstBuyLocked.selector);
        t.burn(1);
        vm.stopPrank();
        vm.prank(attacker);
        vm.expectRevert(StealthToken.FirstBuyLocked.selector);
        t.transferFrom(creator, attacker, 1);
        vm.prank(creator);
        t.approve(address(swapRouter), type(uint256).max);
        PoolKey memory key = _key(token);
        vm.prank(creator);
        vm.expectRevert();
        swapRouter.swap(key, IDexManager.SwapParams(false, -1e18, MAX_PRICE_LIMIT), _settings(), "");
        vm.startPrank(creator);
        t.approve(_dexPermit2(), type(uint256).max);
        IPermit2(_dexPermit2()).approve(token, _dexRouter(), type(uint160).max, uint48(block.timestamp + 1 days));
        (bytes memory commands, bytes[] memory inputs) = UR.exactIn(key, false, 1e18, 0);
        vm.expectRevert();
        IUniversalRouter(_dexRouter()).execute(commands, inputs, block.timestamp);
        vm.stopPrank();

        // Tokens bought later are free to move; the locked amount stays.
        uint256 extra = _buy(creator, token, 0.1 ether);
        vm.prank(creator);
        t.transfer(attacker, extra);
        vm.prank(creator);
        vm.expectRevert(StealthToken.FirstBuyLocked.selector);
        t.transfer(attacker, 1);

        vm.warp(t.unlockTime());
        assertEq(t.lockedBalanceOf(creator), 0);
        assertGt(_sell(creator, token, locked), 0, "unlocked");
    }

    function test_firstBuyLock_noFirstBuyNoLock() public {
        address token = _launchOpts(creator, TAX, 0, _limits(0, 0, 0, 30 days));
        assertEq(StealthToken(token).lockedAccount(), address(0));
    }

    function test_revert_setFirstBuyLock_lockerOnlyOnce() public {
        address token = _launchOpts(creator, TAX, 0.05 ether, _limits(0, 0, 0, 1 days));
        vm.prank(attacker);
        vm.expectRevert(StealthToken.NotLocker.selector);
        StealthToken(token).setFirstBuyLock(attacker, 0);
        vm.prank(address(locker));
        vm.expectRevert(StealthToken.LockAlreadySet.selector);
        StealthToken(token).setFirstBuyLock(attacker, 0);
    }

    function test_revert_invalidLimits() public {
        StealthFactory.LaunchOptions[8] memory bad = [
            _limits(49, 0, 60, 0), // max wallet below 0.5%
            _limits(501, 0, 60, 0), // above 5%
            _limits(0, 9, 60, 0), // max buy below 0.1%
            _limits(0, 501, 60, 0), // above 5%
            _limits(100, 0, 0, 0), // limits without a window
            _limits(100, 0, 3601, 0), // window above 60 minutes
            _limits(0, 0, 60, 0), // a window without limits
            _limits(0, 0, 0, 90 days + 1) // lock above 90 days
        ];
        for (uint256 i; i < bad.length; ++i) {
            StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
            p.options = bad[i];
            vm.prank(creator);
            vm.expectRevert(StealthFactory.InvalidOptions.selector);
            factory.launch(p);
        }
    }

    /// @notice The limits are written into the token's bytecode, so its address does not depend on the launch time.
    function test_predictedAddress_ignoresTheLaunchTime() public {
        StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
        p.options = _limits(100, 50, 5 minutes, 30 days);
        address predicted = factory.predictTokenAddress(creator, p);
        vm.warp(block.timestamp + 1 hours);
        assertEq(factory.predictTokenAddress(creator, p), predicted);
        vm.prank(creator);
        assertEq(factory.launch(p), predicted);
    }

    /// @notice A token with no limits and no lock never reads its terms and writes none.
    function test_noLimits_noTermsInStorage() public {
        address token = _launch(TAX, 4 ether);
        assertEq(StealthToken(token).unlockTime(), 0);
        assertEq(StealthToken(token).lockedAccount(), address(0));
        assertEq(StealthToken(token).lockedAmount(), 0);
        assertEq(StealthToken(token).lockedBalanceOf(creator), 0);
    }

    function test_noLimits_noEffect() public {
        address token = _launch(TAX, 4 ether);
        assertEq(StealthToken(token).maxWallet(), 0);
        assertEq(StealthToken(token).limitsEnd(), 0);
        assertEq(hook.limitsEnd(token), 0);
        _buyExactOut(traders[0], token, 40_000_000e18, 100 ether);
    }
}
