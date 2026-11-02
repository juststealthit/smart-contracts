// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey, Currency, IDexHooks} from "./Dex.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";

/// @dev infinity-periphery's PathKey (same fields, vendored as a struct: only ABI matters here).
struct PathKey {
    Currency intermediateCurrency;
    uint24 fee;
    IHooks hooks;
    IPoolManager poolManager;
    bytes hookData;
    bytes32 parameters;
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

/// @notice Builds PancakeSwap Infinity Universal Router calls for a Stealth pool (the quote is currency0, the token
///         currency1). A buy is zeroForOne. The front end sends exactly these bytes. Proven against the deployed
///         router bytecode by test/fork/Routing.fork.t.sol (live state) and test/unit/Routing.t.sol (local).
library UniversalRouterLib {
    // PancakeSwap Infinity on BSC mainnet (56).
    address internal constant UNIVERSAL_ROUTER = 0xd9C500DfF816a1Da21A48A732d3498Bf09dc9AEB;
    address internal constant CL_QUOTER = 0xd0737C9762912dD34c3271197E362Aa736Df0926;
    address internal constant CL_POSITION_MANAGER = 0x55f4c8abA71A1e923edC303eb4fEfF14608cC226;
    address internal constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address internal constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    // PancakeSwap Infinity on BSC testnet (97).
    address internal constant TESTNET_UNIVERSAL_ROUTER = 0x87FD5305E6a40F378da124864B2D479c2028BD86;
    address internal constant TESTNET_CL_QUOTER = 0x5d544D0ad627a72d7Fb53c22D8888663FC5d5B0d;
    address internal constant TESTNET_CL_POSITION_MANAGER = 0x77DedB52EC6260daC4011313DBEE09616d30d122;
    address internal constant TESTNET_VAULT = 0x2CdB3EC82EE13d341Dc6E73637BE0Eab79cb79dD;
    address internal constant TESTNET_CL_POOL_MANAGER = 0x36A12c70c9Cf64f24E89ee132BF93Df2DCD199d4;
    /// @dev PancakeSwap's own Permit2 (same address on both networks). Not Uniswap's 0x000000000022D4...: the
    ///      Infinity router and position manager read this one (`CLPositionManager.permit2()`).
    address internal constant PERMIT2 = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;

    bytes1 internal constant DEX_SWAP = 0x10;
    bytes1 internal constant SWEEP = 0x04;
    uint8 internal constant CL_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant CL_SWAP_EXACT_IN = 0x07;
    uint8 internal constant CL_SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;
    address internal constant MSG_SENDER = address(1); // the router's alias for its caller

    /// @dev ICLRouterBase.CLSwapExactInputSingleParams.
    struct ExactInSingle {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    /// @dev ICLRouterBase.CLSwapExactInputParams (multi-hop).
    struct ExactIn {
        Currency currencyIn;
        PathKey[] path;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    /// @dev ICLRouterBase.CLSwapExactOutputSingleParams.
    struct ExactOutSingle {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
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
        params[0] = abi.encode(ExactInSingle(key, buy, uint128(amountIn), uint128(minOut), ""));
        params[1] = abi.encode(buy ? key.currency0 : key.currency1, amountIn);
        params[2] = abi.encode(buy ? key.currency1 : key.currency0, minOut);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(CL_SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL), params);
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
        params[0] = abi.encode(ExactIn(currencyIn, path, uint128(amountIn), uint128(minOut)));
        params[1] = abi.encode(currencyIn, amountIn);
        params[2] = abi.encode(path[path.length - 1].intermediateCurrency, minOut);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(CL_SWAP_EXACT_IN, SETTLE_ALL, TAKE_ALL), params);
        commands = abi.encodePacked(DEX_SWAP);
    }

    /// @notice The PathKey hop into a Stealth pool's other currency.
    function hop(PoolKey memory key, Currency to) internal pure returns (PathKey memory) {
        return PathKey({
            intermediateCurrency: to,
            fee: key.fee,
            hooks: key.hooks,
            poolManager: key.poolManager,
            hookData: "",
            parameters: key.parameters
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
        params[0] = abi.encode(ExactOutSingle(key, true, uint128(amountOut), uint128(maxIn), ""));
        params[1] = abi.encode(key.currency0, maxIn);
        params[2] = abi.encode(key.currency1, amountOut);
        inputs = new bytes[](2);
        inputs[0] = abi.encode(abi.encodePacked(CL_SWAP_EXACT_OUT_SINGLE, SETTLE_ALL, TAKE_ALL), params);
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
        params[0] = abi.encode(ExactOutSingle(key, false, uint128(amountOut), uint128(maxIn), ""));
        params[1] = abi.encode(key.currency1, maxIn);
        params[2] = abi.encode(key.currency0, amountOut);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(CL_SWAP_EXACT_OUT_SINGLE, SETTLE_ALL, TAKE_ALL), params);
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
