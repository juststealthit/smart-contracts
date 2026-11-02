// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {Dex, PoolKey} from "./Dex.sol";
import {BaseTest} from "../../test/utils/BaseTest.sol";

/// @notice PancakeSwap Infinity only: the hook's permissions are a bitmap, which every pool key must repeat.
abstract contract DexHookTests is BaseTest {
    function test_dex_permissionBits_withReturnDeltas() public view {
        uint16 b = hook.getHooksRegistrationBitmap();
        assertEq(b, Dex.HOOKS_BITMAP);
        assertEq(b, 0x0dc7, "hook bitmap");
        // bit offsets from ICLHooks: 0 beforeInitialize, 1 afterInitialize, 2 beforeAddLiquidity, 3 afterAdd,
        // 4 beforeRemove, 5 afterRemove, 6 beforeSwap, 7 afterSwap, 8 beforeDonate, 9 afterDonate,
        // 10 beforeSwapReturnsDelta, 11 afterSwapReturnsDelta, 12 afterAddReturnsDelta, 13 afterRemoveReturnsDelta
        for (uint256 i; i < 16; ++i) {
            bool on = (b >> i) & 1 == 1;
            bool want = i == 0 || i == 1 || i == 2 || i == 6 || i == 7 || i == 8 || i == 10 || i == 11;
            assertEq(on, want, string.concat("bit ", vm.toString(i)));
        }
        assertEq(uint256(_key(address(1)).parameters), (10 << 16) | uint256(b), "pool keys repeat the bitmap");
        assertEq(address(hook.feeVault()), address(vault));
        assertEq(hook.locker(), address(locker));
    }

    /// @notice Infinity reads permissions from the key, but the bitmap must equal the hook's: a key that tries to skip
    ///         beforeInitialize (or any other callback) is refused before the hook is even called.
    function test_dex_keyCannotDropACallback() public {
        address token = _launchWith(creator, TAX, 4 ether, 0);
        PoolKey memory sneaky = _key(token);
        sneaky.parameters = bytes32(uint256((10 << 16) | (Dex.HOOKS_BITMAP & ~uint16(1))));
        vm.startPrank(attacker);
        vm.expectRevert(Hooks.HookConfigValidationError.selector);
        manager.initialize(sneaky, 1 << 96);
        sneaky.parameters = bytes32(uint256(10 << 16));
        vm.expectRevert(Hooks.HookConfigValidationError.selector);
        manager.initialize(sneaky, 1 << 96);
        vm.stopPrank();
    }

    function test_dex_settlementIsTheVault() public view {
        assertEq(address(hook.settlement()), address(manager.vault()));
        assertEq(address(vault.settlement()), settlementAddr);
    }
}
