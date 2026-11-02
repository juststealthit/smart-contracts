// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    ICLHooks as IDexHooks,
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_AFTER_INITIALIZE_OFFSET,
    HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_AFTER_SWAP_OFFSET,
    HOOKS_BEFORE_DONATE_OFFSET,
    HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET
} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager as IDexManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {SqrtPriceMath} from "infinity-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {SwapMath} from "infinity-core/src/pool-cl/libraries/SwapMath.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";

/// @title Dex (PancakeSwap Infinity CL)
/// @notice Everything the Stealth contracts need from the DEX, for the PancakeSwap Infinity build. The Uniswap v4
///         build has a file with the same names in variants/v4/. No Stealth logic lives here: only pool keys, tick
///         maths names and one-line forwards to the Vault and the CLPoolManager.
library Dex {
    string internal constant NAME = "pancakeswap-infinity";

    /// @notice Infinity reads hook permissions from a bitmap, so the hook's address carries no bits.
    uint160 internal constant HOOK_ADDRESS_MASK = 0;
    uint160 internal constant HOOK_ADDRESS_FLAGS = 0;

    /// @notice The callbacks the hook registers (= 0x0dc7).
    uint16 internal constant HOOKS_BITMAP = uint16(
        (1 << HOOKS_BEFORE_INITIALIZE_OFFSET) | (1 << HOOKS_AFTER_INITIALIZE_OFFSET)
            | (1 << HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET) | (1 << HOOKS_BEFORE_SWAP_OFFSET) | (1 << HOOKS_AFTER_SWAP_OFFSET)
            | (1 << HOOKS_BEFORE_DONATE_OFFSET) | (1 << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET)
            | (1 << HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET)
    );

    uint160 internal constant MIN_SQRT_PRICE = TickMath.MIN_SQRT_RATIO;
    uint160 internal constant MAX_SQRT_PRICE = TickMath.MAX_SQRT_RATIO;

    /// @notice Pool key of `token` paired with `quote`: LP fee 0, tick spacing as given. The quote is always currency0.
    function key(Currency quote, address token, address hook, address manager, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: quote,
            currency1: Currency.wrap(token),
            hooks: IHooks(hook),
            poolManager: IPoolManager(manager),
            fee: fee,
            parameters: _parameters(tickSpacing)
        });
    }

    /// @notice True if `k` has these pool settings.
    function matches(PoolKey calldata k, address manager, uint24 fee, int24 tickSpacing) internal pure returns (bool) {
        return k.fee == fee && k.parameters == _parameters(tickSpacing) && address(k.poolManager) == manager;
    }

    /// @dev Bits 0-15 repeat the hook's bitmap (the CLPoolManager checks it), bits 16-39 are the tick spacing.
    function _parameters(int24 tickSpacing) private pure returns (bytes32) {
        return bytes32((uint256(uint24(tickSpacing)) << 16) | uint256(HOOKS_BITMAP));
    }

    function id(PoolKey memory k) internal pure returns (bytes32) {
        return PoolId.unwrap(k.toId());
    }

    function sqrtAtTick(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    function tickAtSqrt(uint160 sqrtPriceX96) internal pure returns (int24) {
        return TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    function minUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return TickMath.minUsableTick(tickSpacing);
    }

    function isNative(Currency c) internal pure returns (bool) {
        return c.isNative();
    }
}

/// @notice The settlement calls, which v4 has on the PoolManager and Infinity on its Vault.
abstract contract DexBase {
    /// @notice The chain's CLPoolManager.
    IDexManager public immutable poolManager;
    /// @notice Where funds and ERC-6909 claims live: the Infinity Vault.
    IVault public immutable settlement;

    error ZeroAddress();

    constructor(IDexManager manager_) {
        if (address(manager_) == address(0)) revert ZeroAddress();
        poolManager = manager_;
        settlement = manager_.vault();
    }

    function _sqrtPrice(bytes32 id) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(PoolId.wrap(id));
    }

    function _isLocked() internal view returns (bool) {
        return settlement.getLocker() != address(0);
    }

    function _lockRaw(bytes memory data) internal returns (bytes memory) {
        return settlement.lock(data);
    }

    function _sync(Currency c) internal {
        settlement.sync(c);
    }

    function _settle() internal returns (uint256) {
        return settlement.settle();
    }

    function _settleNative(uint256 amount) internal returns (uint256) {
        return settlement.settle{value: amount}();
    }

    function _take(Currency c, address to, uint256 amount) internal {
        settlement.take(c, to, amount);
    }

    function _mintClaim(address to, Currency c, uint256 amount) internal {
        settlement.mint(to, c, amount);
    }

    function _burnClaim(address from, Currency c, uint256 amount) internal {
        settlement.burn(from, c, amount);
    }

    function _claimOf(address owner, Currency c) internal view returns (uint256) {
        return settlement.balanceOf(owner, c);
    }
}

/// @notice A contract that opens settlement locks. Calls `_onLock` from the Vault's lock callback.
abstract contract DexCallback is DexBase, ILockCallback {
    error NotSettlement();

    /// @dev Only reachable through this contract's own `_lockRaw` calls.
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(settlement)) revert NotSettlement();
        return _onLock(data);
    }

    function _onLock(bytes calldata data) internal virtual returns (bytes memory);
}

/// @notice Base of the hook. Infinity reads the callbacks from this bitmap, which pool keys must repeat.
abstract contract DexHook is DexBase, IDexHooks {
    function getHooksRegistrationBitmap() external pure returns (uint16) {
        return Dex.HOOKS_BITMAP;
    }
}
