// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Dex, DexBase, DexCallback, IDexManager, IDexHooks, PoolKey, Currency, BalanceDelta} from "@dex/Dex.sol";
import {TestRouter} from "../utils/TestRouter.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {ForceSend, ReentrantClaimer} from "../utils/Harnesses.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";
import {LaunchType, TeamShare} from "../../src/interfaces/IStealth.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthHook} from "../../src/StealthHook.sol";
import {StealthToken} from "../../src/StealthToken.sol";
import {StealthTokenDeployer} from "../../src/StealthTokenDeployer.sol";
import {StealthConstants as C} from "../../src/libraries/StealthConstants.sol";

/// @notice Swaps straight on the pool manager inside its own settlement lock, with any hookData, settling after the
///         swap the way routers do. Also tries to reach the fee vault's native claim from inside the lock.
contract RawSwapper is DexCallback {
    constructor(IDexManager manager_) DexBase(manager_) {}

    function buy(PoolKey memory key, uint256 ethIn, bytes memory hookData) external payable returns (uint256 out) {
        out = abi.decode(_lockRaw(abi.encode(key, ethIn, hookData, msg.sender)), (uint256));
    }

    function stealClaims(address vault, uint256 amount) external {
        _lockRaw(abi.encode(vault, amount));
    }

    function _onLock(bytes calldata data) internal override returns (bytes memory) {
        if (data.length == 64) {
            (address vault, uint256 amount) = abi.decode(data, (address, uint256));
            _burnClaim(vault, Currency.wrap(address(0)), amount); // only the owner or its operator may burn
            _take(Currency.wrap(address(0)), address(this), amount);
            return "";
        }
        (PoolKey memory key, uint256 ethIn, bytes memory hookData, address to) =
            abi.decode(data, (PoolKey, uint256, bytes, address));
        BalanceDelta d = poolManager.swap(
            key,
            IDexManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: Dex.MIN_SQRT_PRICE + 1
            }),
            hookData
        );
        _settleNative(uint128(-d.amount0()));
        _take(key.currency1, to, uint128(d.amount1()));
        return abi.encode(uint128(d.amount1()));
    }
}

/// @notice A creator whose refund callback tries to get back into the protocol mid-launch.
contract ReentrantLauncher {
    StealthFactory public immutable factory;
    StealthLocker public immutable locker;
    StealthFeeVault public immutable vault;
    address public token;
    bool public reentered;
    bytes public lastError;

    constructor(StealthFactory factory_) {
        factory = factory_;
        locker = factory_.locker();
        vault = StealthFeeVault(address(factory_.feeVault()));
    }

    function launch(StealthFactory.LaunchParams calldata p) external payable {
        token = factory.launch{value: msg.value}(p);
    }

    receive() external payable {
        reentered = true;
        StealthFactory.LaunchParams memory p = StealthFactory.LaunchParams({
            name: "Again",
            symbol: "AGN",
            logo: "",
            description: "",
            socials: StealthToken.Socials("", "", "", "", ""),
            taxBps: 125,
            quote: address(0),
            target: 4 ether,
            quoteAmount: 0,
            minTokensOut: 0,
            configVersion: factory.configVersion(),
            creator: address(0),
            options: StealthFactory.LaunchOptions(LaunchType.Creator, new TeamShare[](0), 0, 0, 0, 0)
        });
        try factory.launch(p) {
            revert("re-entered the factory");
        } catch (bytes memory err) {
            lastError = err;
        }
    }
}

/// @notice Attacks that have to fail, and ones that have to be unprofitable.
contract AttacksTest is BaseTest {

    TestRouter internal lpRouter;
    TestRouter internal donateRouter;

    function setUp() public override {
        super.setUp();
        lpRouter = new TestRouter(manager);
        donateRouter = new TestRouter(manager);
    }

    function _hookError(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return _dexHookError(address(hook), callback, reason);
    }

    // ---------------------------------------------------------------------
    // Pool squatting
    // ---------------------------------------------------------------------

    /// @notice Front-running a launch by creating its pool first: the Stealth pool can't be made by anyone else,
    ///         and a pool for the same token with other settings doesn't touch the Stealth one.
    function test_squat_poolBeforeLaunch() public {
        StealthFactory.LaunchParams memory p = _params(TAX, 4 ether, 0);
        address predicted = factory.predictTokenAddress(creator, p);
        PoolKey memory stealthKey = Dex.key(NATIVE, predicted, address(hook), address(manager), C.POOL_FEE, C.TICK_SPACING);
        uint160 start = Dex.sqrtAtTick(200_000);

        vm.prank(attacker);
        vm.expectRevert(
            _hookError(IDexHooks.beforeInitialize.selector, abi.encodeWithSelector(StealthHook.NotLocker.selector))
        );
        manager.initialize(stealthKey, start);

        // A plain pool for the not-yet-deployed token, at a silly price. Allowed by the DEX, irrelevant to us.
        PoolKey memory plainKey = _dexPlainKey(NATIVE, Currency.wrap(predicted), 3000, 60);
        vm.prank(attacker);
        manager.initialize(plainKey, Dex.MIN_SQRT_PRICE + 1);

        address token = _launchWith(creator, TAX, 4 ether, 0);
        assertEq(token, predicted, "launch unaffected");
        assertEq(_sqrtPrice(token), locker.getPool(token).startSqrtPriceX96, "the Stealth pool opened at its price");
    }

    /// @notice Nobody else can deploy at a Stealth token's address, or register or re-open its pool.
    function test_squat_tokenAddressAndRegistration() public {
        StealthToken.Args memory args;
        vm.prank(attacker);
        vm.expectRevert(StealthTokenDeployer.NotFactory.selector);
        tokenDeployer.deploy(bytes32(0), args);

        address token = _launch(TAX, 4 ether);
        vm.prank(attacker);
        vm.expectRevert(StealthHook.NotLocker.selector);
        hook.register(token, _reg(12_500, 1, 1));
        vm.prank(address(locker));
        vm.expectRevert(StealthHook.AlreadyRegistered.selector);
        hook.register(token, _reg(12_500, 1, 1));
    }

    // ---------------------------------------------------------------------
    // Liquidity and fees
    // ---------------------------------------------------------------------

    /// @notice A range order (or JIT liquidity) would skim the fee from taxed swaps: refused.
    function test_rangeOrder_refused() public {
        address token = _launch(575, 4 ether);
        _buy(traders[0], token, 1 ether);
        PoolKey memory key = _key(token);
        (, int24 tick,,) = _getSlot0(_poolId(token));
        int24 below = (tick / 10) * 10 - 100;
        vm.deal(attacker, 10 ether);
        vm.prank(attacker);
        vm.expectRevert(
            _hookError(IDexHooks.beforeAddLiquidity.selector, abi.encodeWithSelector(StealthHook.NotLocker.selector))
        );
        lpRouter.modifyLiquidity{value: 10 ether}(
            key,
            IDexManager.ModifyLiquidityParams({
                tickLower: below - 600, tickUpper: below, liquidityDelta: 1e18, salt: 0
            }),
            ""
        );
    }

    /// @notice The locked positions can't be touched by anyone: there is no remove path, and nobody else owns them.
    function test_lockedLiquidity_cannotBeRemoved() public {
        address token = _launch(575, 4 ether);
        _buy(traders[0], token, 1 ether);
        StealthLocker.PoolInfo memory info = locker.getPool(token);
        PoolKey memory key = _key(token);
        vm.prank(attacker);
        vm.expectRevert(); // the attacker has no position to remove from
        lpRouter.modifyLiquidity(
            key,
            IDexManager.ModifyLiquidityParams({
                tickLower: info.curveTickLower, tickUpper: info.curveTickUpper, liquidityDelta: -1e18, salt: CURVE_SALT
            }),
            ""
        );
        assertEq(_positionLiquidityOf(token, CURVE_SALT), info.curveLiquidity);
    }

    /// @notice Donations are refused: nothing can sit in the positions as fees.
    function test_donate_refused() public {
        address token = _launch(TAX, 4 ether);
        _buy(traders[0], token, 1 ether);
        vm.deal(attacker, 1 ether);
        PoolKey memory key = _key(token); // before the prank: an external call would consume it
        vm.prank(attacker);
        vm.expectRevert(
            _hookError(IDexHooks.beforeDonate.selector, abi.encodeWithSelector(StealthHook.DonationsDisabled.selector))
        );
        donateRouter.donate{value: 1 ether}(key, 1 ether, 0, "");
    }

    /// @notice No hookData lowers the fee, and a raw swap in the trader's own unlock, settled after the swap, pays
    ///         exactly what a router swap pays, in native, to the vault.
    function test_noWayAroundTheFee() public {
        address token = _launch(575, 4 ether);
        RawSwapper raw = new RawSwapper(manager);
        uint256 c0 = _vaultClaims();
        uint256 withData = _rawBuy(raw, token, abi.encode(uint24(0)));
        assertEq(_vaultClaims() - c0, 0.0575 ether, "5.75% of 1 native, whatever the hookData");
        address other = _launch(575, 4 ether);
        uint256 plain = _buy(traders[1], other, 1 ether);
        assertEq(withData, plain, "same tokens as a plain router buy");
    }

    /// @notice The vault's native claim can't be burned or taken by anyone else, even inside a lock.
    function test_vaultClaims_cannotBeTaken() public {
        address token = _launch(575, 4 ether);
        _buy(traders[0], token, 1 ether);
        uint256 claims = _vaultClaims();
        RawSwapper raw = new RawSwapper(manager);
        vm.prank(attacker);
        vm.expectRevert();
        raw.stealClaims(address(vault), claims);
        vm.prank(attacker);
        vm.expectRevert();
        _dexTransferClaimsFrom(address(vault), attacker, NATIVE, claims);
        assertEq(_vaultClaims(), claims, "untouched");
    }

    function _rawBuy(RawSwapper raw, address token, bytes memory hookData) internal returns (uint256 out) {
        PoolKey memory key = _key(token);
        vm.prank(attacker);
        out = raw.buy{value: 1 ether}(key, 1 ether, hookData);
    }

    /// @notice The hook's callbacks and fee setter are reachable only through the pool manager.
    function test_hookCallbacks_onlyPoolManager() public {
        address token = _launch(TAX, 4 ether);
        PoolKey memory key = _key(token);
        IDexManager.SwapParams memory sp =
            IDexManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        vm.startPrank(attacker);
        vm.expectRevert(StealthHook.NotPoolManager.selector);
        hook.beforeSwap(address(locker), key, sp, abi.encode(uint24(0)));
        vm.expectRevert(StealthHook.NotPoolManager.selector);
        hook.afterSwap(attacker, key, sp, BalanceDelta.wrap(0), "");
        vm.expectRevert(StealthHook.NotPoolManager.selector);
        hook.afterInitialize(address(locker), key, 1, 0);
        vm.expectRevert(StealthHook.NotPoolManager.selector);
        hook.beforeInitialize(address(locker), key, 1);
        vm.expectRevert(StealthHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(
            address(locker),
            key,
            IDexManager.ModifyLiquidityParams({tickLower: 0, tickUpper: 10, liquidityDelta: 1, salt: 0}),
            ""
        );
        vm.expectRevert(); // a static-fee pool's LP fee can't be changed by anyone
        manager.updateDynamicLPFee(key, 500_000);
        vm.stopPrank();
        assertEq(_lpFee(token), 0, "the attacker changed nothing");
    }

    // ---------------------------------------------------------------------
    // Price
    // ---------------------------------------------------------------------

    /// @notice Above the launch price there is no liquidity: a swap that would drift the price up there reverts,
    ///         even from the state where a zero-size buy has crossed into the curve at the launch price.
    function test_pricePoke_aboveStartRefused() public {
        address token = _launch(575, 4 ether);
        _buy(traders[0], token, 1); // all fee, crosses into the curve without moving the price
        assertEq(_sqrtPrice(token), locker.getPool(token).startSqrtPriceX96);
        deal(token, attacker, 1e18); // tokens from nowhere: the only way to push back past the start
        vm.startPrank(attacker);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        PoolKey memory key = _key(token);
        vm.expectRevert(
            _hookError(IDexHooks.afterSwap.selector, abi.encodeWithSelector(StealthHook.PriceAboveStart.selector))
        );
        swapRouter.swap(
            key,
            IDexManager.SwapParams({zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            TestRouter.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Reentrancy and forced native
    // ---------------------------------------------------------------------

    function test_reentrantClaimer_blocked() public {
        address token = _launch(575, 4 ether);
        ReentrantClaimer rc = new ReentrantClaimer(vault);
        rc.setToken(token);
        vm.prank(creator);
        vault.offerCreator(token, address(rc));
        rc.accept();
        _buy(traders[0], token, 1 ether);
        uint256 owed = vault.coinOwed(token);
        vm.expectRevert(); // the re-entry reverts, which makes the payment (and the claim) revert
        rc.claim();
        assertEq(vault.coinOwed(token), owed, "nothing was paid out");
    }

    function test_reentrantLauncher_refundCannotReenter() public {
        ReentrantLauncher rl = new ReentrantLauncher(factory);
        vm.deal(address(this), 10 ether);
        rl.launch{value: 1 ether}(_params(TAX, 4 ether, 0)); // 1 native is far over the 5% cap: a refund is paid
        assertTrue(rl.reentered(), "the refund reached the creator");
        assertEq(bytes4(rl.lastError()), bytes4(keccak256("ReentrancyGuardReentrantCall()")), "re-entry refused");
        assertEq(
            IERC20(rl.token()).balanceOf(address(rl)),
            locker.getPool(rl.token()).launcher == address(rl) ? IERC20(rl.token()).balanceOf(address(rl)) : 0
        );
        assertGt(IERC20(rl.token()).balanceOf(address(rl)), 0);
    }

    /// @notice native forced in with selfdestruct changes nobody's payout.
    function test_forcedBnb_changesNothing() public {
        address token = _launch(575, 4 ether);
        _buy(traders[0], token, 1 ether);
        new ForceSend{value: 1 ether}(payable(address(vault)));
        new ForceSend{value: 1 ether}(payable(address(locker)));
        new ForceSend{value: 1 ether}(payable(address(hook)));
        new ForceSend{value: 1 ether}(payable(address(factory)));
        uint256 before = creator.balance;
        vm.prank(creator);
        vault.claimCreator(token);
        assertEq(creator.balance - before, 0.04025 ether, "the creator gets their share, no more");
        vault.sweep(_one(token));
        assertEq(_vaultClaims(), 0, "every owed wei paid, from the claim");
        assertEq(address(vault).balance, 1 ether, "the forced native just sits there, outside the books");
    }

    // ---------------------------------------------------------------------
    // Privileges
    // ---------------------------------------------------------------------

    /// @notice The admin can only shape future launches; a live token's pool, fee and money are out of reach.
    function test_admin_cannotTouchLiveTokens() public {
        address token = _launch(575, 4 ether);
        _buy(traders[0], token, 1 ether);
        StealthHook.PoolConfig memory before = hook.getConfig(token);

        vm.startPrank(admin);
        factory.setTargetRange(5 ether, 5 ether, 6 ether);
        factory.setLaunchFee(0.1 ether);
        factory.setLaunchesPaused(true);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreator(token);
        vm.expectRevert(StealthHook.NotLocker.selector);
        hook.register(token, _reg(12_500, 1, 1));
        vm.stopPrank();

        StealthHook.PoolConfig memory afterCfg = hook.getConfig(token);
        assertEq(afterCfg.taxFee, before.taxFee);
        assertEq(afterCfg.startSqrtPriceX96, before.startSqrtPriceX96);
        assertEq(afterCfg.graduationSqrtPriceX96, before.graduationSqrtPriceX96);
        assertEq(afterCfg.launchTime, before.launchTime);
        uint256 c0 = _vaultClaims();
        _buy(traders[1], token, 1 ether); // trading continues while launches are paused
        assertEq(_vaultClaims() - c0, 0.0575 ether, "still the tier picked at launch");
    }

    /// @notice The deployer keeps no power after deployment.
    function test_deployer_hasNoRole() public {
        address token = _launch(575, 4 ether);
        vm.startPrank(deployer);
        vm.expectRevert(StealthFactory.NotAdmin.selector);
        factory.setLaunchesPaused(true);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreator(token);
        vm.expectRevert(StealthLocker.NotFactory.selector);
        locker.launch(
            StealthLocker.LaunchInput({
                token: token,
                launcher: deployer,
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
        vm.stopPrank();
    }

    /// @notice Fees only ever go to the set wallets, whoever triggers the payout.
    function test_feeTheft_destinationsFixed() public {
        address token = _launch(575, 4 ether);
        _buy(traders[0], token, 2 ether);
        uint256 t0 = platform.balance;
        uint256 m0 = marketing.balance;
        uint256 a0 = attacker.balance;
        vm.startPrank(attacker);
        vault.sweep(_one(token));
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.claimCreator(token);
        vm.expectRevert(StealthFeeVault.NotCreator.selector);
        vault.offerCreator(token, attacker);
        vm.expectRevert(StealthFeeVault.NotPendingCreator.selector);
        vault.acceptCreator(token);
        vm.stopPrank();
        assertEq(attacker.balance, a0, "the attacker got nothing");
        assertEq(platform.balance - t0, 0.0345 ether, "1.725% of the 2 native trade: 30% of the 5.75% tier");
        assertEq(marketing.balance - m0, 0, "no marketing share on a Creator coin");
    }

    /// @notice At the 90% sniper fee every swap shape still works, including exact output.
    function test_sniperWindow_allShapesWork() public {
        address token = _launchWith(creator, TAX, 4 ether, 0);
        uint256 got = _buy(sniper, token, 1 ether);
        assertGt(got, 0);
        _buyExactOut(sniper, token, got / 10, 100 ether);
        _sell(sniper, token, got / 10);
        (, uint256 raised,,) = locker.progress(token);
        uint256 c0 = _vaultClaims();
        _sellExactOut(sniper, token, raised / 1000);
        assertEq(_vaultClaims() - c0, _feeOnTop(raised / 1000, 900_000), "90% on an exact-out sell too");
        assertGt(_vaultClaims(), 0.9 ether, "the sniper paid 90% on everything");
    }
}
