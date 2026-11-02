// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";

/// @notice The smallest possible trades. Never something for nothing: every wei in is accounted for, nothing comes
///         out that wasn't paid for, and the pool state stays sound.
contract DustTest is BaseTest {
    address internal token;
    StealthLocker.PoolInfo internal info;

    function setUp() public override {
        super.setUp();
        token = _launch(125, 4 ether); // the lowest tier: the most dust gets through
        info = locker.getPool(token);
    }

    function test_oneWeiBuy_isAllFee() public {
        uint256 pmBefore = settlementAddr.balance;
        uint256 c0 = _vaultClaims();
        uint256 got = _buy(traders[0], token, 1);
        assertEq(got, 0, "1 wei less a 1.25% fee (rounded up) is nothing");
        assertEq(settlementAddr.balance - pmBefore, 1, "the wei reaches the settlement contract");
        assertEq(_vaultClaims() - c0, 1, "as the vault's fee claim");
        assertEq(_sqrtPrice(token), info.startSqrtPriceX96, "and the price does not move");
    }

    function test_tinyBuys_neverBeatTheLaunchPrice() public {
        // At the launch price 1 wei buys at most `startTokensPerWei` token-wei; nobody ever gets more.
        uint256 startTokensPerWei = uint256(info.startSqrtPriceX96) * info.startSqrtPriceX96 >> 192;
        for (uint256 w = 2; w <= 64; ++w) {
            uint256 pmBefore = settlementAddr.balance;
            uint256 got = _buy(traders[0], token, w);
            assertEq(settlementAddr.balance - pmBefore, w, "every wei lands in the pool");
            assertGt(got, 0);
            assertLe(got, w * startTokensPerWei, "no buy beats the launch price");
        }
    }

    function test_oneTokenWeiSell_isAllFee() public {
        _buy(traders[0], token, 1 ether);
        uint256 pmBefore = settlementAddr.balance;
        uint256 got = _sell(traders[0], token, 1);
        assertEq(got, 0, "1 token-wei is worth far less than 1 wei");
        assertEq(settlementAddr.balance, pmBefore);
    }

    function test_dustSells_payNothingOut() public {
        _buy(traders[0], token, 1 ether);
        // At this price one wei of the quote is worth ~1e9 token-wei: anything smaller pays nothing.
        for (uint256 t = 1; t <= 1e8; t *= 10) {
            assertEq(_sell(traders[0], token, t), 0);
        }
    }

    function test_dustRoundTrips_neverProfit() public {
        address t = traders[1];
        _buy(t, token, 0.01 ether);
        uint256 ethBefore = t.balance;
        uint256 tokensBefore = IERC20(token).balanceOf(t);
        for (uint256 i = 1; i <= 40; ++i) {
            uint256 got = _buy(t, token, i * 7);
            if (got > 1) _sell(t, token, got / 2 + i);
        }
        // Value the leftover tokens generously at the launch price: still a loss.
        uint256 startTokensPerWei = uint256(info.startSqrtPriceX96) * info.startSqrtPriceX96 >> 192;
        uint256 tokenGain = IERC20(token).balanceOf(t) - tokensBefore;
        assertLt(t.balance + tokenGain / startTokensPerWei + 1, ethBefore + 1, "dust never profits");
    }

    function test_dustFees_accumulateInTheVault() public {
        _buy(traders[0], token, 0.5 ether);
        uint256 c0 = _vaultClaims();
        for (uint256 i; i < 50; ++i) {
            _buy(traders[1], token, 150); // 1.25% of 150 wei, rounded up: a 2 wei fee each
        }
        assertEq(_vaultClaims() - c0, 100, "every dust fee reaches the vault");
        assertEq(_vaultClaims(), _vaultOwed(_one(token)));
    }
}
