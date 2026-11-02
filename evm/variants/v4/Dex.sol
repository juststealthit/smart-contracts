// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks as IDexHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager as IDexManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title Dex (Uniswap v4)
/// @notice Everything the Stealth contracts need from the DEX, for the Uniswap v4 build. The PancakeSwap Infinity build
///         has a file with the same names in variants/infinity/. No Stealth logic lives here: only pool keys, tick
///         maths names and one-line forwards to the pool manager.
library Dex {
    string internal constant NAME = "uniswap-v4";

    /// @notice The hook's address must carry exactly these bits (v4 reads permissions from the address).
    uint160 internal constant HOOK_ADDRESS_MASK = Hooks.ALL_HOOK_MASK;
    uint160 internal constant HOOK_ADDRESS_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    uint160 internal constant MIN_SQRT_PRICE = TickMath.MIN_SQRT_PRICE;
    uint160 internal constant MAX_SQRT_PRICE = TickMath.MAX_SQRT_PRICE;

    /// @notice Pool key of `token` paired with `quote`: LP fee 0, tick spacing as given. The quote is always currency0.
    function key(Currency quote, address token, address hook, address, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: quote,
            currency1: Currency.wrap(token),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IDexHooks(hook)
        });
    }

    /// @notice True if `k` has these pool settings.
    function matches(PoolKey calldata k, address, uint24 fee, int24 tickSpacing) internal pure returns (bool) {
        return k.fee == fee && k.tickSpacing == tickSpacing;
    }

    function id(PoolKey memory k) internal pure returns (bytes32) {
        return PoolId.unwrap(k.toId());
    }

    function sqrtAtTick(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function tickAtSqrt(uint160 sqrtPriceX96) internal pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    function minUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return TickMath.minUsableTick(tickSpacing);
    }

    function isNative(Currency c) internal pure returns (bool) {
        return c.isAddressZero();
    }
}

/// @notice The settlement calls, which v4 has on the PoolManager and Infinity on its Vault.
abstract contract DexBase {
    using StateLibrary for IDexManager;
    using TransientStateLibrary for IDexManager;

    /// @notice The chain's pool manager.
    IDexManager public immutable poolManager;
    /// @notice Where funds and ERC-6909 claims live. On v4, the PoolManager itself.
    IDexManager public immutable settlement;

    error ZeroAddress();

    constructor(IDexManager manager_) {
        if (address(manager_) == address(0)) revert ZeroAddress();
        poolManager = manager_;
        settlement = manager_;
    }

    function _sqrtPrice(bytes32 id) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(PoolId.wrap(id));
    }

    function _isLocked() internal view returns (bool) {
        return poolManager.isUnlocked();
    }

    function _lockRaw(bytes memory data) internal returns (bytes memory) {
        return poolManager.unlock(data);
    }

    function _sync(Currency c) internal {
        poolManager.sync(c);
    }

    function _settle() internal returns (uint256) {
        return poolManager.settle();
    }

    function _settleNative(uint256 amount) internal returns (uint256) {
        return poolManager.settle{value: amount}();
    }

    function _take(Currency c, address to, uint256 amount) internal {
        poolManager.take(c, to, amount);
    }

    function _mintClaim(address to, Currency c, uint256 amount) internal {
        poolManager.mint(to, c.toId(), amount);
    }

    function _burnClaim(address from, Currency c, uint256 amount) internal {
        poolManager.burn(from, c.toId(), amount);
    }

    function _claimOf(address owner, Currency c) internal view returns (uint256) {
        return poolManager.balanceOf(owner, c.toId());
    }
}

/// @notice A contract that opens settlement locks. Calls `_onLock` from v4's unlock callback.
abstract contract DexCallback is DexBase, IUnlockCallback {
    error NotSettlement();

    /// @dev Only reachable through this contract's own `_lockRaw` calls.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotSettlement();
        return _onLock(data);
    }

    function _onLock(bytes calldata data) internal virtual returns (bytes memory);
}

/// @notice Base of the hook. On v4 the hook's permissions are its address, so a wrongly mined salt fails here.
abstract contract DexHook is DexBase, IDexHooks {
    error HookAddressMismatch();

    constructor() {
        if (uint160(address(this)) & Dex.HOOK_ADDRESS_MASK != Dex.HOOK_ADDRESS_FLAGS) revert HookAddressMismatch();
    }
}
