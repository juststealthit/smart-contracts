// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Dex, SqrtPriceMath, Currency} from "@dex/Dex.sol";
import {SwapQuoter} from "../utils/SwapQuoter.sol";
import {TestRouter} from "../utils/TestRouter.sol";
import {MockERC20} from "../utils/MockTokens.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {Handler} from "./Handler.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthHook} from "../../src/StealthHook.sol";
import {LaunchType} from "../../src/interfaces/IStealth.sol";

contract InvariantsTest is BaseTest {
    Handler internal handler;
    TestRouter internal donateRouter;
    SwapQuoter internal quoter;
    address[] internal actors;
    address[] internal ethHolders;
    uint256 internal ethTotal;
    Currency[] internal quotes;

    function setUp() public override {
        super.setUp();
        donateRouter = new TestRouter(manager);
        quoter = new SwapQuoter(manager);

        for (uint256 i; i < 6; ++i) {
            actors.push(traders[i]);
        }
        actors.push(creator);
        actors.push(creator2);
        actors.push(claimer);

        // Three quotes: the native coin, an 18-decimal ERC-20 and a 6-decimal ERC-20, both listed with the same
        // 4-10 whole-unit target range as native. Every actor holds plenty of each and has approved the factory (first
        // buys) and the router (buys).
        quotes.push(NATIVE);
        MockERC20 q18 = new MockERC20("Quote18", "Q18", 18);
        MockERC20 q6 = new MockERC20("Quote6", "Q6", 6);
        quotes.push(Currency.wrap(address(q18)));
        quotes.push(Currency.wrap(address(q6)));
        vm.startPrank(admin);
        factory.listQuote(address(q18), 4e18, 4e18, 10e18);
        factory.listQuote(address(q6), 4e6, 4e6, 10e6);
        vm.stopPrank();
        for (uint256 i; i < actors.length; ++i) {
            q18.mint(actors[i], 1e9 * 1e18);
            q6.mint(actors[i], 1e9 * 1e6);
            vm.startPrank(actors[i]);
            q18.approve(address(factory), type(uint256).max);
            q6.approve(address(factory), type(uint256).max);
            q18.approve(address(swapRouter), type(uint256).max);
            q6.approve(address(swapRouter), type(uint256).max);
            q18.approve(address(stealthRouter), type(uint256).max);
            q6.approve(address(stealthRouter), type(uint256).max);
            vm.stopPrank();
        }
        handler = new Handler(
            manager, settlementAddr, swapRouter, donateRouter, quoter, factory, vault, stealthRouter, actors, quotes
        );
        // Pools to start: every launch type, across the quotes, some past their sniper window, some inside it. Actors
        // 0.. of a team launch; optSeed picks the type (seed % 6) and the team's size (seed >> 8).
        handler.launch(6, 4, 4 ether, 0.5 ether, 0, 0); // Creator, native
        handler.launch(3, 1, 7e18, 0.2e18, 1, 2); // Marketing, 18-dec
        handler.launch(4, 2, 5e6, 0.3e6, 2, 3); // Holders, 6-dec
        handler.launch(7, 3, 5 ether, 0.3 ether, 0, 4); // Buyback, native
        handler.launch(5, 2, 6 ether, 0.2 ether, 0, 5); // Pot, native
        vm.warp(block.timestamp + 20);
        handler.launch(2, 0, 10 ether, 0, 0, 0x0301); // Team, native
        handler.launch(5, 0, 8e18, 0.1e18, 1, 4); // Buyback, 18-dec
        handler.launch(1, 4, 6e6, 0.1e6, 2, 0x0101); // Team, 6-dec

        for (uint256 i; i < actors.length; ++i) {
            ethHolders.push(actors[i]);
        }
        address[12] memory others = [
            platform,
            marketing,
            address(vault),
            address(locker),
            settlementAddr,
            address(swapRouter),
            address(stealthRouter),
            distributor,
            address(donateRouter),
            address(quoter),
            address(handler),
            address(hook)
        ];
        for (uint256 i; i < others.length; ++i) {
            ethHolders.push(others[i]);
        }
        ethTotal = _ethSum();

        bytes4[] memory selectors = new bytes4[](30);
        selectors[0] = Handler.launch.selector;
        selectors[1] = Handler.buy.selector;
        selectors[2] = Handler.buyExactOut.selector;
        selectors[3] = Handler.sell.selector;
        selectors[4] = Handler.sellExactOut.selector;
        selectors[5] = Handler.transfer.selector;
        selectors[6] = Handler.burn.selector;
        selectors[7] = Handler.donate.selector;
        selectors[8] = Handler.claimCreator.selector;
        selectors[9] = Handler.handoff.selector;
        selectors[10] = Handler.sweep.selector;
        selectors[11] = Handler.warp.selector;
        selectors[12] = Handler.buy.selector;
        selectors[13] = Handler.sell.selector;
        selectors[14] = Handler.claimCreatorPart.selector;
        selectors[15] = Handler.proposeReassign.selector;
        selectors[16] = Handler.cancelReassign.selector;
        selectors[17] = Handler.acceptReassign.selector;
        selectors[18] = Handler.claimLegacy.selector;
        selectors[19] = Handler.warpLong.selector;
        selectors[20] = Handler.rotateManager.selector;
        selectors[21] = Handler.handoffToProposed.selector;
        selectors[22] = Handler.routerTrade.selector;
        selectors[23] = Handler.routerTrade.selector;
        selectors[24] = Handler.withdrawPot.selector;
        selectors[25] = Handler.buyback.selector;
        selectors[26] = Handler.buyback.selector;
        selectors[27] = Handler.buybackRefused.selector;
        selectors[28] = Handler.warpShort.selector;
        selectors[29] = Handler.warpShort.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Per currency, the vault's claim equals everything owed in it, to the unit, and it never holds native.
    function invariant_vaultBooksExact() public view {
        for (uint256 j; j < quotes.length; ++j) {
            uint256 owed = _owedIn(quotes[j]);
            assertEq(_vaultClaims(quotes[j]), owed, "claims != sum owed");
            assertEq(vault.totalOwed(quotes[j]), owed, "totalOwed != sum owed");
            if (!Dex.isNative(quotes[j])) {
                assertEq(IERC20(Currency.unwrap(quotes[j])).balanceOf(address(vault)), 0, "ERC-20 in the vault");
            }
        }
        assertEq(address(vault).balance, 0, "native coin in the vault");
    }

    function _owedIn(Currency q) internal view returns (uint256 owed) {
        address[] memory tokens = handler.allTokens();
        for (uint256 i; i < tokens.length; ++i) {
            if (vault.quoteOf(tokens[i]) == q) owed += _vaultOwed(_one(tokens[i]));
        }
    }

    /// @notice Every team's books add up: each wallet's paid plus claimable sums to `teamAccrued`, what is claimable sums
    ///         to what the coin owes, the wallets are 2-10 with bps summing to 100%. No other type has a team, and the
    ///         Marketing type keeps nothing.
    function invariant_teamBooks() public view {
        address[] memory tokens = handler.allTokens();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            (address[] memory wallets, uint16[] memory bps) = vault.team(token);
            LaunchType t = vault.launchTypeOf(token);
            if (t != LaunchType.Team) {
                assertEq(wallets.length, 0, "a team on another launch type");
                assertEq(vault.teamAccrued(token), 0, "team earnings on another launch type");
                if (t == LaunchType.Marketing) assertEq(vault.coinOwed(token), 0, "the Marketing type kept something");
                continue;
            }
            assertGe(wallets.length, 2);
            assertLe(wallets.length, 10);
            uint256 total;
            uint256 paidOut;
            uint256 claimable;
            for (uint256 k; k < wallets.length; ++k) {
                total += bps[k];
                paidOut += vault.memberPaid(token, wallets[k]);
                claimable += vault.claimable(token, wallets[k]);
            }
            assertEq(total, 10_000, "split != 100%");
            assertEq(paidOut + claimable, vault.teamAccrued(token), "wallets' paid + owed != team accrued");
            assertEq(claimable, vault.coinOwed(token), "claimable != what the coin owes");
            assertEq(paidOut, vault.creatorClaimed(token), "paid != lifetime claims");
        }
    }

    /// @notice Each token's legacy total is exactly the sum of its old creators' legacy balances, and an open
    ///         takeover proposal never names the current creator and never waits longer than the notice.
    function invariant_takeoverBooks() public view {
        address[] memory tokens = handler.allTokens();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 sum;
            for (uint256 j; j < actors.length; ++j) {
                sum += vault.legacyOwed(token, actors[j]);
            }
            assertEq(vault.legacyTotal(token), sum, "legacy total != sum of legacy balances");
            (address to, uint64 eta, uint32 epoch) = vault.reassignment(token);
            assertLe(epoch, vault.managerEpoch(), "proposal from a future epoch");
            if (to != address(0)) {
                assertTrue(to != vault.creatorOf(token), "proposal names the current creator");
                assertLe(eta, block.timestamp + vault.reassignNotice(), "notice longer than configured");
            }
        }
    }

    /// @notice Every fee credited is either still owed or was paid out, per currency.
    function invariant_creditedMinusPaidIsOwed() public view {
        for (uint256 j; j < quotes.length; ++j) {
            assertEq(handler.credited(quotes[j]) - handler.paid(quotes[j]), vault.totalOwed(quotes[j]));
        }
    }

    /// @notice Per token and role, every unit credited (split here from the design) is still owed or was paid: the split
    ///         of every fee is exact.
    function invariant_creditedMinusPaidPerRole() public view {
        address[] memory tokens = handler.allTokens();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            assertEq(
                handler.creditedPlatform(token),
                vault.platformOwed(token) + vault.platformPaid(token),
                "platform: credited != owed + paid"
            );
            assertEq(
                handler.creditedMarketing(token),
                vault.marketingOwed(token) + vault.marketingPaid(token),
                "marketing: credited != owed + paid"
            );
            assertEq(
                handler.creditedCoin(token),
                vault.coinOwed(token) + vault.legacyTotal(token) + vault.creatorClaimed(token) + vault.potPaid(token),
                "coin: credited != owed + paid"
            );
        }
    }

    /// @notice A pot can only be spent by its own launch type: a buyback pot never paid anyone but the pool, and what
    ///         a buyback coin's pot has lost is exactly what its buybacks spent.
    function invariant_potsSpentOnlyByTheirType() public view {
        address[] memory tokens = handler.allTokens();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            LaunchType t = vault.launchTypeOf(token);
            if (t == LaunchType.Buyback) assertEq(vault.potPaid(token), handler.buybackSpent(token), "pot left a buyback");
            else assertEq(handler.buybackSpent(token), 0, "a buyback on another launch type");
            if (t != LaunchType.Buyback && t != LaunchType.Holders && t != LaunchType.Pot) {
                assertEq(vault.potPaid(token), 0, "a pot on this type");
            }
        }
    }

    /// @notice No Stealth contract ever holds a Stealth token, and the locker and hook hold no quote and no claims.
    function invariant_noTokenFeesNoStrayEth() public view {
        address[] memory tokens = handler.allTokens();
        for (uint256 i; i < tokens.length; ++i) {
            IERC20 t = IERC20(tokens[i]);
            assertEq(t.balanceOf(address(locker)), 0, "locker holds tokens");
            assertEq(t.balanceOf(address(hook)), 0, "hook holds tokens");
            assertEq(t.balanceOf(address(vault)), 0, "vault holds tokens");
            assertEq(t.balanceOf(address(factory)), 0, "factory holds tokens");
            (uint256 g0, uint256 g1) = _feeGrowthGlobals(_poolId(tokens[i]));
            assertEq(g0 + g1, 0, "fees accrued in the positions");
        }
        assertEq(address(locker).balance, 0);
        assertEq(address(hook).balance, 0);
        for (uint256 j; j < quotes.length; ++j) {
            assertEq(_dexClaimOf(address(locker), quotes[j]), 0);
            assertEq(_dexClaimOf(address(hook), quotes[j]), 0);
            if (!Dex.isNative(quotes[j])) {
                IERC20 q = IERC20(Currency.unwrap(quotes[j]));
                assertEq(q.balanceOf(address(locker)) + q.balanceOf(address(hook)) + q.balanceOf(address(factory)), 0);
            }
        }
    }

    /// @notice Every swap paid exactly its mode's fee, and filled exactly as quoted.
    function invariant_feesExactAndQuotesMatch() public view {
        assertEq(handler.feeViolations(), 0, "a swap paid a different fee");
        assertEq(handler.quoteMismatches(), 0, "a swap filled differently from its quote");
    }

    /// @notice The launch positions never change, nobody else has liquidity, and the price stays in range.
    function invariant_liquidityLockedAndAlone() public view {
        address[] memory tokens = handler.allTokens();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            StealthLocker.PoolInfo memory info = locker.getPool(token);
            assertEq(_positionLiquidityOf(token, CURVE_SALT), info.curveLiquidity);
            assertEq(_positionLiquidityOf(token, TAIL_SALT), info.tailLiquidity);
            (uint160 price, int24 tick,,) = _getSlot0(_poolId(token));
            uint256 expected;
            if (tick < info.curveTickUpper) expected = tick >= info.curveTickLower ? info.curveLiquidity : info.tailLiquidity;
            assertEq(_poolLiquidity(_poolId(token)), expected, "unexpected active liquidity");
            assertLe(price, info.startSqrtPriceX96, "past the launch price");
        }
    }

    /// @notice Graduation is flagged exactly when the price has reached the graduation price, and never undone.
    function invariant_graduationFlag() public view {
        address[] memory tokens = handler.allTokens();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            bool crossed = handler.lowestPrice(token) <= locker.getPool(token).graduationSqrtPriceX96;
            assertEq(hook.graduated(token), crossed);
        }
    }

    /// @notice The fee rate follows the sniper curve inside the window (a straight line from 90%, one step per second),
    ///         then it is the tier, which is one of the five and never changes; the LP fee is 0.
    function invariant_feeOnSchedule() public view {
        address[] memory tokens = handler.allTokens();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            assertEq(_lpFee(token), 0);
            uint24 rate = hook.currentFee(token);
            StealthHook.PoolConfig memory c = hook.getConfig(token);
            uint24 tax = c.taxFee;
            assertTrue(
                tax == 12_500 || tax == 22_500 || tax == 32_500 || tax == 42_500 || tax == 57_500, "not a tier"
            );
            uint256 elapsed = block.timestamp - c.launchTime;
            if (elapsed < 15) assertEq(rate, 900_000 - (uint256(900_000 - tax) * elapsed) / 15, "off the sniper curve");
            else assertEq(rate, tax, "not the tier");
        }
    }

    /// @notice Supply only falls, by exactly what holders and buybacks burned, and every token is in the pool or with a
    ///         holder.
    function invariant_supplyAccounted() public view {
        address[] memory tokens = handler.allTokens();
        for (uint256 i; i < tokens.length; ++i) {
            IERC20 t = IERC20(tokens[i]);
            assertEq(t.totalSupply(), handler.supplyAtLaunch(tokens[i]) - handler.burned(tokens[i]));
            uint256 held = t.balanceOf(settlementAddr);
            for (uint256 j; j < actors.length; ++j) {
                held += t.balanceOf(actors[j]);
            }
            assertEq(held, t.totalSupply());
        }
    }

    /// @notice The settlement contract always holds, in every currency, at least what the locked positions are worth plus
    ///         the fee vault's claims.
    function invariant_vaultSolvent() public view {
        address[] memory tokens = handler.allTokens();
        uint256[] memory quoteOwed = new uint256[](quotes.length);
        for (uint256 j; j < quotes.length; ++j) {
            quoteOwed[j] = _vaultClaims(quotes[j]);
        }
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            StealthLocker.PoolInfo memory info = locker.getPool(token);
            uint160 price = _sqrtPrice(token);
            (uint256 e1, uint256 t1) = _amounts(price, info.curveTickLower, info.curveTickUpper, info.curveLiquidity);
            (uint256 e2, uint256 t2) = _amounts(price, info.tailTickLower, info.curveTickLower, info.tailLiquidity);
            for (uint256 j; j < quotes.length; ++j) {
                if (quotes[j] == vault.quoteOf(token)) quoteOwed[j] += e1 + e2;
            }
            assertGe(IERC20(token).balanceOf(settlementAddr), t1 + t2, "token side short");
        }
        for (uint256 j; j < quotes.length; ++j) {
            uint256 held = Dex.isNative(quotes[j])
                ? settlementAddr.balance
                : IERC20(Currency.unwrap(quotes[j])).balanceOf(settlementAddr);
            assertGe(held, quoteOwed[j], "quote side short");
            assertGe(_dexPoolReserves(quotes[j]), quoteOwed[j] - _vaultClaims(quotes[j]));
        }
    }

    /// @notice No native is created or lost anywhere, and every ERC-20 quote unit is with a holder or the settlement contract.
    function invariant_quoteConserved() public view {
        assertEq(_ethSum(), ethTotal);
        for (uint256 j = 1; j < quotes.length; ++j) {
            IERC20 q = IERC20(Currency.unwrap(quotes[j]));
            uint256 sum;
            for (uint256 i; i < ethHolders.length; ++i) {
                sum += q.balanceOf(ethHolders[i]);
            }
            assertEq(sum, q.totalSupply(), "quote units unaccounted for");
        }
    }

    function afterInvariant() external view {
        string[28] memory names = [
            "launch",
            "buy",
            "buyExactOut",
            "sell",
            "sellExactOut",
            "sniperTrade",
            "routerTrade",
            "transfer",
            "burn",
            "donateRefused",
            "claimCreator",
            "claimCreatorPart",
            "handoff",
            "sweep",
            "warp",
            "warpShort",
            "warpLong",
            "proposeReassign",
            "cancelReassign",
            "acceptReassign",
            "expiredReassign",
            "staleReassign",
            "claimLegacy",
            "rotateManager",
            "handoffToProposed",
            "withdrawPot",
            "buyback",
            "buybackRefused"
        ];
        for (uint256 i; i < names.length; ++i) {
            console2.log(names[i], handler.calls(names[i]));
        }
        uint256 graduated;
        address[] memory tokens = handler.allTokens();
        for (uint256 i; i < tokens.length; ++i) {
            if (hook.graduated(tokens[i])) graduated++;
        }
        console2.log("tokens", tokens.length, "graduated", graduated);
        for (uint256 j; j < quotes.length; ++j) {
            console2.log("quote", Currency.unwrap(quotes[j]));
            console2.log("  fees credited", handler.credited(quotes[j]), "paid", handler.paid(quotes[j]));
        }
    }

    function _amounts(uint160 price, int24 lower, int24 upper, uint128 liquidity)
        internal
        pure
        returns (uint256 eth, uint256 tokens)
    {
        uint160 a = Dex.sqrtAtTick(lower);
        uint160 b = Dex.sqrtAtTick(upper);
        if (price <= a) return (SqrtPriceMath.getAmount0Delta(a, b, liquidity, true), 0);
        if (price >= b) return (0, SqrtPriceMath.getAmount1Delta(a, b, liquidity, true));
        eth = SqrtPriceMath.getAmount0Delta(price, b, liquidity, true);
        tokens = SqrtPriceMath.getAmount1Delta(a, price, liquidity, true);
    }

    function _ethSum() internal view returns (uint256 sum) {
        for (uint256 i; i < ethHolders.length; ++i) {
            sum += ethHolders[i].balance;
        }
    }
}
