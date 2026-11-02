// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";

/// @notice The anti-sniper fee: 90% in the launch's second, stepping down every second, straight to the tier at 15 s.
///         The same line as Stealth's Meteora launches on Solana: cliff - seconds x (cliff - tier) / 15.
contract SniperDecayTest is BaseTest {
    uint16[5] internal tiers = [125, 225, 325, 425, 575];

    function _expected(uint24 tier, uint256 elapsed) internal pure returns (uint24) {
        if (elapsed >= 15) return tier;
        return uint24(900_000 - (uint256(900_000 - tier) * elapsed) / 15);
    }

    function test_sniper_everySecondOfEveryTier() public {
        for (uint256 i; i < tiers.length; ++i) {
            uint24 tier = uint24(tiers[i]) * 100;
            uint256 start = block.timestamp;
            address token = _launchWith(creator, tiers[i], TARGET, 0);
            uint24 last = type(uint24).max;
            for (uint256 s; s <= 20; ++s) {
                vm.warp(start + s);
                uint24 rate = hook.currentFee(token);
                assertEq(rate, _expected(tier, s), "the line");
                if (s <= 15) assertLt(rate, last, "steps down every second");
                else assertEq(rate, last, "flat after the window");
                last = rate;
                uint256 before = _vaultClaims();
                _buy(traders[i], token, 0.01 ether);
                assertEq(_vaultClaims() - before, _feeOnInput(0.01 ether, rate), "the swap paid that rate");
            }
            assertEq(hook.currentFee(token), tier);
            vm.warp(start);
        }
    }

    function test_sniper_startsAt90AndEndsAtTheTier() public {
        address token = _launchWith(creator, TAX, TARGET, 0);
        uint256 t0 = block.timestamp;
        assertEq(hook.currentFee(token), 900_000);
        assertEq(hook.sniperWindowEnd(token), t0 + 15);
        vm.warp(t0 + 14);
        assertEq(hook.currentFee(token), 900_000 - (uint256(900_000 - TAX_PIPS) * 14) / 15);
        vm.warp(t0 + 15);
        assertEq(hook.currentFee(token), TAX_PIPS);
    }

    /// @notice All four swap modes pay the same step inside the window, each on its own quote leg.
    function test_sniper_allFourModes() public {
        uint256 t0 = block.timestamp;
        address token = _launchWith(creator, TAX, TARGET, 0);
        vm.warp(t0 + 7);
        uint24 rate = _expected(TAX_PIPS, 7);
        uint256 c0 = _vaultClaims();
        uint256 tokens = _buy(traders[0], token, 0.5 ether);
        assertEq(_vaultClaims() - c0, _feeOnInput(0.5 ether, rate), "exact-in buy");

        c0 = _vaultClaims();
        uint256 q0 = traders[1].balance;
        _buyExactOut(traders[1], token, 1_000_000e18, 1 ether);
        uint256 paid = q0 - traders[1].balance;
        uint256 fee = _vaultClaims() - c0;
        assertEq(fee, _feeOnTop(paid - fee, rate), "exact-out buy");

        c0 = _vaultClaims();
        uint256 q1 = traders[0].balance;
        _sell(traders[0], token, tokens / 2);
        uint256 got = traders[0].balance - q1;
        fee = _vaultClaims() - c0;
        assertEq(fee, _feeOnInput(got + fee, rate), "exact-in sell");

        c0 = _vaultClaims();
        _sellExactOut(traders[0], token, 0.001 ether);
        assertEq(_vaultClaims() - c0, _feeOnTop(0.001 ether, rate), "exact-out sell");
    }

    /// @notice The launcher's first buy, in the launch transaction, pays the tier and not the sniper fee.
    function test_sniper_firstBuyPaysTheTier() public {
        uint256 c0 = _vaultClaims();
        vm.prank(creator);
        address token = factory.launch{value: 0.01 ether}(_params(TAX, TARGET, 0));
        assertEq(_vaultClaims() - c0, _feeOnInput(0.01 ether, TAX_PIPS));
        assertGt(IERC20(token).balanceOf(creator), 0);
    }

    /// @notice Sniping your own coin: the surplus above the tier goes to the platform wallet. The coin still gets only
    ///         70% of its tier, so a creator cannot recycle a sniper fee to itself.
    function test_sniper_surplusGoesToThePlatform() public {
        address token = _launchWith(creator, TAX, TARGET, 0);
        uint256 fee = _feeOnInput(1 ether, 900_000);
        _buy(creator, token, 1 ether);
        uint256 coin = _coinPart(fee, TAX_PIPS, 900_000);
        assertEq(vault.platformOwed(token), fee - coin);
        assertEq(vault.coinOwed(token) + vault.marketingOwed(token), coin);
        assertApproxEqAbs(coin, 0.02975 ether, 1, "70% of the 4.25% tier");
    }

    function testFuzz_sniper_line(uint8 tierIndex, uint64 elapsed) public {
        uint256 start = block.timestamp;
        uint16 tax = tiers[tierIndex % 5];
        address token = _launchWith(creator, tax, TARGET, 0);
        vm.warp(start + elapsed);
        assertEq(hook.currentFee(token), _expected(uint24(tax) * 100, elapsed));
    }
}
