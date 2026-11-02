// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {Dex, DexCallback, IDexManager, PoolKey, Currency} from "./Dex.sol";
import {UniversalRouterLib as UR} from "./UniversalRouterLib.sol";

/// @notice Reads the settlement contract's pending `sync` from a test contract.
library DexTestLib {
    function syncedCurrency(IDexManager manager) internal view returns (Currency synced) {
        (synced,) = manager.vault().getVaultReserve();
    }
}

/// @notice The PancakeSwap Infinity side of the test base: places the production bytecode from BSC mainnet (Vault,
///         CLPoolManager, CLQuoter, Universal Router, Permit2) at the real addresses, and reads pool state.
abstract contract DexTest is Test {
    string internal constant DEX_NAME = "infinity";
    /// @dev Storage slots in the deployed bytecode (forge inspect storageLayout at infinity-core 3891d0c).
    uint256 internal constant VAULT_OWNER_SLOT = 3;
    uint256 internal constant CLPM_OWNER_SLOT = 0;

    IDexManager internal manager;
    address internal settlementAddr;
    address internal dexOwner = makeAddr("dexOwner");

    function _dexRouter() internal view virtual returns (address) {
        return UR.UNIVERSAL_ROUTER;
    }

    function _dexQuoter() internal view virtual returns (address) {
        return UR.CL_QUOTER;
    }

    function _dexPermit2() internal view virtual returns (address) {
        return UR.PERMIT2;
    }

    /// @dev Local tests place the production bytecode; fork tests override this to use the live contracts.
    function _installDex() internal virtual {
        _etchFixture(UR.VAULT, "Vault");
        _etchFixture(UR.CL_POOL_MANAGER, "CLPoolManager");
        _etchFixture(UR.CL_QUOTER, "CLQuoter");
        _etchFixture(UR.UNIVERSAL_ROUTER, "UniversalRouter");
        _etchFixture(UR.PERMIT2, "Permit2");
        manager = IDexManager(UR.CL_POOL_MANAGER);
        settlementAddr = UR.VAULT;
        // Owners live in storage, which etching leaves empty: give both to a stand-in for PancakeSwap's owner.
        vm.store(UR.VAULT, bytes32(VAULT_OWNER_SLOT), bytes32(uint256(uint160(dexOwner))));
        vm.store(UR.CL_POOL_MANAGER, bytes32(CLPM_OWNER_SLOT), bytes32(uint256(uint160(dexOwner))));
        vm.prank(dexOwner);
        IVault(UR.VAULT).registerApp(UR.CL_POOL_MANAGER);
    }

    function _etchFixture(address at, string memory name) internal {
        vm.etch(at, vm.parseBytes(vm.trim(vm.readFile(string.concat("test/fixtures/", name, ".bsc.hex")))));
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
        return manager.getLiquidity(PoolId.wrap(id), owner, lower, upper, salt);
    }

    function _feeGrowthGlobals(bytes32 id) internal view returns (uint256, uint256) {
        return manager.getFeeGrowthGlobals(PoolId.wrap(id));
    }

    /// @dev What the Vault tracks as the CLPoolManager's own reserves.
    function _dexPoolReserves(Currency c) internal view returns (uint256) {
        return IVault(settlementAddr).reservesOfApp(address(manager), c);
    }

    function _dexClaimOf(address owner, Currency c) internal view returns (uint256) {
        return IVault(settlementAddr).balanceOf(owner, c);
    }

    /// @dev Lets `spender` move the caller's claims.
    function _dexApproveClaims(address spender, Currency c, uint256 amount) internal {
        IVault(settlementAddr).approve(spender, c, amount);
    }

    function _dexTransferClaims(address to, Currency c, uint256 amount) internal {
        IVault(settlementAddr).transfer(to, c, amount);
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
        return int24(uint24(uint256(k.parameters) >> 16));
    }

    function _keyManager(PoolKey memory k) internal pure returns (address) {
        return address(k.poolManager);
    }

    function _withTickSpacing(PoolKey memory k, int24 tickSpacing) internal pure returns (PoolKey memory) {
        k.parameters = bytes32((uint256(uint24(tickSpacing)) << 16) | Dex.HOOKS_BITMAP);
        return k;
    }

    /// @dev True: an Infinity key names its manager.
    function _withManager(PoolKey memory k, address poolManager) internal pure returns (PoolKey memory, bool) {
        k.poolManager = IPoolManager(poolManager);
        return (k, true);
    }

    /// @dev Calls `target`'s lock callback, as the DEX would.
    function _callLockCallback(address target, bytes memory data) internal {
        DexCallback(target).lockAcquired(data);
    }

    function _dexTransferClaimsFrom(address from, address to, Currency c, uint256 amount) internal {
        IVault(settlementAddr).transferFrom(from, to, c, amount);
    }

    function _dexFeeGrowthGlobals(bytes32 id) internal view returns (uint256, uint256) {
        return manager.getFeeGrowthGlobals(PoolId.wrap(id));
    }

    /// @dev A hookless pool key on this DEX.
    function _dexPlainKey(Currency c0, Currency c1, uint24 fee, int24 tickSpacing)
        internal
        view
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(manager)),
            fee: fee,
            parameters: bytes32(uint256(uint24(tickSpacing)) << 16)
        });
    }

    /// @dev The error the pool manager reverts with when `hook` reverts with `reason` in callback `callback`.
    function _dexHookError(address hook, bytes4 callback, bytes memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector, hook, callback, reason, abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev The settlement callback every lock-opening contract exposes.
    function _dexCallbackSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("lockAcquired(bytes)"));
    }
}
