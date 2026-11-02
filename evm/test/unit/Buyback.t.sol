// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, IDexManager} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {SwapQuoter} from "../utils/SwapQuoter.sol";
import {MockERC20} from "../utils/MockTokens.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";
import {LaunchType} from "../../src/interfaces/IStealth.sol";

/// @notice The buyback: the distributor spends a Buyback coin's pot buying the coin from its pool and burns every token.
contract BuybackTest is BaseTest {
    SwapQuoter internal quoter;
    address internal token;

    function setUp() public override {
        super.setUp();
        quoter = new SwapQuoter(manager);
        token = _coin(TAX);
        _skipSniperWindow(token);
        _trade(token, 20 ether); // fills the pot
    }

    function _coin(uint16 tax) internal returns (address) {
        return _launchOpts(creator, tax, 0, _typed(LaunchType.Buyback));
    }

    function _trade(address t, uint256 amount) internal {
        vm.deal(traders[0], amount);
        uint256 tokens = _buy(traders[0], t, amount);
        _sell(traders[0], t, tokens);
    }

    function _bb(address t, uint256 amount, uint256 minOut) internal returns (uint256) {
        uint256 nonce = vault.potNonce(t);
        vm.prank(distributor);
        return vault.buyback(t, amount, minOut, block.timestamp, nonce);
    }

    function _quoted(address t, uint256 amount) internal returns (uint256 out) {
        (, out) = quoter.quote(
            _key(t),
            IDexManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            })
        );
    }

    // ---------------------------------------------------------------------
    // The burn
    // ---------------------------------------------------------------------

    function test_buyback_spendsThePotAndSupplyFalls() public {
        uint256 pot = vault.coinOwed(token);
        assertGt(pot, 0, "trading filled the pot");
        uint256 spend = pot / 2;
        uint256 quoted = _quoted(token, spend);
        uint256 supply = IERC20(token).totalSupply();
        uint160 priceBefore = _sqrtPrice(token);

        uint256 burned = _bb(token, spend, quoted);

        assertEq(burned, quoted, "the quote is exact");
        assertEq(IERC20(token).totalSupply(), supply - burned, "supply fell by exactly what was bought");
        assertEq(IERC20(token).balanceOf(address(vault)), 0, "the vault keeps no tokens");
        assertEq(IERC20(token).balanceOf(address(0xdead)), 0, "no dead-address balance: a real burn");
        assertLt(_sqrtPrice(token), priceBefore, "it was a real buy: the price moved");
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE), "claims == owed");
        assertEq(vault.potPaid(token), spend);
    }

    /// @notice The buy is a normal trade: it pays the tier, and the coin's part of that tax returns to the pot.
    function test_buyback_paysTheTierLikeAnyTrade() public {
        uint256 pot = vault.coinOwed(token);
        uint256 platformBefore = vault.platformOwed(token);
        uint256 marketingBefore = vault.marketingOwed(token);
        uint256 spend = pot;
        uint256 fee = _feeOnInput(spend, TAX_PIPS);
        uint256 coin = _coinPart(fee, TAX_PIPS, TAX_PIPS);
        _bb(token, spend, 1);
        assertEq(vault.coinOwed(token), coin, "pot after: the buyback's own tax came back");
        assertEq(vault.platformOwed(token), platformBefore + fee - coin);
        assertEq(vault.marketingOwed(token), marketingBefore, "no marketing share");
    }

    function test_buyback_events() public {
        uint256 spend = vault.coinOwed(token) / 4;
        uint256 out = _quoted(token, spend);
        uint256 fee = _feeOnInput(spend, TAX_PIPS);
        uint256 potAfter = vault.coinOwed(token) - spend + _coinPart(fee, TAX_PIPS, TAX_PIPS);
        vm.expectEmit(true, true, true, true, address(vault));
        emit StealthFeeVault.BuybackBurned(token, 0, spend, out, potAfter);
        _bb(token, spend, out);
    }

    function test_buyback_erc20Quotes() public {
        for (uint8 d = 6; d <= 18; d += 12) {
            MockERC20 q = _listedQuote(d == 6 ? "Q6" : "Q18", d, 1, 1_000_000);
            uint256 unit = 10 ** d;
            StealthFactory.LaunchParams memory p = _paramsQ(address(q), TAX, 4 * unit, 0, 0);
            p.options = _typed(LaunchType.Buyback);
            uint256 pull = factory.quoteProbeAmount(address(q));
            deal(address(q), creator, pull);
            vm.startPrank(creator);
            IERC20(address(q)).approve(address(factory), pull);
            address t = factory.launch(p);
            vm.stopPrank();
            _skipSniperWindow(t);
            _fundQuote(t, traders[1], 100 * unit);
            uint256 tokens = _buy(traders[1], t, 20 * unit);
            _sell(traders[1], t, tokens / 2);

            Currency c = Currency.wrap(address(q));
            uint256 pot = vault.coinOwed(t);
            uint256 supply = IERC20(t).totalSupply();
            uint256 burned = _bb(t, pot, 1);
            assertEq(IERC20(t).totalSupply(), supply - burned);
            assertEq(q.balanceOf(address(vault)), 0, "the quote never leaves the settlement contract");
            assertEq(_vaultClaims(c), vault.totalOwed(c));
        }
    }

    function testFuzz_buyback_supplyFallsByTheBurn(uint96 volume, uint16 shareBps) public {
        uint256 v = bound(volume, 1 ether, 40 ether);
        address t = _coin(575);
        _skipSniperWindow(t);
        _trade(t, v);
        uint256 pot = vault.coinOwed(t);
        uint256 spend = bound(shareBps, 1, 10_000) * pot / 10_000;
        vm.assume(spend != 0);
        uint256 supply = IERC20(t).totalSupply();
        uint256 owedBefore = vault.totalOwed(NATIVE);
        uint256 burned = _bb(t, spend, 1);
        assertEq(IERC20(t).totalSupply(), supply + 0 - burned);
        uint256 fee = _feeOnInput(spend, 57_500);
        assertEq(vault.totalOwed(NATIVE), owedBefore - spend + fee, "books moved by the spend and the tax");
        assertEq(_vaultClaims(), vault.totalOwed(NATIVE));
    }

    // ---------------------------------------------------------------------
    // Role
    // ---------------------------------------------------------------------

    function test_buyback_onlyTheDistributor() public {
        uint256 nonce = vault.potNonce(token);
        address[4] memory nope = [admin, creator, attacker, creatorManager];
        for (uint256 i; i < nope.length; ++i) {
            vm.prank(nope[i]);
            vm.expectRevert(StealthFeeVault.NotDistributor.selector);
            vault.buyback(token, 1, 1, block.timestamp, nonce);
        }
    }

    function test_buyback_rotatingTheDistributorMovesTheRight() public {
        address next = makeAddr("nextBot");
        vm.prank(admin);
        vault.setDistributor(next);
        uint256 nonce = vault.potNonce(token);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.NotDistributor.selector);
        vault.buyback(token, 1e6, 1, block.timestamp, nonce);
        vm.prank(next);
        vault.buyback(token, 1e6, 1, block.timestamp, nonce);
    }

    // ---------------------------------------------------------------------
    // Pot limits
    // ---------------------------------------------------------------------

    function test_buyback_cannotExceedThePot() public {
        uint256 pot = vault.coinOwed(token);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.AmountTooHigh.selector);
        vault.buyback(token, pot + 1, 1, block.timestamp, 0);
    }

    /// @notice A pot pays for its own coin only, however full the other coins' balances are.
    function test_buyback_spendsOnlyThatCoinsPot() public {
        address other = _coin(TAX);
        _skipSniperWindow(other);
        _trade(other, 1 ether);
        uint256 otherPot = vault.coinOwed(other);
        uint256 bigPot = vault.coinOwed(token);
        assertGt(bigPot, otherPot);

        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.AmountTooHigh.selector);
        vault.buyback(other, otherPot + 1, 1, block.timestamp, 0);

        _bb(other, otherPot, 1);
        assertEq(vault.coinOwed(token), bigPot, "the other coin's pot is untouched");
    }

    function test_buyback_cannotTouchOtherRolesBalances() public {
        uint256 platform_ = vault.platformOwed(token);
        uint256 marketing_ = vault.marketingOwed(token);
        uint256 pot = vault.coinOwed(token);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.AmountTooHigh.selector);
        vault.buyback(token, pot + platform_, 1, block.timestamp, 0);
        assertEq(vault.platformOwed(token), platform_);
        assertEq(vault.marketingOwed(token), marketing_);
    }

    function test_buyback_onlyBuybackCoins() public {
        for (uint8 t; t < 6; ++t) {
            if (LaunchType(t) == LaunchType.Team || LaunchType(t) == LaunchType.Buyback) continue;
            address coin = _launchOpts(creator, TAX, 0, _typed(LaunchType(t)));
            vm.prank(distributor);
            vm.expectRevert(StealthFeeVault.WrongLaunchType.selector);
            vault.buyback(coin, 1, 1, block.timestamp, 0);
        }
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.WrongLaunchType.selector);
        vault.buyback(makeAddr("not a coin"), 1, 1, block.timestamp, 0);
    }

    /// @notice The buyback pot can only become burned tokens: no call pays it to an address.
    function test_buyback_potCannotBeWithdrawn() public {
        address[] memory to = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        to[0] = distributor;
        amounts[0] = 1;
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.WrongLaunchType.selector);
        vault.withdrawPot(token, to, amounts, 0);
    }

    // ---------------------------------------------------------------------
    // Slippage
    // ---------------------------------------------------------------------

    function test_buyback_minOutMustBeSet() public {
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.ZeroAmount.selector);
        vault.buyback(token, 1e6, 0, block.timestamp, 0);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.ZeroAmount.selector);
        vault.buyback(token, 0, 1, block.timestamp, 0);
    }

    function test_buyback_revertsUnderTheMinimumAndChangesNothing() public {
        uint256 pot = vault.coinOwed(token);
        uint256 quoted = _quoted(token, pot / 2);
        uint256 supply = IERC20(token).totalSupply();
        uint256 nonce = vault.potNonce(token);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.Slippage.selector);
        vault.buyback(token, pot / 2, quoted + 1, block.timestamp, nonce);
        assertEq(vault.coinOwed(token), pot);
        assertEq(IERC20(token).totalSupply(), supply);
        assertEq(vault.potNonce(token), nonce, "a failed buyback does not spend the nonce");
    }

    /// @notice A sandwich: the attacker buys in front of the bot. The minimum the bot pinned makes the buyback revert,
    ///         the attacker is left holding tokens at a worse price and the pot has not moved.
    function test_buyback_sandwichFrontRunReverts() public {
        uint256 spend = vault.coinOwed(token) / 2;
        uint256 minOut = _quoted(token, spend) * 9_900 / 10_000; // the bot's 1%
        _buy(attacker, token, 5 ether);
        uint256 pot = vault.coinOwed(token);
        uint256 nonce = vault.potNonce(token);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.Slippage.selector);
        vault.buyback(token, spend, minOut, block.timestamp, nonce);
        assertEq(vault.coinOwed(token), pot);
    }

    function test_buyback_expiredDeadline() public {
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.Expired.selector);
        vault.buyback(token, 1e6, 1, block.timestamp - 1, 0);
    }

    // ---------------------------------------------------------------------
    // Retry
    // ---------------------------------------------------------------------

    /// @notice A bot that does not know whether its transaction landed sends it again: the second one reverts.
    function test_buyback_resendingTheSameCallCannotSpendTwice() public {
        uint256 spend = vault.coinOwed(token) / 4;
        uint256 nonce = vault.potNonce(token);
        vm.prank(distributor);
        vault.buyback(token, spend, 1, block.timestamp, nonce);
        uint256 pot = vault.coinOwed(token);
        uint256 supply = IERC20(token).totalSupply();
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.StaleNonce.selector);
        vault.buyback(token, spend, 1, block.timestamp, nonce);
        assertEq(vault.coinOwed(token), pot);
        assertEq(IERC20(token).totalSupply(), supply);
    }

    function test_buyback_failedCallCanBeRetried() public {
        uint256 spend = vault.coinOwed(token) / 4;
        uint256 quoted = _quoted(token, spend);
        uint256 nonce = vault.potNonce(token);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.Slippage.selector);
        vault.buyback(token, spend, quoted + 1, block.timestamp, nonce);
        vm.prank(distributor);
        uint256 burned = vault.buyback(token, spend, quoted, block.timestamp, nonce);
        assertEq(burned, quoted);
        assertEq(vault.potNonce(token), nonce + 1);
    }

    function test_buyback_noncesArePerCoin() public {
        address other = _coin(TAX);
        _skipSniperWindow(other);
        _trade(other, 1 ether);
        _bb(token, 1e6, 1);
        assertEq(vault.potNonce(token), 1);
        assertEq(vault.potNonce(other), 0);
        _bb(other, 1e6, 1);
    }

    // ---------------------------------------------------------------------
    // Windows and limits
    // ---------------------------------------------------------------------

    function test_buyback_refusedInTheSniperWindow() public {
        address t = _coin(TAX);
        _buy(traders[1], t, 1 ether); // pays the sniper fee: the coin's part is in the pot
        assertGt(vault.coinOwed(t), 0);
        vm.prank(distributor);
        vm.expectRevert(StealthFeeVault.SniperWindowOpen.selector);
        vault.buyback(t, 1e6, 1, block.timestamp, 0);
        _skipSniperWindow(t);
        _bb(t, 1e6, 1);
    }

    /// @notice In the limits window the buy counts against the max buy like anyone's, and can be retried smaller.
    ///         Each call must be its own transaction: the limit is counted per transaction.
    /// forge-config: default.isolate = true
    /// forge-config: infinity.isolate = true
    function test_buyback_respectsTheMaxBuy() public {
        StealthFactory.LaunchOptions memory o = _typed(LaunchType.Buyback);
        o.maxBuyBps = 10; // 1M tokens, about 0.00125 of the quote at the launch price
        o.limitsWindow = 1 hours;
        address t = _launchOpts(creator, 575, 0, o);
        _skipSniperWindow(t);
        for (uint256 i; i < 300; ++i) {
            uint256 tokens = _buy(traders[2], t, 0.001 ether);
            _sell(traders[2], t, tokens);
        }
        uint256 pot = vault.coinOwed(t);
        assertGt(pot, 0.0013 ether, "the whole pot buys more than the limit");
        vm.prank(distributor);
        vm.expectRevert(); // MaxBuyExceeded, wrapped by the DEX's hook-call error
        vault.buyback(t, pot, 1, block.timestamp, 0);
        assertEq(vault.coinOwed(t), pot, "nothing moved");
        assertGt(_bb(t, 0.001 ether, 1), 0, "a retry under the limit goes through");
    }

    /// @notice The fee vault holds the bought tokens for a moment, above any max wallet. It is exempt, and the tokens
    ///         are gone before the transaction ends.
    function test_buyback_worksUnderAMaxWallet() public {
        StealthFactory.LaunchOptions memory o = _typed(LaunchType.Buyback);
        o.maxWalletBps = 50;
        o.limitsWindow = 1 hours;
        address t = _launchOpts(creator, 575, 0, o);
        _skipSniperWindow(t);
        for (uint256 i; i < 60; ++i) {
            uint256 tokens = _buy(traders[2], t, 0.005 ether);
            _sell(traders[2], t, tokens);
        }
        uint256 pot = vault.coinOwed(t);
        assertGt(_quoted(t, pot), 0);
        uint256 burned = _bb(t, pot, 1);
        assertGt(burned, 0);
        assertEq(IERC20(t).balanceOf(address(vault)), 0);
    }

    function test_buyback_afterGraduationAndAcrossIt() public {
        address t = _coin(TAX);
        _skipSniperWindow(t);
        _graduate(t, traders[4]);
        uint256 supply = IERC20(t).totalSupply();
        uint256 burned = _bb(t, vault.coinOwed(t), 1);
        assertEq(IERC20(t).totalSupply(), supply - burned);
    }

    function test_buyback_sweepAndBuybackCoexist() public {
        vm.prank(claimer);
        vault.sweep(_one(token));
        _bb(token, vault.coinOwed(token), 1);
        vm.prank(claimer);
        vault.sweep(_one(token));
        assertEq(_vaultClaims(), vault.coinOwed(token));
    }
}
