// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {DexHook, Dex} from "./Dex.sol";
import {BaseTest} from "../../test/utils/BaseTest.sol";
import {StealthHook} from "../../src/StealthHook.sol";
import {IStealthFeeVault} from "../../src/interfaces/IStealth.sol";

/// @notice Uniswap v4 only: the hook's permissions are its address.
abstract contract DexHookTests is BaseTest {
    function test_dex_permissionBits_withReturnDeltas() public view {
        uint160 a = uint160(address(hook));
        assertEq(a & Hooks.ALL_HOOK_MASK, Dex.HOOK_ADDRESS_FLAGS);
        // bits from Hooks: 13 beforeInitialize, 12 afterInitialize, 11 beforeAddLiquidity, 10 afterAdd,
        // 9 beforeRemove, 8 afterRemove, 7 beforeSwap, 6 afterSwap, 5 beforeDonate, 4 afterDonate,
        // 3 beforeSwapReturnsDelta, 2 afterSwapReturnsDelta, 1 afterAddReturnsDelta, 0 afterRemoveReturnsDelta
        for (uint256 i; i < 14; ++i) {
            bool on = (a >> i) & 1 == 1;
            bool want = i == 13 || i == 12 || i == 11 || i == 7 || i == 6 || i == 5 || i == 3 || i == 2;
            assertEq(on, want, string.concat("bit ", vm.toString(i)));
        }
        assertEq(address(hook.feeVault()), address(vault));
        assertEq(hook.locker(), address(locker));
    }

    /// @notice A hook at an address without exactly these bits cannot exist, so no build of it can skip a callback.
    function test_dex_hookAtAnotherAddressCannotDeploy() public {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertTrue(uint160(next) & Dex.HOOK_ADDRESS_MASK != Dex.HOOK_ADDRESS_FLAGS);
        vm.expectRevert(DexHook.HookAddressMismatch.selector);
        new StealthHook(manager, IStealthFeeVault(address(vault)));
    }

    function test_dex_settlementIsThePoolManager() public view {
        assertEq(address(hook.settlement()), address(manager));
        assertEq(address(vault.settlement()), address(manager));
    }
}
