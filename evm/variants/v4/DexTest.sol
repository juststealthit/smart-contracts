// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {DexCallback, IDexManager, PoolKey, Currency, IDexHooks} from "./Dex.sol";
import {UniversalRouterLib as UR} from "./UniversalRouterLib.sol";

/// @notice Reads the settlement contract's pending `sync` from a test contract.
library DexTestLib {
    function syncedCurrency(IDexManager manager) internal view returns (Currency) {
        return TransientStateLibrary.getSyncedCurrency(manager);
    }
}

/// @notice The Uniswap v4 side of the test base: places the live Robinhood Chain bytecode of the PoolManager (identical
///         to HyperEVM's apart from its own address), the Universal Router, the V4Quoter and Permit2 at their real
///         addresses, and reads pool state the v4 way.
abstract contract DexTest is Test {
    using StateLibrary for IDexManager;

    string internal constant DEX_NAME = "v4";
    /// @dev solmate `Owned`: storage slot 0.
    uint256 internal constant MANAGER_OWNER_SLOT = 0;

    IDexManager internal manager;
    address internal settlementAddr;
    address internal dexOwner = makeAddr("dexOwner");

    function _dexRouter() internal view virtual returns (address) {
        return UR.UNIVERSAL_ROUTER;
    }

    function _dexQuoter() internal view virtual returns (address) {
        return UR.V4_QUOTER;
    }

    function _dexPermit2() internal view virtual returns (address) {
        return UR.PERMIT2;
    }

    /// @dev Local tests place the production bytecode; fork tests override this to use the live contracts.
    function _installDex() internal virtual {
        _etchFixture(UR.POOL_MANAGER, "PoolManager");
        _etchFixture(UR.UNIVERSAL_ROUTER, "UniversalRouter");
        _etchFixture(UR.V4_QUOTER, "V4Quoter");
        _etchFixture(UR.PERMIT2, "Permit2");
        manager = IDexManager(UR.POOL_MANAGER);
        settlementAddr = UR.POOL_MANAGER;
        vm.store(UR.POOL_MANAGER, bytes32(MANAGER_OWNER_SLOT), bytes32(uint256(uint160(dexOwner))));
    }

    function _etchFixture(address at, string memory name) internal {
        vm.etch(at, vm.parseBytes(vm.trim(vm.readFile(string.concat("test/fixtures/", name, ".robinhood.hex")))));
        vm.label(at, name);
    }

    function _getSlot0(bytes32 id)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return manager.getSlot0(PoolId.wrap(id));
    }

    function _poolLiquidity(bytes32 id) internal view returns (uint128) {
        return manager.getLiquidity(PoolId.wrap(id));
    }

    function _positionLiquidity(bytes32 id, address owner, int24 lower, int24 upper, bytes32 salt)
        internal
        view
        returns (uint128)
    {
        return manager.getPositionLiquidity(PoolId.wrap(id), Position.calculatePositionKey(owner, lower, upper, salt));
    }

    function _feeGrowthGlobals(bytes32 id) internal view returns (uint256, uint256) {
        return manager.getFeeGrowthGlobals(PoolId.wrap(id));
    }

    /// @dev v4 keeps every pool's funds together, so the pools' own reserves are the PoolManager's balance.
    function _dexPoolReserves(Currency c) internal view returns (uint256) {
        return c.balanceOf(address(manager));
    }

    function _dexClaimOf(address owner, Currency c) internal view returns (uint256) {
        return manager.balanceOf(owner, c.toId());
    }

    /// @dev Lets `spender` move `owner`'s claims (the caller must be `owner`).
    function _dexApproveClaims(address spender, Currency c, uint256 amount) internal {
        IERC6909Claims(address(manager)).approve(spender, c.toId(), amount);
    }

    function _dexTransferClaims(address to, Currency c, uint256 amount) internal {
        manager.transfer(to, c.toId(), amount);
    }

    /// @dev What a pool manager reverts with when a hook callback reverts with `reason`.
    function _wrappedHookError(address hook, bytes4 callback, bytes memory reason)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            hook,
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _keyTickSpacing(PoolKey memory k) internal pure returns (int24) {
        return k.tickSpacing;
    }

    /// @dev A v4 key does not name its manager.
    function _keyManager(PoolKey memory) internal view returns (address) {
        return address(manager);
    }

    function _withTickSpacing(PoolKey memory k, int24 tickSpacing) internal pure returns (PoolKey memory) {
        k.tickSpacing = tickSpacing;
        return k;
    }

    /// @dev False: a v4 key has no manager field to forge.
    function _withManager(PoolKey memory k, address) internal pure returns (PoolKey memory, bool) {
        return (k, false);
    }

    /// @dev Calls `target`'s lock callback, as the DEX would.
    function _callLockCallback(address target, bytes memory data) internal {
        DexCallback(target).unlockCallback(data);
    }

    function _dexTransferClaimsFrom(address from, address to, Currency c, uint256 amount) internal {
        manager.transferFrom(from, to, c.toId(), amount);
    }

    function _dexFeeGrowthGlobals(bytes32 id) internal view returns (uint256, uint256) {
        return manager.getFeeGrowthGlobals(PoolId.wrap(id));
    }

    /// @dev A hookless pool key on this DEX.
    function _dexPlainKey(Currency c0, Currency c1, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IDexHooks(address(0))});
    }

    /// @dev The error the pool manager reverts with when `hook` reverts with `reason` in callback `callback`.
    function _dexHookError(address hook, bytes4 callback, bytes memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector, hook, callback, reason, abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev The settlement callback every lock-opening contract exposes.
    function _dexCallbackSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("unlockCallback(bytes)"));
    }
}
