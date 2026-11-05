// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UniversalRouterLib as UR} from "./UniversalRouterLib.sol";

/// @notice The live chains the Uniswap v4 build forks in test/fork: Robinhood Chain, HyperEVM, Base, Arc, Ethereum, Arbitrum One and
///         Avalanche C-Chain. Addresses only; forks are
///         read-only and nothing is ever sent to a network.
library DexFork {
    struct Chain {
        string rpc; // an `rpc_endpoints` alias in foundry.toml: public RPCs only
        uint256 chainId;
        address manager;
        address settlement;
        address router;
        address quoter;
        address permit2;
        address realQuote; // a real ERC-20 to pair with, or 0
    }

    uint256 internal constant CHAINS = 7;

    function chain(uint256 i) internal pure returns (Chain memory) {
        if (i == 0) {
            return Chain("robinhood", 4663, UR.POOL_MANAGER, UR.POOL_MANAGER, UR.UNIVERSAL_ROUTER, UR.V4_QUOTER, UR.PERMIT2, address(0));
        }
        if (i == 2) {
            return Chain("base", 8453, UR.BASE_POOL_MANAGER, UR.BASE_POOL_MANAGER, UR.BASE_UNIVERSAL_ROUTER, UR.BASE_V4_QUOTER, UR.PERMIT2, address(0));
        }
        if (i == 4) {
            return Chain("ethereum", 1, UR.ETH_POOL_MANAGER, UR.ETH_POOL_MANAGER, UR.ETH_UNIVERSAL_ROUTER, UR.ETH_V4_QUOTER, UR.PERMIT2, address(0));
        }
        if (i == 5) {
            return Chain("arbitrum", 42161, UR.ARB_POOL_MANAGER, UR.ARB_POOL_MANAGER, UR.ARB_UNIVERSAL_ROUTER, UR.ARB_V4_QUOTER, UR.PERMIT2, address(0));
        }
        if (i == 6) {
            return Chain(
                "avalanche", 43114, UR.AVAX_POOL_MANAGER, UR.AVAX_POOL_MANAGER, UR.AVAX_UNIVERSAL_ROUTER, UR.AVAX_V4_QUOTER, UR.PERMIT2, address(0)
            );
        }
        if (i == 3) {
            return Chain("arc", 5042, UR.ARC_POOL_MANAGER, UR.ARC_POOL_MANAGER, UR.ARC_UNIVERSAL_ROUTER, UR.ARC_V4_QUOTER, UR.PERMIT2, address(0));
        }
        return Chain(
            "hyperevm",
            999,
            UR.HYPER_POOL_MANAGER,
            UR.HYPER_POOL_MANAGER,
            UR.HYPER_UNIVERSAL_ROUTER,
            UR.HYPER_V4_QUOTER,
            UR.PERMIT2,
            address(0)
        );
    }

    /// @notice "" if the live contracts are wired the way the Stealth build expects.
    function wiring(Chain memory c) internal view returns (string memory) {
        if (c.manager.code.length == 0 || c.router.code.length == 0) return "no code at the pool manager or router";
        if (c.quoter.code.length == 0 || c.permit2.code.length == 0) return "no code at the quoter or Permit2";
        (bool ok, bytes memory ret) = c.quoter.staticcall(abi.encodeWithSignature("poolManager()"));
        if (!ok || abi.decode(ret, (address)) != c.manager) return "the quoter reads another pool manager";
        (ok, ret) = c.router.staticcall(abi.encodeWithSignature("poolManager()"));
        if (!ok || abi.decode(ret, (address)) != c.manager) return "the router reads another pool manager";
        return "";
    }
}
