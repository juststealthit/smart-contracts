// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey, Currency, IDexHooks} from "./Dex.sol";

/// @dev v4-periphery's PathKey at the deployed router's version (only the ABI matters here).
struct PathKey {
    Currency intermediateCurrency;
    uint24 fee;
    int24 tickSpacing;
    IDexHooks hooks;
    bytes hookData;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

interface IDexQuoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);

    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountIn, uint256 gasEstimate);

    struct QuoteExactParams {
        Currency exactCurrency;
        PathKey[] path;
        uint128 exactAmount;
    }

    function quoteExactInput(QuoteExactParams memory params) external returns (uint256 amountOut, uint256 gasEstimate);
}

/// @notice Builds Uniswap v4 Universal Router calls for a Stealth pool (the quote is currency0, the token
///         currency1). A buy is zeroForOne. The front end sends exactly these bytes. Proven against the deployed
///         router bytecode by test/fork/Routing.fork.t.sol (live state) and test/unit/Routing.t.sol (local).
library UniversalRouterLib {
    // Uniswap's canonical v4 deployment on Robinhood Chain mainnet (4663).
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    // Uniswap v4 on HyperEVM (999).
    address internal constant HYPER_UNIVERSAL_ROUTER = 0x9aFe3C497e19501DB228F28CdBdD29bC98F65DBa;
    address internal constant HYPER_V4_QUOTER = 0x108Bfe38532C98f8Cd8D7Ab49c9dDAa3675a1c5e;
    address internal constant HYPER_POOL_MANAGER = 0x12D4Fd9C5DeDd00ab8a0bCe2CF0167bbf94b6B1F;
    // Uniswap v4 on Base (8453). Its Universal Router is an older build: nothing here goes through it.
    address internal constant BASE_UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant BASE_V4_QUOTER = 0x0d5e0F971ED27FBfF6c2837bf31316121532048D;
    address internal constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    // Uniswap v4 on Arc (5042): Robinhood Chain's addresses. Uniswap's docs don't list Arc, so test/fork/NewChains.fork.t.sol
    // proves they behave as v4.
    address internal constant ARC_UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant ARC_V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant ARC_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    // Ethereum, Arbitrum One and Avalanche C-Chain, from Uniswap's v4 deployments page (2026-11-05)
    address internal constant ETH_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant ETH_V4_QUOTER = 0x99bd42B2B22e531f283b7F8a86dFf631EB16A9D1;
    address internal constant ETH_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    address internal constant ARB_UNIVERSAL_ROUTER = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3;
    address internal constant ARB_V4_QUOTER = 0x8928074CA1b241D8Ec02815881c1Af11E8bC5219;
    address internal constant ARB_POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;

    address internal constant AVAX_UNIVERSAL_ROUTER = 0x94b75331AE8d42C1b61065089B7d48FE14aA73b7;
    address internal constant AVAX_V4_QUOTER = 0xf27e532878B622d6b916F524E8711880107D4eF0;
    address internal constant AVAX_POOL_MANAGER = 0x06380C0e0912312B5150364B9DC4542BA0DbBc85;
    /// @dev Uniswap's canonical Permit2, the same on every chain.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes1 internal constant DEX_SWAP = 0x10;
    bytes1 internal constant SWEEP = 0x04;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SWAP_EXACT_IN = 0x07;
    uint8 internal constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;
    address internal constant MSG_SENDER = address(1); // the router's alias for its caller

    /// @dev The single-pool params the deployed router reads, `minHopPriceX36` included. The five-field encoding of
    ///      older v4-periphery only works by luck on a native pair (the router then reads currency0, zero, as the
    ///      length of hookData) and reverts on any ERC-20 pair: found by the local ERC-20 routing tests.
    struct ExactInSingle {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @dev Multi-hop exact input.
    struct ExactIn {
        Currency currencyIn;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    struct ExactOutSingle {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @notice Exact-input swap. A BNB-paired buy sends `amountIn` as value; anything paid in an ERC-20 (a sell, or
    ///         a buy with an ERC-20 quote) needs a Permit2 allowance for the router.
    function exactIn(PoolKey memory key, bool buy, uint256 amountIn, uint256 minOut)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInSingle(key, buy, uint128(amountIn), uint128(minOut), 0, ""));
        params[1] = abi.encode(buy ? key.currency0 : key.currency1, amountIn);
        params[2] = abi.encode(buy ? key.currency1 : key.currency0, minOut);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL), params);
        commands = abi.encodePacked(DEX_SWAP);
    }

    /// @notice Exact-input multi-hop swap along `path` (e.g. native -> Stealth coin A -> Stealth coin B paired with A).
    ///         Every hop through a Stealth pool pays that pool's fee in that pool's quote.
    function exactInPath(Currency currencyIn, PathKey[] memory path, uint256 amountIn, uint256 minOut)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactIn(currencyIn, path, new uint256[](path.length), uint128(amountIn), uint128(minOut)));
        params[1] = abi.encode(currencyIn, amountIn);
        params[2] = abi.encode(path[path.length - 1].intermediateCurrency, minOut);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_IN, SETTLE_ALL, TAKE_ALL), params);
        commands = abi.encodePacked(DEX_SWAP);
    }

    /// @notice The PathKey hop into a Stealth pool's other currency.
    function hop(PoolKey memory key, Currency to) internal pure returns (PathKey memory) {
        return PathKey({
            intermediateCurrency: to,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: key.hooks,
            hookData: ""
        });
    }

    /// @notice Exact-output buy: for BNB send `maxIn` as value, and whatever isn't used is swept back to the caller;
    ///         for an ERC-20 quote the router pulls only what the swap needs through Permit2.
    function exactOutBuy(PoolKey memory key, uint256 amountOut, uint256 maxIn)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactOutSingle(key, true, uint128(amountOut), uint128(maxIn), 0, ""));
        params[1] = abi.encode(key.currency0, maxIn);
        params[2] = abi.encode(key.currency1, amountOut);
        inputs = new bytes[](2);
        inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_OUT_SINGLE, SETTLE_ALL, TAKE_ALL), params);
        inputs[1] = abi.encode(key.currency0, MSG_SENDER, uint256(0));
        commands = abi.encodePacked(DEX_SWAP, SWEEP);
    }

    /// @notice Exact-output sell: receive exactly `amountOut` of the quote, paying at most `maxIn` tokens through
    ///         Permit2.
    function exactOutSell(PoolKey memory key, uint256 amountOut, uint256 maxIn)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactOutSingle(key, false, uint128(amountOut), uint128(maxIn), 0, ""));
        params[1] = abi.encode(key.currency1, maxIn);
        params[2] = abi.encode(key.currency0, amountOut);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_OUT_SINGLE, SETTLE_ALL, TAKE_ALL), params);
        commands = abi.encodePacked(DEX_SWAP);
    }

    function quoteIn(address quoter, PoolKey memory key, bool buy, uint256 amountIn) internal returns (uint256 out) {
        (out,) = IDexQuoter(quoter).quoteExactInputSingle(
            IDexQuoter.QuoteExactSingleParams(key, buy, uint128(amountIn), "")
        );
    }

    function quoteOut(address quoter, PoolKey memory key, bool buy, uint256 amountOut)
        internal
        returns (uint256 amountIn)
    {
        (amountIn,) = IDexQuoter(quoter).quoteExactOutputSingle(
            IDexQuoter.QuoteExactSingleParams(key, buy, uint128(amountOut), "")
        );
    }
}
