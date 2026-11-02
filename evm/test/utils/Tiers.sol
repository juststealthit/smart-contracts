// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev One of the five tax tiers, in bps, picked by a fuzz seed.
function tierOf(uint256 seed) pure returns (uint16) {
    uint16[5] memory tiers = [125, 225, 325, 425, 575];
    return tiers[seed % 5];
}
