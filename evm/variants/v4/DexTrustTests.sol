// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "./Dex.sol";
import {ProtocolFeeBase} from "../../test/utils/ProtocolFeeBase.sol";

/// @notice What Uniswap's own admin can do to Stealth pools: there is no pause on v4, and the owner can name a
///         protocol-fee controller, which can take up to 0.1% per direction on a live pool. The hook's fee and the
///         books stay exact (ProtocolFeeBase).
abstract contract DexTrustTests is ProtocolFeeBase {
    function _setMaxProtocolFee(PoolKey memory key) internal override returns (uint24) {
        address controller = makeAddr("protocolFeeController");
        vm.prank(dexOwner);
        manager.setProtocolFeeController(controller);
        uint24 maxFee = 1000 | (1000 << 12);
        vm.prank(controller);
        manager.setProtocolFee(key, maxFee);
        return maxFee;
    }

    function test_v4_hasNoPause_tradingAndPayoutsCannotBeHalted() public {
        address token = _launch(TAX, 4 ether);
        uint256 got = _buy(traders[0], token, 1 ether);
        vm.prank(dexOwner);
        (bool ok,) = address(manager).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok, "the v4 PoolManager has no pause");
        assertGt(_sell(traders[0], token, got / 2), 0, "trading goes on");
        vm.prank(creator);
        assertGt(vault.claimCreator(token), 0, "payouts go on");
    }

    /// @notice Only the owner can name the controller, and only the controller can set the fee.
    function test_v4_protocolFee_gated() public {
        address token = _launch(TAX, 4 ether);
        PoolKey memory key = _key(token);
        vm.prank(attacker);
        vm.expectRevert();
        manager.setProtocolFeeController(attacker);
        vm.prank(attacker);
        vm.expectRevert();
        manager.setProtocolFee(key, 1000);
    }
}
