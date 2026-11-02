// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingBase} from "../utils/RoutingBase.sol";
import {MockERC20} from "../utils/MockTokens.sol";

/// @notice PancakeSwap's deployed Universal Router, Permit2 and CLQuoter bytecode (etched locally) on a native pair.
contract RoutingBnbTest is RoutingBase {}

/// @notice The same on an 18-decimal ERC-20 pair (USDT-like).
contract RoutingErc20Test is RoutingBase {
    function _makeQuote() internal override returns (address) {
        return address(new MockERC20("Mock USD", "mUSD", 18));
    }
}

/// @notice The same on a 6-decimal ERC-20 pair (USDC-on-Ethereum-like).
contract RoutingErc20SixDecimalsTest is RoutingBase {
    function _makeQuote() internal override returns (address) {
        return address(new MockERC20("Mock USD6", "mUSD6", 6));
    }
}
