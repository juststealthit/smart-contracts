// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    Dex,
    DexHook,
    DexBase,
    IDexHooks,
    IDexManager,
    FullMath,
    PoolKey,
    BalanceDelta,
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta,
    Currency
} from "@dex/Dex.sol";
import {StealthConstants as C} from "./libraries/StealthConstants.sol";
import {IStealthFeeVault} from "./interfaces/IStealth.sol";

/// @title StealthHook
/// @notice The hook on every Stealth pool. The pools have an LP fee of 0; this hook takes the token's tax itself,
///         always on the quote leg of the swap (the native coin or the ERC-20 the token is paired with): from the
///         quote going in on a buy, from the quote coming out on a sell. The rate is the tier picked at launch (1.25%
///         to 5.75%, locked), except for the first 15 seconds, when an anti-sniper fee starts at 90% and steps down
///         every second to the tier. The fee is credited to the StealthFeeVault in the same swap. During a token's
///         limits window the hook caps how many tokens one transaction can buy. Only the StealthLocker can create a
///         Stealth pool or add liquidity to one. The hook also marks the moment the price first passes the
///         graduation price, and stops anyone pushing the price past the launch price, where there is no liquidity.
/// @dev No admin and no upgrade path. Every Stealth token's address is above its quote's, so the quote is always
///      currency0 and the token currency1. The fee is settled as an ERC-6909 claim minted to the fee vault, so nothing
///      moves during the swap: on a buy the trader's quote only reaches the pool's settlement contract when the
///      router settles after the swap. The hook never holds funds or claims. Fees round up, so rounding never
///      favours the trader.
contract StealthHook is DexHook {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @dev Two slots, both written once at launch: the launch writes as little as it can.
    struct PoolConfig {
        uint160 startSqrtPriceX96; // non-zero = registered
        uint40 launchTime; // set when the pool is initialized
        uint24 taxFee; // pips: the tier, locked
        bool graduated;
        uint160 graduationSqrtPriceX96;
        uint32 limitsWindow; // seconds after launch during which `maxBuyBps` applies
        uint16 maxBuyBps; // most of the supply one transaction can buy during the limits window; 0 = no limit
    }

    /// @notice What the locker registers for a token before its pool is created. The tax in pips.
    struct Registration {
        uint24 taxFee;
        uint160 startSqrtPriceX96;
        uint160 graduationSqrtPriceX96;
        uint16 maxBuyBps;
        uint32 limitsWindow;
    }

    /// @notice The only address that can register, create or add liquidity to Stealth pools.
    address public immutable locker;
    /// @notice Receives every fee.
    IStealthFeeVault public immutable feeVault;

    /// @dev Transient slot seed for the tokens bought per transaction, per token, during the limits window.
    bytes32 internal constant BOUGHT_SLOT = keccak256("stealth.hook.boughtThisTx");

    mapping(address token => PoolConfig) internal _configs;

    event PoolRegistered(address indexed token, uint24 taxFee, uint16 maxBuyBps, uint32 limitsWindow);
    /// @notice A swap paid `fee` (raw units of the token's quote) at `rate` pips. `isBuy`: quote in; `exactInput`:
    ///         the trader fixed the input.
    event SwapFee(address indexed token, address indexed sender, bool isBuy, bool exactInput, uint256 fee, uint24 rate);
    event Graduated(address indexed token, uint160 sqrtPriceX96);

    error NotPoolManager();
    error NotLocker();
    error AlreadyRegistered();
    error InvalidFee();
    error InvalidPool();
    error PriceAboveStart();
    error PartialFill();
    error MaxBuyExceeded();
    error DonationsDisabled();
    error HookNotImplemented();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev The deployer (msg.sender) becomes the locker.
    constructor(IDexManager poolManager_, IStealthFeeVault feeVault_) DexBase(poolManager_) {
        feeVault = feeVault_;
        locker = msg.sender;
    }

    // ---------------------------------------------------------------------
    // Locker
    // ---------------------------------------------------------------------

    /// @notice Records a token's tier, buy limit and prices before its pool exists.
    /// @dev Callable by the locker only, once per token.
    function register(address token, Registration calldata r) external {
        if (msg.sender != locker) revert NotLocker();
        PoolConfig storage cfg = _configs[token];
        if (cfg.startSqrtPriceX96 != 0) revert AlreadyRegistered();
        if (!_isTier(r.taxFee) || r.limitsWindow > C.MAX_LIMITS_WINDOW || r.startSqrtPriceX96 == 0) revert InvalidFee();
        cfg.startSqrtPriceX96 = r.startSqrtPriceX96;
        cfg.taxFee = r.taxFee;
        cfg.graduationSqrtPriceX96 = r.graduationSqrtPriceX96;
        cfg.limitsWindow = r.limitsWindow;
        cfg.maxBuyBps = r.maxBuyBps;
        emit PoolRegistered(token, r.taxFee, r.maxBuyBps, r.limitsWindow);
    }

    // ---------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------

    /// @notice Refuses every pool except one the locker creates with the Stealth pool settings, at the launch price.
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != locker) revert NotLocker();
        address token = Currency.unwrap(key.currency1);
        PoolConfig storage cfg = _configs[token];
        if (
            cfg.startSqrtPriceX96 == 0 || cfg.launchTime != 0 || sqrtPriceX96 != cfg.startSqrtPriceX96
                || !Dex.matches(key, address(poolManager), C.POOL_FEE, C.TICK_SPACING)
                || !(key.currency0 == feeVault.quoteOf(token))
        ) revert InvalidPool();
        return IDexHooks.beforeInitialize.selector;
    }

    /// @notice Starts the sniper window.
    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPoolManager returns (bytes4) {
        _configs[Currency.unwrap(key.currency1)].launchTime = uint40(block.timestamp);
        return IDexHooks.afterInitialize.selector;
    }

    /// @notice Only the locker may add liquidity, so the two locked positions are the only liquidity.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IDexManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        if (sender != locker) revert NotLocker();
        return IDexHooks.beforeAddLiquidity.selector;
    }

    /// @notice Refuses donations: they would sit in the locked positions as fees nobody can ever collect, in tokens
    ///         as well as quote. Nothing but the hook's own fee, in the quote, to the fee vault.
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert DonationsDisabled();
    }

    /// @notice Takes the fee when the quote is the amount the trader fixed: an exact-input buy (fee out of the quote
    ///         going in) or an exact-output sell (fee on top of the quote coming out).
    function beforeSwap(address sender, PoolKey calldata key, IDexManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactInput = params.amountSpecified < 0;
        if (params.zeroForOne != exactInput) {
            return (IDexHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        address token = Currency.unwrap(key.currency1);
        uint24 rate = _rate(token, sender);
        // Never 0: the rate is at least 1.25% and the pool refuses a zero amount, so the fee rounds up to >= 1.
        uint256 fee = _specifiedFee(params.amountSpecified, rate);
        _chargeFee(token, key.currency0, fee, rate);
        emit SwapFee(token, sender, params.zeroForOne, exactInput, fee, rate);
        return (IDexHooks.beforeSwap.selector, toBeforeSwapDelta(int256(fee).toInt128(), 0), 0);
    }

    /// @notice Takes the fee when the quote is the amount the pool worked out: an exact-output buy (fee on top of
    ///         the quote going in) or an exact-input sell (fee out of the quote coming out). For the other two
    ///         modes, checks the pool swapped exactly the quote the fee was sized on. Then caps buys during the
    ///         limits window, marks graduation and guards the price.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IDexManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128 hookDelta) {
        address token = Currency.unwrap(key.currency1);
        uint24 rate = _rate(token, sender);
        if (params.zeroForOne && sender != locker) _checkBuyLimit(token, uint128(delta.amount1()));
        _checkPrice(token, key);
        hookDelta = _feeAfterSwap(token, key.currency0, sender, params, delta.amount0(), rate);
        return (IDexHooks.afterSwap.selector, hookDelta);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getConfig(address token) external view returns (PoolConfig memory) {
        return _configs[token];
    }

    /// @notice The fee a trader's swap pays right now, in pips (0 before launch).
    function currentFee(address token) external view returns (uint24) {
        if (_configs[token].launchTime == 0) return 0;
        return _rate(token, address(0));
    }

    /// @notice When the buy limit stops applying (0 if the token has none).
    function limitsEnd(address token) external view returns (uint256) {
        PoolConfig storage cfg = _configs[token];
        return cfg.maxBuyBps == 0 ? 0 : uint256(cfg.launchTime) + cfg.limitsWindow;
    }

    /// @notice True once the price has passed the graduation price. Never goes back to false.
    function graduated(address token) external view returns (bool) {
        return _configs[token].graduated;
    }

    /// @notice Timestamp at which the sniper window closes (0 before launch).
    function sniperWindowEnd(address token) external view returns (uint256) {
        uint256 launchTime = _configs[token].launchTime;
        return launchTime == 0 ? 0 : launchTime + C.SNIPER_WINDOW;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev The locker's own swap (the first buy, in the launch transaction) pays the tier. Everyone else pays the
    ///      sniper fee until the window closes: 90% in the launch's own second, then a straight line down, one step
    ///      per elapsed second, so `elapsed == 15` would be exactly the tier. Then the tier.
    function _rate(address token, address sender) internal view returns (uint24) {
        PoolConfig storage cfg = _configs[token];
        uint24 tax = cfg.taxFee;
        if (sender == locker) return tax;
        uint256 elapsed = block.timestamp - cfg.launchTime;
        if (elapsed >= C.SNIPER_WINDOW) return tax;
        return uint24(C.SNIPER_START_FEE - (uint256(C.SNIPER_START_FEE - tax) * elapsed) / C.SNIPER_WINDOW);
    }

    function _isTier(uint24 fee) internal pure returns (bool) {
        return fee == uint24(C.TAX_TIER_1) * C.PIPS_PER_BPS || fee == uint24(C.TAX_TIER_2) * C.PIPS_PER_BPS
            || fee == uint24(C.TAX_TIER_3) * C.PIPS_PER_BPS || fee == uint24(C.TAX_TIER_4) * C.PIPS_PER_BPS
            || fee == uint24(C.TAX_TIER_5) * C.PIPS_PER_BPS;
    }

    /// @dev During the limits window, no transaction may buy more than `maxBuyBps` of the supply from the pool, across
    ///      all its swaps (counted in transient storage). Pool-level, so taking the tokens as ERC-6909 claims does not
    ///      get around it.
    function _checkBuyLimit(address token, uint128 tokensOut) internal {
        PoolConfig storage cfg = _configs[token];
        uint256 maxBuyBps = cfg.maxBuyBps;
        if (maxBuyBps == 0 || block.timestamp >= uint256(cfg.launchTime) + cfg.limitsWindow) return;
        bytes32 slot = keccak256(abi.encode(BOUGHT_SLOT, token));
        uint256 bought;
        assembly ("memory-safe") {
            bought := tload(slot)
        }
        bought += tokensOut;
        if (bought > C.TOTAL_SUPPLY * maxBuyBps / C.BPS) revert MaxBuyExceeded();
        assembly ("memory-safe") {
            tstore(slot, bought)
        }
    }

    /// @dev Fee when the quote is the specified amount: out of an exact quote input, or on top of an exact output.
    function _specifiedFee(int256 amountSpecified, uint24 rate) internal pure returns (uint256) {
        return amountSpecified < 0
            ? FullMath.mulDivRoundingUp(uint256(-amountSpecified), rate, C.PIPS)
            : FullMath.mulDivRoundingUp(uint256(amountSpecified), rate, C.PIPS - rate);
    }

    /// @dev afterSwap's share of the fee work. `quoteDelta` is the pool's own quote amount for the swap.
    function _feeAfterSwap(
        address token,
        Currency quote,
        address sender,
        IDexManager.SwapParams calldata params,
        int128 quoteDelta,
        uint24 rate
    ) internal returns (int128) {
        bool exactInput = params.amountSpecified < 0;
        uint256 quoteSwapped = uint256(uint128(quoteDelta < 0 ? -quoteDelta : quoteDelta));
        if (params.zeroForOne == exactInput) {
            // Fee taken in beforeSwap from the requested amount. A price limit that stopped the swap early would
            // leave that fee too big for what traded. The locker's first buy stops at its cap by design and
            // sizes its amount so that only rounding units can be cut.
            if (sender != locker) {
                uint256 fee = _specifiedFee(params.amountSpecified, rate);
                uint256 requested = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
                if (quoteSwapped != (exactInput ? requested - fee : requested + fee)) revert PartialFill();
            }
            return 0;
        }
        uint256 fee2 = params.zeroForOne
            ? FullMath.mulDivRoundingUp(quoteSwapped, rate, C.PIPS - rate) // exact-out buy: on top of the quote in
            : FullMath.mulDivRoundingUp(quoteSwapped, rate, C.PIPS); // exact-in sell: out of the quote out
        if (fee2 == 0) return 0;
        _chargeFee(token, quote, fee2, rate);
        emit SwapFee(token, sender, params.zeroForOne, exactInput, fee2, rate);
        return int256(fee2).toInt128();
    }

    /// @dev Refuses a price past the launch price (no liquidity there) and marks the first crossing of graduation.
    function _checkPrice(address token, PoolKey calldata key) internal {
        PoolConfig storage cfg = _configs[token];
        uint160 sqrtPriceX96 = _sqrtPrice(Dex.id(key));
        if (sqrtPriceX96 > cfg.startSqrtPriceX96) revert PriceAboveStart();
        if (!cfg.graduated && sqrtPriceX96 <= cfg.graduationSqrtPriceX96) {
            cfg.graduated = true;
            emit Graduated(token, sqrtPriceX96);
        }
    }

    /// @dev Settles the hook's side of the fee as a quote claim minted straight to the fee vault, then books the split.
    function _chargeFee(address token, Currency quote, uint256 fee, uint24 rate) internal {
        _mintClaim(address(feeVault), quote, fee);
        feeVault.credit(token, quote, fee, rate);
    }

    // ---------------------------------------------------------------------
    // Unused callbacks (their bits are not registered, so the pool manager never calls them)
    // ---------------------------------------------------------------------

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IDexManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IDexManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IDexManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
