// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {LaunchType} from "../../src/interfaces/IStealth.sol";
import {MockERC20} from "../utils/MockTokens.sol";

/// @notice Every tier, every launch type, all four swap modes, to the unit: the trader pays the tier on the gross quote
///         leg; the coin gets 70% of the tax, the platform wallet the rest; the coin's part goes by launch type (all of
///         it to marketing on the Marketing type), and nothing is lost to rounding.
contract ExactSplitTest is BaseTest {
    uint16[5] internal tiers = [125, 225, 325, 425, 575];

    struct Before {
        uint256 claims;
        uint256 owed;
        uint256 platform;
        uint256 marketing;
        uint256 coin;
    }

    function _snap(address token) internal view returns (Before memory b) {
        Currency q = vault.quoteOf(token);
        b = Before(_vaultClaims(q), vault.totalOwed(q), vault.platformOwed(token), vault.marketingOwed(token), vault.coinOwed(token));
    }

    /// @dev Checks the split of the swap since `b`. `gross` is the swap's gross quote leg.
    function _check(address token, Before memory b, LaunchType t, uint24 rate, uint256 gross, string memory label) internal view {
        Before memory a = _snap(token);
        uint256 fee = a.claims - b.claims;
        uint256 platformDelta = a.platform - b.platform;
        uint256 marketingDelta = a.marketing - b.marketing;
        uint256 coinDelta = a.coin - b.coin;
        assertEq(a.owed - b.owed, fee, label);
        assertEq(platformDelta + marketingDelta + coinDelta, fee, "every unit booked");
        // The tax is the rate of the gross leg, rounded up.
        assertLe(fee, (gross * rate) / 1_000_000 + 1, label);
        assertGe(fee, (gross * rate) / 1_000_000, label);
        uint256 coin = _coinPart(fee, rate, rate);
        assertEq(platformDelta, fee - coin, "the platform takes the rest of the tax");
        assertApproxEqAbs(coin, gross * (uint256(rate) * 7 / 10) / 1_000_000, 1, "the coin gets 70% of the tier");
        uint256 mkt = t == LaunchType.Marketing ? coin : 0;
        assertEq(marketingDelta, mkt, "marketing: the whole part on the Marketing type, otherwise nothing");
        assertEq(coinDelta, coin - mkt, "the coin's part");
    }

    function _options(LaunchType t) internal returns (StealthFactory.LaunchOptions memory o) {
        if (t != LaunchType.Team) return _typed(t);
        address[] memory wallets = new address[](2);
        wallets[0] = makeAddr("teamA");
        wallets[1] = makeAddr("teamB");
        uint16[] memory bps = new uint16[](2);
        bps[0] = 7_000;
        bps[1] = 3_000;
        return _teamOf(wallets, bps);
    }

    /// @dev A sell's gross quote leg: what the trader got plus the tax.
    function _soldGross(address token, address trader, uint256 q0, Before memory b) internal view returns (uint256) {
        return _quoteBalance(token, trader) - q0 + (_vaultClaims(vault.quoteOf(token)) - b.claims);
    }

    /// @dev Runs all four modes on `token` and checks each.
    function _allFourModes(address token, LaunchType t, uint24 rate, uint256 unit) internal {
        address trader = traders[3];
        _fundQuote(token, trader, 100 * unit);

        // Exact-in buy: gross is the input.
        Before memory b = _snap(token);
        uint256 tokens = _buy(trader, token, unit);
        _check(token, b, t, rate, unit, "exact-in buy");

        // Exact-out buy: gross is what the trader paid.
        b = _snap(token);
        uint256 q0 = _quoteBalance(token, trader);
        _buyExactOut(trader, token, tokens / 2, 10 * unit);
        _check(token, b, t, rate, q0 - _quoteBalance(token, trader), "exact-out buy");

        // Exact-in sell: gross is what the trader got plus the tax.
        b = _snap(token);
        q0 = _quoteBalance(token, trader);
        _sell(trader, token, tokens / 2);
        _check(token, b, t, rate, _soldGross(token, trader, q0, b), "exact-in sell");

        // Exact-out sell: gross is what the trader got plus the tax.
        b = _snap(token);
        q0 = _quoteBalance(token, trader);
        _sellExactOut(trader, token, unit / 10);
        assertEq(_quoteBalance(token, trader) - q0, unit / 10, "exact output");
        _check(token, b, t, rate, _soldGross(token, trader, q0, b), "exact-out sell");

        Currency q = vault.quoteOf(token);
        assertEq(_vaultClaims(q), vault.totalOwed(q), "claims == owed");
        assertEq(vault.tokenOwed(token), vault.coinOwed(token) + vault.marketingOwed(token) + vault.platformOwed(token));
    }

    function test_split_everyTierEveryTypeNative() public {
        for (uint256 i; i < tiers.length; ++i) {
            for (uint8 t; t < 6; ++t) {
                address token = _launchOpts(creator, tiers[i], 0, _options(LaunchType(t)));
                _skipSniperWindow(token);
                _allFourModes(token, LaunchType(t), uint24(tiers[i]) * 100, 1 ether);
            }
        }
    }

    function test_split_everyTypeErc20Quotes() public {
        MockERC20 q18 = _listedQuote("Q18", 18, 1, 1_000_000);
        MockERC20 q6 = _listedQuote("Q6", 6, 1, 1_000_000);
        for (uint8 t; t < 6; ++t) {
            for (uint256 d; d < 2; ++d) {
                MockERC20 q = d == 0 ? q18 : q6;
                uint256 unit = 10 ** q.decimals();
                StealthFactory.LaunchParams memory p = _paramsQ(address(q), 575, 4 * unit, 0, 0);
                p.options = _options(LaunchType(t));
                uint256 pull = factory.quoteProbeAmount(address(q));
                deal(address(q), creator, pull);
                vm.startPrank(creator);
                IERC20(address(q)).approve(address(factory), pull);
                address token = factory.launch(p);
                vm.stopPrank();
                _skipSniperWindow(token);
                _allFourModes(token, LaunchType(t), 57_500, unit);
            }
        }
    }

    function testFuzz_split_oneBuyOneSell(uint8 tierIndex, uint8 typeIndex, uint96 amount) public {
        uint16 tax = tiers[tierIndex % 5];
        LaunchType t = LaunchType(typeIndex % 6);
        uint256 gross = bound(amount, 1e6, 50 ether);
        address token = _launchOpts(creator, tax, 0, _options(t));
        _skipSniperWindow(token);
        vm.deal(traders[0], gross);
        Before memory b = _snap(token);
        uint256 tokens = _buy(traders[0], token, gross);
        _check(token, b, t, uint24(tax) * 100, gross, "fuzz buy");
        b = _snap(token);
        uint256 q0 = traders[0].balance;
        _sell(traders[0], token, tokens);
        _check(token, b, t, uint24(tax) * 100, traders[0].balance - q0 + (_vaultClaims() - b.claims), "fuzz sell");
    }

    /// @notice The first buy splits the same way, at the tier.
    function test_split_firstBuy() public {
        Before memory b = _snap(address(0));
        vm.prank(creator);
        address token = factory.launch{value: 0.01 ether}(_params(225, TARGET, 0));
        Before memory a = _snap(token);
        uint256 fee = a.claims - b.claims;
        assertEq(fee, _feeOnInput(0.01 ether, 22_500));
        uint256 coin = _coinPart(fee, 22_500, 22_500);
        assertEq(vault.platformOwed(token), fee - coin);
        assertEq(vault.marketingOwed(token), 0);
        assertEq(vault.coinOwed(token), coin);
    }
}
