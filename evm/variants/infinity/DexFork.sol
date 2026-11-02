// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IDexManager} from "./Dex.sol";
import {UniversalRouterLib as UR} from "./UniversalRouterLib.sol";

/// @notice The live chain the Infinity build forks in test/fork: BNB Chain. Addresses only; forks are read-only and nothing
///         is ever sent to a network.
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

    uint256 internal constant CHAINS = 1;
    /// @dev BSC USDT (18 decimals).
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    function chain(uint256) internal pure returns (Chain memory) {
        return Chain("bsc", 56, UR.CL_POOL_MANAGER, UR.VAULT, UR.UNIVERSAL_ROUTER, UR.CL_QUOTER, UR.PERMIT2, USDT);
    }

    /// @notice "" if the live contracts are wired the way the Stealth build expects.
    function wiring(Chain memory c) internal view returns (string memory) {
        if (address(IDexManager(c.manager).vault()) != c.settlement) return "the CLPoolManager reads another Vault";
        if (c.settlement.code.length != 8347) return "the Vault is not infinity-core 3891d0c";
        (bool ok, bytes memory ret) = c.settlement.staticcall(abi.encodeCall(IVault.isAppRegistered, (c.manager)));
        if (!ok || !abi.decode(ret, (bool))) return "the CLPoolManager is not a registered app";
        (ok, ret) = UR.CL_POSITION_MANAGER.staticcall(abi.encodeWithSignature("permit2()"));
        if (!ok || abi.decode(ret, (address)) != c.permit2) return "Permit2 is not PancakeSwap's";
        if (c.router.code.length == 0 || c.quoter.code.length == 0) return "no code at the router or quoter";
        return "";
    }
}
