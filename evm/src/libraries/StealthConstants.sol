// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title StealthConstants
/// @notice Every protocol-wide constant and hard cap, kept in one place so reviewers can find them.
/// @dev These are compiled into bytecode. No admin key can move them.
library StealthConstants {
    string internal constant LAUNCHPAD_NAME = "Stealth";

    // ---------------------------------------------------------------------
    // Supply
    // ---------------------------------------------------------------------

    /// @notice Supply of every Stealth token (18 decimals), less a few token-wei of rounding the pool cannot place.
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    /// @notice Tokens in the bonding-curve position: sold between the start price and the graduation price.
    uint256 internal constant CURVE_SUPPLY = 800_000_000e18;
    /// @notice Tokens in the tail position: sold above the graduation price.
    uint256 internal constant POOL_SUPPLY = 200_000_000e18;
    /// @notice 5% of supply: the most the launcher's first buy can take.
    uint256 internal constant LAUNCH_ALLOWANCE = 50_000_000e18;

    // ---------------------------------------------------------------------
    // Fees
    // ---------------------------------------------------------------------

    uint256 internal constant BPS = 10_000;
    /// @notice Pool fees are in pips (1_000_000 = 100%).
    uint24 internal constant PIPS_PER_BPS = 100;
    /// @notice 100% in pips.
    uint256 internal constant PIPS = 1_000_000;
    /// @notice The five tax tiers, picked at launch and locked: 1.25%, 2.25%, 3.25%, 4.25%, 5.75% of each trade.
    uint16 internal constant TAX_TIER_1 = 125;
    uint16 internal constant TAX_TIER_2 = 225;
    uint16 internal constant TAX_TIER_3 = 325;
    uint16 internal constant TAX_TIER_4 = 425;
    uint16 internal constant TAX_TIER_5 = 575;
    /// @notice The tier a launch gets if it names none.
    uint16 internal constant DEFAULT_TAX_BPS = TAX_TIER_1;
    /// @notice The coin's part of its tier (70%). The platform wallet gets everything else the trade paid, including
    ///         all of the sniper fee above the tier, so a launcher gains nothing by sniping their own coin.
    uint256 internal constant COIN_TAX_BPS = 7_000;
    /// @notice Wallets in a team launch.
    uint256 internal constant MIN_TEAM_SIZE = 2;
    uint256 internal constant MAX_TEAM_SIZE = 10;

    /// @notice Anti-sniper fee: 90% at launch, stepping down every second, straight down to the tier after 15 seconds.
    uint24 internal constant SNIPER_START_FEE = 900_000;
    uint256 internal constant SNIPER_WINDOW = 15;

    // ---------------------------------------------------------------------
    // Launch safety
    // ---------------------------------------------------------------------

    /// @notice Max wallet, when set: 0.5% to 5% of supply.
    uint16 internal constant MIN_MAX_WALLET_BPS = 50;
    uint16 internal constant MAX_MAX_WALLET_BPS = 500;
    /// @notice Max buy per transaction, when set: 0.1% to 5% of supply.
    uint16 internal constant MIN_MAX_BUY_BPS = 10;
    uint16 internal constant MAX_MAX_BUY_BPS = 500;
    /// @notice The limits apply for at most the first 60 minutes.
    uint32 internal constant MAX_LIMITS_WINDOW = 60 minutes;
    /// @notice The launcher's first buy can be locked for at most 90 days.
    uint32 internal constant MAX_FIRST_BUY_LOCK = 90 days;

    // ---------------------------------------------------------------------
    // Hard caps on configuration
    // ---------------------------------------------------------------------

    /// @notice Launch fee (always paid in the chain's native coin) can never exceed this many native units.
    uint256 internal constant MAX_LAUNCH_FEE = 0.1 ether;
    /// @notice Absolute lower bound for a deployment's native graduation-target floor.
    uint256 internal constant MIN_TARGET_FLOOR = 0.001 ether;
    /// @notice Absolute upper bound for a deployment's native graduation-target ceiling.
    uint256 internal constant MAX_TARGET_CEILING = 1_000_000 ether;

    // ---------------------------------------------------------------------
    // ERC-20 quote currencies
    // ---------------------------------------------------------------------

    /// @notice Fewest decimals an ERC-20 quote may have. Below this one unit of rounding (every fee rounds up by at
    ///         most one unit) stops being dust.
    uint8 internal constant MIN_QUOTE_DECIMALS = 6;
    /// @notice Most decimals an ERC-20 quote may have.
    uint8 internal constant MAX_QUOTE_DECIMALS = 18;
    /// @notice Graduation targets for an ERC-20 quote are bounded, in whole quote units, by
    ///         [10^-QUOTE_TARGET_MIN_EXP, 10^QUOTE_TARGET_MAX_EXP]: 0.01 to 10^12 units.
    uint8 internal constant QUOTE_TARGET_MIN_EXP = 2;
    uint8 internal constant QUOTE_TARGET_MAX_EXP = 12;
    /// @notice A launch paired with an ERC-20 pulls at least 10^(decimals - PROBE_UNIT_EXP) raw units (at least
    ///         PROBE_MIN_RAW) from the launcher and returns what the first buy does not use, to check it moves exactly.
    uint8 internal constant PROBE_UNIT_EXP = 4;
    uint256 internal constant PROBE_MIN_RAW = 10_000;
    /// @notice Most CREATE2 salts the token deployer tries to find a token address above the quote's address.
    uint256 internal constant MAX_SALT_TRIES = 4096;

    // ---------------------------------------------------------------------
    // Token metadata limits (they bound the worst-case launch gas: 200 gas per byte of the token's code)
    // ---------------------------------------------------------------------

    uint256 internal constant MAX_NAME_LENGTH = 64;
    uint256 internal constant MAX_SYMBOL_LENGTH = 32;
    uint256 internal constant MAX_LOGO_LENGTH = 512;
    uint256 internal constant MAX_DESCRIPTION_LENGTH = 1024;
    uint256 internal constant MAX_SOCIAL_LENGTH = 256;

    // ---------------------------------------------------------------------
    // Pool
    // ---------------------------------------------------------------------

    /// @notice Every Stealth pool has a static LP fee of 0: the hook takes the tax itself, on the quote leg.
    uint24 internal constant POOL_FEE = 0;
    /// @notice Tick spacing for Stealth pools: 0.1% price steps at the curve's ends.
    int24 internal constant TICK_SPACING = 10;
    /// @notice Token-wei held back per position when sizing liquidity, to absorb the pool's round-up.
    uint256 internal constant SEED_ROUNDING_BUFFER = 2;
}
