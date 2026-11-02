// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    Dex,
    DexBase,
    DexCallback,
    IDexManager,
    FullMath,
    SqrtPriceMath,
    SwapMath,
    PoolKey,
    BalanceDelta,
    Currency
} from "@dex/Dex.sol";
import {StealthConstants as C} from "./libraries/StealthConstants.sol";
import {PoolGeometry} from "./libraries/PoolGeometry.sol";
import {StealthHook} from "./StealthHook.sol";
import {StealthToken} from "./StealthToken.sol";
import {IStealthFeeVault} from "./interfaces/IStealth.sol";

/// @title StealthLocker
/// @notice Opens each Stealth token's pool in the launch transaction and owns its liquidity forever. The whole supply
///         goes into two positions shaped like a bonding curve (see PoolGeometry). There is no function that removes
///         liquidity. The launcher's optional first buy runs here, capped at 5% of supply, with any unused quote
///         refunded. The pools have an LP fee of 0, so the positions never earn fees: the hook takes every fee in the
///         quote currency and credits the fee vault directly.
/// @dev Deploys the StealthHook in its constructor with CREATE2, so the hook's locker is this contract. On Uniswap v4
///      the salt must be mined for the hook's permission bits; on Infinity any salt works.
///      Each launch stores one slot here, the target. Everything else about a pool follows from it, or lives in the
///      token, the hook or the fee vault, so `getPool` and `progress` work it out instead of reading it.
contract StealthLocker is DexCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct LaunchInput {
        address token;
        address launcher; // pays, receives the first-buy tokens and any refund
        Currency quote; // address(0) = the native coin
        uint16 taxBps; // the tier
        uint256 target; // graduation target, raw quote units
        uint16 maxWalletBps; // the token enforces it; caps the first buy
        uint16 maxBuyBps; // the hook enforces it per transaction during the limits window; caps the first buy
        uint32 limitsWindow;
        uint32 firstBuyLock; // seconds; locks the launcher's first-buy tokens in the token
        uint256 quoteIn; // quote this launch brought: msg.value for the native coin, already here for an ERC-20
        uint256 devBuy; // most of `quoteIn` the first buy may spend (fee included); the rest is refunded
        uint256 minTokensOut; // slippage limit on the first buy
    }

    /// @notice A pool's launch terms and geometry, worked out from what the system stores.
    struct PoolInfo {
        address launcher;
        uint40 launchTime;
        uint16 taxBps;
        int24 curveTickLower;
        int24 curveTickUpper;
        int24 tailTickLower;
        uint128 curveLiquidity;
        uint128 tailLiquidity;
        uint160 startSqrtPriceX96;
        uint160 graduationSqrtPriceX96;
        Currency quote;
        uint256 target; // as requested at launch, raw quote units
        uint256 graduationQuote; // what the curve position actually holds at the graduation price
    }

    struct Seed {
        PoolKey key;
        PoolGeometry.Geometry g;
        address launcher;
        uint24 rate;
        uint256 devBuy;
        uint256 minTokensOut;
        uint256 allowance;
    }

    struct QuoteState {
        uint160 sqrtPriceX96;
        int24 tick;
        int256 remaining;
        uint256 tokensOut;
        uint256 quoteUsed;
    }

    bytes32 internal constant CURVE_SALT = bytes32(0);
    bytes32 internal constant TAIL_SALT = bytes32(uint256(1));

    StealthHook public immutable hook;
    IStealthFeeVault public immutable feeVault;
    address public immutable factory;

    /// @dev Quote above what the pool needs to reach the first-buy cap, so the cap and not the amount stops the buy.
    uint256 internal constant CAP_BUFFER = 1_000;

    /// @dev A token's graduation target. Non-zero = launched.
    mapping(address token => uint256) internal _targets;

    event PoolLaunched(
        address indexed token,
        bytes32 indexed poolId,
        address indexed launcher,
        Currency quote,
        uint160 startSqrtPriceX96,
        uint160 graduationSqrtPriceX96,
        int24 curveTickLower,
        int24 curveTickUpper,
        uint128 curveLiquidity,
        uint128 tailLiquidity,
        uint256 graduationQuote
    );
    event DevBuy(address indexed token, address indexed launcher, uint256 quoteIn, uint256 tokensOut, uint256 refund);

    error NotFactory();
    error AlreadyLaunched();
    error UnknownToken();
    error ZeroAmount();
    error Slippage();
    error WiringMismatch();
    error BadQuoteInput();
    error QuoteTransferMismatch();

    /// @param poolManager_ The chain's pool manager.
    /// @param feeVault_ StealthFeeVault (receives every fee from the hook).
    /// @param factory_ StealthFactory (the only caller of `launch`).
    /// @param hookSalt CREATE2 salt of the hook (mined on Uniswap v4).
    constructor(IDexManager poolManager_, IStealthFeeVault feeVault_, address factory_, bytes32 hookSalt)
        DexBase(poolManager_)
    {
        if (address(feeVault_) == address(0) || factory_ == address(0)) revert ZeroAddress();
        feeVault = feeVault_;
        factory = factory_;
        hook = new StealthHook{salt: hookSalt}(poolManager_, feeVault_);
        // Every address here was predicted before deployment. Refuse to deploy if a prediction was wrong.
        if (feeVault_.hook() != address(hook) || feeVault_.factory() != factory_) revert WiringMismatch();
    }

    // ---------------------------------------------------------------------
    // Launch
    // ---------------------------------------------------------------------

    /// @notice Creates the token's pool, locks the whole supply into it, and runs the launcher's first buy.
    /// @dev Callable by the factory only, with the quote for the first buy sent as value (native) or already
    ///      transferred here (ERC-20). Works whether or not the settlement contract is already locked by the caller.
    function launch(LaunchInput calldata p) external payable nonReentrant returns (uint256 devTokens, uint256 refund) {
        if (msg.sender != factory) revert NotFactory();
        if (_targets[p.token] != 0) revert AlreadyLaunched();
        // For an ERC-20 the factory has already moved `quoteIn` here and checked it arrived exactly.
        if (p.devBuy > p.quoteIn || msg.value != (Dex.isNative(p.quote) ? p.quoteIn : 0)) revert BadQuoteInput();

        PoolGeometry.Geometry memory g = PoolGeometry.compute(p.target);
        _targets[p.token] = p.target;
        uint24 rate = uint24(p.taxBps) * C.PIPS_PER_BPS;
        hook.register(
            p.token,
            StealthHook.Registration({
                taxFee: rate,
                startSqrtPriceX96: g.startSqrtPriceX96,
                graduationSqrtPriceX96: g.graduationSqrtPriceX96,
                maxBuyBps: p.maxBuyBps,
                limitsWindow: p.maxBuyBps == 0 ? 0 : p.limitsWindow
            })
        );

        PoolKey memory key = _key(p.quote, p.token);
        poolManager.initialize(key, g.startSqrtPriceX96);
        emit PoolLaunched(
            p.token,
            Dex.id(key),
            p.launcher,
            p.quote,
            g.startSqrtPriceX96,
            g.graduationSqrtPriceX96,
            g.curveTickLower,
            g.curveTickUpper,
            g.curveLiquidity,
            g.tailLiquidity,
            g.graduationQuote
        );

        Seed memory s = Seed({
            key: key,
            g: g,
            launcher: p.launcher,
            rate: rate,
            devBuy: p.devBuy,
            minTokensOut: p.minTokensOut,
            allowance: firstBuyAllowance(p.maxWalletBps, p.maxBuyBps)
        });
        uint256 quoteUsed;
        (devTokens, quoteUsed) = abi.decode(_run(s), (uint256, uint256));
        refund = p.quoteIn - quoteUsed;
        if (p.devBuy != 0) emit DevBuy(p.token, p.launcher, quoteUsed, devTokens, refund);
        if (p.firstBuyLock != 0 && devTokens != 0) StealthToken(p.token).setFirstBuyLock(p.launcher, devTokens);
        if (refund != 0) _refund(p.quote, p.launcher, refund);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice The pool key of a Stealth token.
    function poolKey(address token) public view returns (PoolKey memory) {
        return _key(feeVault.quoteOf(token), token);
    }

    /// @notice A pool's launch terms and geometry.
    function getPool(address token) external view returns (PoolInfo memory info) {
        uint256 target = _targets[token];
        if (target == 0) revert UnknownToken();
        PoolGeometry.Geometry memory g = PoolGeometry.compute(target);
        StealthHook.PoolConfig memory cfg = hook.getConfig(token);
        return PoolInfo({
            launcher: StealthToken(token).deployer(),
            launchTime: cfg.launchTime,
            taxBps: uint16(cfg.taxFee / C.PIPS_PER_BPS),
            curveTickLower: g.curveTickLower,
            curveTickUpper: g.curveTickUpper,
            tailTickLower: g.tailTickLower,
            curveLiquidity: g.curveLiquidity,
            tailLiquidity: g.tailLiquidity,
            startSqrtPriceX96: g.startSqrtPriceX96,
            graduationSqrtPriceX96: g.graduationSqrtPriceX96,
            quote: feeVault.quoteOf(token),
            target: target,
            graduationQuote: g.graduationQuote
        });
    }

    /// @notice Where the token is on its curve: quote raised and tokens sold (from the locked positions), and
    ///         whether the price has passed the graduation price.
    function progress(address token)
        external
        view
        returns (uint160 sqrtPriceX96, uint256 quoteRaised, uint256 tokensSold, bool graduated)
    {
        uint256 target = _targets[token];
        if (target == 0) revert UnknownToken();
        PoolGeometry.Geometry memory g = PoolGeometry.compute(target);
        sqrtPriceX96 = _sqrtPrice(Dex.id(poolKey(token)));
        graduated = hook.graduated(token);
        if (sqrtPriceX96 >= g.startSqrtPriceX96) return (sqrtPriceX96, 0, 0, graduated);
        if (sqrtPriceX96 >= g.graduationSqrtPriceX96) {
            quoteRaised = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, g.startSqrtPriceX96, g.curveLiquidity, false);
            tokensSold = SqrtPriceMath.getAmount1Delta(sqrtPriceX96, g.startSqrtPriceX96, g.curveLiquidity, false);
        } else {
            quoteRaised = g.graduationQuote
                + SqrtPriceMath.getAmount0Delta(sqrtPriceX96, g.graduationSqrtPriceX96, g.tailLiquidity, false);
            tokensSold =
                SqrtPriceMath.getAmount1Delta(g.graduationSqrtPriceX96, g.startSqrtPriceX96, g.curveLiquidity, false)
                + SqrtPriceMath.getAmount1Delta(sqrtPriceX96, g.graduationSqrtPriceX96, g.tailLiquidity, false);
        }
    }

    /// @notice What a first buy of `quoteIn` would return on a fresh pool with these settings.
    /// @dev Replays the launch: the gross quote is capped at what reaches the 5% cap, the hook takes the tier from it
    ///      (rounded up), and the rest is swapped with the pool's own swap loop, one step per tick-bitmap word,
    ///      which is where the pool rounds. The first buy stays inside the curve position.
    /// @return tokensOut Tokens the launcher would receive (at most 5% of supply).
    /// @return quoteUsed Quote the buy would use, fee included; the rest of `quoteIn` is refunded.
    function quoteLaunchBuy(uint256 target, uint16 taxBps, uint256 quoteIn)
        external
        pure
        returns (uint256 tokensOut, uint256 quoteUsed)
    {
        return quoteLaunchBuyCapped(target, taxBps, quoteIn, C.LAUNCH_ALLOWANCE);
    }

    /// @notice `quoteLaunchBuy` for a first buy capped at `allowance` tokens (see `firstBuyAllowance`).
    function quoteLaunchBuyCapped(uint256 target, uint16 taxBps, uint256 quoteIn, uint256 allowance)
        public
        pure
        returns (uint256 tokensOut, uint256 quoteUsed)
    {
        PoolGeometry.Geometry memory g = PoolGeometry.compute(target);
        uint24 rate = uint24(taxBps) * C.PIPS_PER_BPS;
        uint160 cap = _devBuyCap(g.startSqrtPriceX96, g.curveLiquidity, allowance);
        uint256 gross = _devBuyGross(g.startSqrtPriceX96, cap, g.curveLiquidity, rate, quoteIn);
        uint256 fee = FullMath.mulDivRoundingUp(gross, rate, C.PIPS);
        // The pool first crosses the start tick with no liquidity, which leaves it one tick below.
        QuoteState memory q = QuoteState({
            sqrtPriceX96: g.startSqrtPriceX96,
            tick: g.curveTickUpper - 1,
            remaining: -int256(gross - fee),
            tokensOut: 0,
            quoteUsed: 0
        });
        while (q.remaining != 0 && q.sqrtPriceX96 > cap) {
            _quoteStep(q, cap, g.curveLiquidity);
        }
        return (q.tokensOut, q.quoteUsed + fee);
    }

    /// @notice Most tokens a first buy may take: 5% of supply, or less if the launch sets a max wallet or a max buy.
    function firstBuyAllowance(uint16 maxWalletBps, uint16 maxBuyBps) public pure returns (uint256 allowance) {
        allowance = C.LAUNCH_ALLOWANCE;
        if (maxWalletBps != 0 && C.TOTAL_SUPPLY * maxWalletBps / C.BPS < allowance) {
            allowance = C.TOTAL_SUPPLY * maxWalletBps / C.BPS;
        }
        if (maxBuyBps != 0 && C.TOTAL_SUPPLY * maxBuyBps / C.BPS < allowance) {
            allowance = C.TOTAL_SUPPLY * maxBuyBps / C.BPS;
        }
    }

    // ---------------------------------------------------------------------
    // Internal: launch
    // ---------------------------------------------------------------------

    function _key(Currency quote, address token) internal view returns (PoolKey memory) {
        return Dex.key(quote, token, address(hook), address(poolManager), C.POOL_FEE, C.TICK_SPACING);
    }

    /// @dev Seeds inside a lock: directly if someone already holds the settlement lock (this contract's deltas still
    ///      net to zero before it returns), otherwise through a lock of its own.
    function _run(Seed memory s) internal returns (bytes memory) {
        return _isLocked() ? _seed(s) : _lockRaw(abi.encode(s));
    }

    function _onLock(bytes calldata data) internal override returns (bytes memory) {
        return _seed(abi.decode(data, (Seed)));
    }

    /// @dev Adds both positions, mints exactly what they took straight to the settlement contract (so no dust is ever
    ///      minted and the supply makes one transfer less), then runs the first buy. Requires a held lock.
    function _seed(Seed memory s) internal returns (bytes memory) {
        PoolGeometry.Geometry memory g = s.g;
        (BalanceDelta curveDelta,) = poolManager.modifyLiquidity(
            s.key,
            IDexManager.ModifyLiquidityParams({
                tickLower: g.curveTickLower,
                tickUpper: g.curveTickUpper,
                liquidityDelta: int256(uint256(g.curveLiquidity)),
                salt: CURVE_SALT
            }),
            ""
        );
        (BalanceDelta tailDelta,) = poolManager.modifyLiquidity(
            s.key,
            IDexManager.ModifyLiquidityParams({
                tickLower: g.tailTickLower,
                tickUpper: g.curveTickLower,
                liquidityDelta: int256(uint256(g.tailLiquidity)),
                salt: TAIL_SALT
            }),
            ""
        );
        // Both positions sit at or below the price at launch, so they take tokens (currency1) only.
        uint256 tokensOwed = uint256(uint128(-curveDelta.amount1())) + uint256(uint128(-tailDelta.amount1()));
        _sync(s.key.currency1);
        StealthToken(Currency.unwrap(s.key.currency1)).mintSupply(address(settlement), tokensOwed);
        _settle();

        (uint256 devTokens, uint256 quoteUsed) = s.devBuy == 0 ? (0, 0) : _devBuy(s);
        return abi.encode(devTokens, quoteUsed);
    }

    /// @dev Swaps at most the quote that reaches the cap (fee included); the cap is also the price limit, so the buy
    ///      stops there even if rounding leaves a few units. The hook charges the tier, not the sniper fee.
    function _devBuy(Seed memory s) internal returns (uint256 devTokens, uint256 quoteUsed) {
        PoolGeometry.Geometry memory g = s.g;
        uint160 cap = _devBuyCap(g.startSqrtPriceX96, g.curveLiquidity, s.allowance);
        uint256 gross = _devBuyGross(g.startSqrtPriceX96, cap, g.curveLiquidity, s.rate, s.devBuy);
        BalanceDelta delta = poolManager.swap(
            s.key,
            IDexManager.SwapParams({zeroForOne: true, amountSpecified: -int256(gross), sqrtPriceLimitX96: cap}),
            ""
        );
        quoteUsed = uint256(uint128(-delta.amount0()));
        devTokens = uint256(uint128(delta.amount1()));
        if (devTokens == 0) revert ZeroAmount();
        if (devTokens < s.minTokensOut) revert Slippage();

        // Pay the quote in. sync first in both cases: it also clears any stale ERC-20 sync left in the settlement.
        _sync(s.key.currency0);
        if (Dex.isNative(s.key.currency0)) {
            _settleNative(quoteUsed);
        } else {
            IERC20(Currency.unwrap(s.key.currency0)).safeTransfer(address(settlement), quoteUsed);
            if (_settle() != quoteUsed) revert QuoteTransferMismatch();
        }
        _take(s.key.currency1, s.launcher, devTokens);
    }

    /// @dev Returns the unused quote. For an ERC-20 the launcher must receive exactly the amount sent.
    function _refund(Currency quote, address launcher, uint256 amount) internal {
        if (Dex.isNative(quote)) {
            Address.sendValue(payable(launcher), amount);
            return;
        }
        IERC20 q = IERC20(Currency.unwrap(quote));
        uint256 launcherBefore = q.balanceOf(launcher);
        uint256 selfBefore = q.balanceOf(address(this));
        q.safeTransfer(launcher, amount);
        if (q.balanceOf(launcher) != launcherBefore + amount || q.balanceOf(address(this)) != selfBefore - amount) {
            revert QuoteTransferMismatch();
        }
    }

    /// @dev Gross quote (fee included) for a first buy of up to `quoteIn`: never more than what takes the pool to
    ///      the cap, plus a small buffer so the cap, not the amount, ends the buy.
    function _devBuyGross(uint160 startSqrtPriceX96, uint160 cap, uint128 liquidity, uint24 rate, uint256 quoteIn)
        internal
        pure
        returns (uint256)
    {
        uint256 toCap = SqrtPriceMath.getAmount0Delta(cap, startSqrtPriceX96, liquidity, true) + CAP_BUFFER;
        uint256 grossToCap = FullMath.mulDivRoundingUp(toCap, C.PIPS, C.PIPS - rate);
        return quoteIn < grossToCap ? quoteIn : grossToCap;
    }

    /// @dev One step of the pool's swap loop for a buy (LP fee 0): to the next tick-bitmap word boundary, or the cap.
    function _quoteStep(QuoteState memory q, uint160 cap, uint128 liquidity) internal pure {
        int24 compressed = PoolGeometry.floorToSpacing(q.tick) / C.TICK_SPACING;
        int24 next = (compressed - int24(uint24(uint8(uint24(compressed) % 256)))) * C.TICK_SPACING;
        uint160 sqrtNext = Dex.sqrtAtTick(next);
        (uint160 sqrtAfter, uint256 amountIn, uint256 amountOut,) =
            SwapMath.computeSwapStep(q.sqrtPriceX96, sqrtNext < cap ? cap : sqrtNext, liquidity, q.remaining, 0);
        q.remaining += int256(amountIn);
        q.tokensOut += amountOut;
        q.quoteUsed += amountIn;
        q.tick = sqrtAfter == sqrtNext ? next - 1 : Dex.tickAtSqrt(sqrtAfter);
        q.sqrtPriceX96 = sqrtAfter;
    }

    function _devBuyCap(uint160 startSqrtPriceX96, uint128 curveLiquidity, uint256 allowance)
        internal
        pure
        returns (uint160)
    {
        return SqrtPriceMath.getNextSqrtPriceFromOutput(startSqrtPriceX96, curveLiquidity, allowance, true);
    }
}
