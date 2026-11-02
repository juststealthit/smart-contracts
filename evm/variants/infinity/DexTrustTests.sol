// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {IDexManager, PoolKey} from "./Dex.sol";
import {ProtocolFeeBase} from "../../test/utils/ProtocolFeeBase.sol";

interface IOwnerPausable {
    function pause() external;
    function unpause() external;
}

/// @notice What PancakeSwap's own admin keys can do to Stealth pools: pause the CLPoolManager (halts trading and
///         launches; fee payouts keep working), and switch on a protocol fee of up to 0.4% per direction on any pool
///         (the hook's fee and the books stay exact, ProtocolFeeBase).
abstract contract DexTrustTests is ProtocolFeeBase {
    function _setMaxProtocolFee(PoolKey memory key) internal override returns (uint24) {
        address controller = makeAddr("protocolFeeController");
        vm.prank(dexOwner);
        manager.setProtocolFeeController(IProtocolFeeController(controller));
        uint24 maxFee = 4000 | (4000 << 12);
        vm.prank(controller);
        manager.setProtocolFee(key, maxFee);
        return maxFee;
    }

    function test_pancakePause_haltsTradingAndLaunches_payoutsStillWork() public {
        address token = _launch(TAX, 4 ether);
        uint256 got = _buy(traders[0], token, 1 ether);
        vm.prank(dexOwner);
        IOwnerPausable(address(manager)).pause();

        PoolKey memory key = _key(token);
        vm.prank(traders[0]);
        vm.expectRevert(); // whenNotPaused
        swapRouter.swap{value: 1 ether}(key, IDexManager.SwapParams(true, -1 ether, MIN_PRICE_LIMIT), _settings(), "");
        vm.prank(creator2);
        vm.expectRevert(); // adding the locked positions is refused while paused
        factory.launch(_params(TAX, 4 ether, 0));

        // Fee payouts only touch the Vault, which the CLPoolManager's pause does not stop.
        uint256 owed = vault.coinOwed(token);
        uint256 before = creator.balance;
        vm.prank(creator);
        vault.claimCreator(token);
        assertEq(creator.balance - before, owed);

        vm.prank(dexOwner);
        IOwnerPausable(address(manager)).unpause();
        assertGt(_sell(traders[0], token, got / 2), 0, "trading resumes");
    }
}
