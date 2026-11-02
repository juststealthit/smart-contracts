// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@dex/Dex.sol";

/// @notice Who a coin's part of its tax pays, picked at launch and locked. Creator: the creator's wallet. Team: 2-10
///         wallets by bps. Marketing: the marketing wallet. Holders: a pot the distributor pays to holders. Buyback: a pot
///         the distributor spends buying the coin and burning it. Pot: a general pot the distributor pays out, for
///         launch types run off chain by the ops bot.
/// @dev The order is the ABI: new types go at the end, and none ever moves.
enum LaunchType {
    Creator,
    Team,
    Marketing,
    Holders,
    Buyback,
    Pot
}

/// @notice One wallet of a team launch and its bps of the team's part.
struct TeamShare {
    address wallet;
    uint16 bps;
}

/// @notice StealthFeeVault surface used by the hook, locker and factory.
interface IStealthFeeVault {
    function credit(address token, Currency currency, uint256 fee, uint24 rate) external;
    function creditLaunchFee(address token) external payable;
    function registerToken(
        address token,
        address creator,
        Currency quote,
        LaunchType launchType,
        TeamShare[] calldata team,
        uint16 taxBps
    ) external;
    function quoteOf(address token) external view returns (Currency);
    function hook() external view returns (address);
    function factory() external view returns (address);
    function distributor() external view returns (address);
}
