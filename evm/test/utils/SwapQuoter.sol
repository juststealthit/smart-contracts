// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DexBase, DexCallback, IDexManager, PoolKey, BalanceDelta} from "@dex/Dex.sol";

/// @notice Quotes a swap the way the DEX's own quoter does: runs it inside a settlement lock, then reverts with the
///         result. The swap goes through the hook exactly like a real one. Unlike the deployed quoter it takes any
///         price limit; the tests compare it with the deployed quoter too (Routing tests).
contract SwapQuoter is DexCallback {
    error QuoteResult(int128 amount0, int128 amount1);
    error NotFilled();

    constructor(IDexManager manager_) DexBase(manager_) {}

    /// @return amountIn What the swap takes. @return amountOut What it gives.
    function quote(PoolKey memory key, IDexManager.SwapParams memory params)
        external
        returns (uint256 amountIn, uint256 amountOut)
    {
        try this.run(key, params) {}
        catch (bytes memory reason) {
            if (reason.length != 68 || bytes4(reason) != QuoteResult.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
            (int128 a0, int128 a1) = abi.decode(_tail(reason), (int128, int128));
            (int128 inDelta, int128 outDelta) = params.zeroForOne ? (a0, a1) : (a1, a0);
            amountIn = uint256(uint128(-inDelta));
            amountOut = uint256(uint128(outDelta));
            if (params.amountSpecified > 0 && amountOut != uint256(params.amountSpecified)) revert NotFilled();
        }
    }

    function run(PoolKey memory key, IDexManager.SwapParams memory params) external {
        _lockRaw(abi.encode(key, params));
    }

    function _onLock(bytes calldata data) internal override returns (bytes memory) {
        (PoolKey memory key, IDexManager.SwapParams memory params) =
            abi.decode(data, (PoolKey, IDexManager.SwapParams));
        BalanceDelta delta = poolManager.swap(key, params, "");
        revert QuoteResult(delta.amount0(), delta.amount1());
    }

    function _tail(bytes memory reason) private pure returns (bytes memory out) {
        out = new bytes(reason.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = reason[i + 4];
        }
    }
}
