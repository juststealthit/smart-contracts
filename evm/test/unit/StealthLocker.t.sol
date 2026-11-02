// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DexBase, DexCallback, IDexManager, Currency} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthHook} from "../../src/StealthHook.sol";
import {PoolGeometry} from "../../src/libraries/PoolGeometry.sol";
import {IStealthFeeVault} from "../../src/interfaces/IStealth.sol";
import {StealthDeploy} from "../../script/lib/StealthDeploy.sol";
import {UnlockedCaller} from "../utils/Harnesses.sol";

contract StealthLockerTest is BaseTest {
    function test_poolKeyAndSeeding() public {
        address token = _launch(325, 4 ether);
        StealthLocker.PoolInfo memory info = locker.getPool(token);
        PoolGeometry.Geometry memory g = PoolGeometry.compute(4 ether);
        assertEq(Currency.unwrap(_key(token).currency0), address(0), "native is currency0");
        assertEq(Currency.unwrap(_key(token).currency1), token);
        assertEq(_key(token).fee, 0, "static zero LP fee: the hook takes the fee");
        assertEq(_keyTickSpacing(_key(token)), 10, "tick spacing 10");
        assertEq(_keyManager(_key(token)), address(manager));
        assertEq(Currency.unwrap(info.quote), address(0));
        assertEq(info.target, 4 ether);
        assertEq(address(_key(token).hooks), address(hook));
        assertEq(info.curveLiquidity, g.curveLiquidity);
        assertEq(info.tailLiquidity, g.tailLiquidity);
        assertEq(info.graduationQuote, g.graduationQuote);
        assertEq(_positionLiquidityOf(token, CURVE_SALT), g.curveLiquidity, "curve position locked");
        assertEq(_positionLiquidityOf(token, TAIL_SALT), g.tailLiquidity, "tail position locked");
        assertEq(_poolLiquidity(_poolId(token)), 0, "no active liquidity until the first buy");
        (, uint256 raised, uint256 sold, bool graduated) = locker.progress(token);
        assertEq(raised, 0);
        assertEq(sold, 0);
        assertFalse(graduated);
    }

    function test_progressTracksTheCurve() public {
        address token = _launch(325, 4 ether);
        uint256 got = _buy(traders[0], token, 1 ether);
        (, uint256 raised, uint256 sold,) = locker.progress(token);
        // The pool took exactly 1 native less the 3.25% fee; progress() reads it back from the price, rounding down.
        assertApproxEqAbs(raised, 0.9675 ether, 2, "1 native less the 3.25% fee");
        assertLe(raised, 0.9675 ether);
        assertApproxEqAbs(sold, got, 1e6);
        assertEq(_poolLiquidity(_poolId(token)), locker.getPool(token).curveLiquidity, "curve now active");

        _graduate(token, traders[1]);
        (, raised,,) = locker.progress(token);
        assertGe(raised, locker.getPool(token).graduationQuote);
        assertEq(
            _poolLiquidity(_poolId(token)), locker.getPool(token).tailLiquidity, "tail active past graduation"
        );
    }

    /// @notice The positions never earn anything: no fees accrue in the pool, so nothing is left for anyone to collect.
    function test_positionsEarnNoFees() public {
        address token = _launch(575, 4 ether);
        uint256 got = _buy(traders[0], token, 2 ether);
        _sell(traders[0], token, got / 2);
        _buyExactOut(traders[1], token, 1_000_000e18, 1 ether);
        (uint256 g0, uint256 g1) = _feeGrowthGlobals(_poolId(token));
        assertEq(g0, 0, "no quote fee growth");
        assertEq(g1, 0, "no token fee growth");
        assertEq(IERC20(token).balanceOf(address(locker)), 0);
        assertEq(address(locker).balance, 0);
    }

    function test_launchInsideALock() public {
        UnlockedCaller c = new UnlockedCaller(manager, factory);
        vm.deal(address(this), 1 ether);
        address token = c.launch{value: 0.05 ether}(_params(TAX, 4 ether, 0));
        assertGt(IERC20(token).balanceOf(address(c)), 0, "first buy from inside a lock");
        assertEq(locker.getPool(token).launcher, address(c));
    }

    function test_revert_access() public {
        vm.startPrank(attacker);
        vm.expectRevert(StealthLocker.NotFactory.selector);
        locker.launch(
            StealthLocker.LaunchInput({
                token: address(1),
                launcher: attacker,
                quote: NATIVE,
                taxBps: 125,
                target: 4 ether,
                maxWalletBps: 0,
                maxBuyBps: 0,
                limitsWindow: 0,
                firstBuyLock: 0,
                quoteIn: 0,
                devBuy: 0,
                minTokensOut: 0
            })
        );
        vm.expectRevert(DexCallback.NotSettlement.selector);
        _callLockCallback(address(locker), "");
        (bool ok,) = address(locker).call{value: 1 ether}("");
        assertFalse(ok, "locker refuses stray native");
        vm.stopPrank();
        vm.expectRevert(StealthLocker.UnknownToken.selector);
        locker.progress(address(0xbeef));
    }

    /// @dev The factory is trusted to send matching quote, but the locker still refuses an inconsistent input.
    function test_revert_badQuoteInput() public {
        StealthLocker.LaunchInput memory p = StealthLocker.LaunchInput({
            token: address(0xbeef),
            launcher: attacker,
            quote: NATIVE,
            taxBps: 125,
            target: 4 ether,
            maxWalletBps: 0,
            maxBuyBps: 0,
            limitsWindow: 0,
            firstBuyLock: 0,
            quoteIn: 1 ether,
            devBuy: 2 ether,
            minTokensOut: 0
        });
        vm.deal(address(factory), 10 ether);
        vm.startPrank(address(factory));
        vm.expectRevert(StealthLocker.BadQuoteInput.selector); // devBuy above quoteIn
        locker.launch{value: 1 ether}(p);
        p.devBuy = 1 ether;
        vm.expectRevert(StealthLocker.BadQuoteInput.selector); // native value must equal quoteIn
        locker.launch{value: 0.5 ether}(p);
        p.quote = Currency.wrap(address(0x1234));
        vm.expectRevert(StealthLocker.BadQuoteInput.selector); // no value with an ERC-20 quote
        locker.launch{value: 1 ether}(p);
        vm.stopPrank();
    }

    function test_revert_launchTwice() public {
        address token = _launch(325, 4 ether);
        vm.prank(address(factory));
        vm.expectRevert(StealthLocker.AlreadyLaunched.selector);
        locker.launch(
            StealthLocker.LaunchInput({
                token: token,
                launcher: attacker,
                quote: NATIVE,
                taxBps: 125,
                target: 4 ether,
                maxWalletBps: 0,
                maxBuyBps: 0,
                limitsWindow: 0,
                firstBuyLock: 0,
                quoteIn: 0,
                devBuy: 0,
                minTokensOut: 0
            })
        );
    }

    function test_revert_constructor() public {
        IStealthFeeVault fv = IStealthFeeVault(address(vault));
        vm.expectRevert(DexBase.ZeroAddress.selector);
        new StealthLocker(IDexManager(address(0)), fv, address(factory), bytes32(0));
        vm.expectRevert(DexBase.ZeroAddress.selector);
        new StealthLocker(manager, IStealthFeeVault(address(0)), address(factory), bytes32(0));
        vm.expectRevert(DexBase.ZeroAddress.selector);
        new StealthLocker(manager, fv, address(0), bytes32(0));
        // A second locker deploys its own hook, but the fee vault points at the live hook, so it is refused. A failed
        // CREATE still uses a nonce, so the locker's address is predicted here, for a salt valid on either DEX.
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 initHash = keccak256(abi.encodePacked(type(StealthHook).creationCode, abi.encode(manager, fv)));
        (bytes32 salt,) = StealthDeploy.mineHookSalt(next, initHash);
        vm.expectRevert(StealthLocker.WiringMismatch.selector);
        new StealthLocker(manager, fv, address(factory), salt);
    }

    /// @notice The locker keeps one slot per launch: everything `getPool` shows is the system's own state or follows
    ///         from the target.
    function test_getPool_worksOutWhatItDoesNotStore() public {
        address token = _launchWith(creator, 225, 5 ether, 0);
        StealthLocker.PoolInfo memory info = locker.getPool(token);
        PoolGeometry.Geometry memory g = PoolGeometry.compute(5 ether);
        assertEq(info.launcher, creator);
        assertEq(info.launchTime, block.timestamp);
        assertEq(info.taxBps, 225);
        assertEq(info.curveTickLower, g.curveTickLower);
        assertEq(info.curveTickUpper, g.curveTickUpper);
        assertEq(info.tailTickLower, g.tailTickLower);
        assertEq(info.startSqrtPriceX96, g.startSqrtPriceX96);
        assertEq(info.graduationSqrtPriceX96, g.graduationSqrtPriceX96);
        assertEq(info.target, 5 ether);
        vm.expectRevert(StealthLocker.UnknownToken.selector);
        locker.getPool(address(0xbeef));
    }
}
