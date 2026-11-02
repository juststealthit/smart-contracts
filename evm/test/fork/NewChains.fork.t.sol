// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDexManager, PoolKey} from "@dex/Dex.sol";
import {DexFork} from "@dex/DexFork.sol";
import {IDexQuoter} from "@dex/UniversalRouterLib.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {LaunchType} from "../../src/interfaces/IStealth.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthDeploy} from "../../script/lib/StealthDeploy.sol";

/// @notice Base (8453) and Arc (5042) on the v4 build: the whole system deployed into a local fork with the mainnet deploy's
///         settings, then a launch, trades, the fee split, a sweep, a creator claim, a Pot payout and graduation against the
///         chain's own PoolManager and Quoter. Nothing is broadcast. Needs STEALTH_FORK=true; skips cleanly if the RPC can't be
///         reached. STEALTH_BASE_RPC or STEALTH_ARC_RPC picks a private RPC, otherwise foundry.toml's public one. Only the v4 build
///         has these chains.
abstract contract NewChainFork is BaseTest {
    DexFork.Chain internal live;

    function _index() internal pure virtual returns (uint256);
    function _rpcEnv() internal pure virtual returns (string memory);
    function _expectedChainId() internal pure virtual returns (uint256);
    /// @dev floor, min, default, max, ceiling, in the chain's native coin.
    function _targets() internal pure virtual returns (uint256[5] memory);
    /// @dev A trade of about a thousand dollars.
    function _trade() internal pure virtual returns (uint256);

    function setUp() public override {
        if (!vm.envOr("STEALTH_FORK", false) || _index() >= DexFork.CHAINS) {
            vm.skip(true);
            return;
        }
        live = DexFork.chain(_index());
        string memory rpc = vm.envOr(_rpcEnv(), live.rpc);
        try vm.createSelectFork(rpc) returns (uint256) {} catch {
            console2.log("skipping: cannot reach the chain");
            vm.skip(true);
            return;
        }
        vm.rollFork(block.number - 20);
        assertEq(block.chainid, _expectedChainId(), "wrong chain");
        super.setUp();
    }

    function _actorSalt() internal pure override returns (string memory) {
        return "@stealth-new-chains";
    }

    function _installDex() internal override {
        manager = IDexManager(live.manager);
        settlementAddr = live.settlement;
    }

    function _dexRouter() internal view override returns (address) {
        return live.router;
    }

    function _dexQuoter() internal view override returns (address) {
        return live.quoter;
    }

    function _dexPermit2() internal view override returns (address) {
        return live.permit2;
    }

    function _deployParams() internal override returns (StealthDeploy.Params memory p) {
        p = super._deployParams();
        uint256[5] memory t = _targets();
        p.targetFloor = t[0];
        p.targetCeiling = t[4];
        p.config = StealthDeploy.config(t[1], t[2], t[3]);
    }

    function test_fork_wiring() public view {
        assertEq(DexFork.wiring(live), "", "live wiring");
        assertEq(address(vault.poolManager()), live.manager);
        assertEq(address(stealthRouter.permit2()), live.permit2);
        assertEq(factory.targetFloor(), _targets()[0]);
        assertEq(factory.targetCeiling(), _targets()[4]);
    }

    /// @notice The chain's Quoter and PoolManager agree: what it quotes for a pool on this chain is what a swap fills, both
    ///         ways. This is what "behaves as v4" means here: a v4 pool with a v4 hook, unlocked, swapped and settled in native.
    function test_fork_quoterMatchesTheFill() public {
        uint256 amount = _trade();
        address token = _launchWith(creator, TAX, _targets()[2], 0);
        _skipSniperWindow(token);
        PoolKey memory k = _key(token);

        (uint256 quotedBuy,) = IDexQuoter(_dexQuoter()).quoteExactInputSingle(
            IDexQuoter.QuoteExactSingleParams({poolKey: k, zeroForOne: true, exactAmount: uint128(amount), hookData: ""})
        );
        assertGt(quotedBuy, 0, "the quoter reads the pool");
        (uint256 paid, uint256 got) = _routerSwap(traders[3], token, true, true, amount, quotedBuy, amount);
        assertEq(paid, amount);
        assertEq(got, quotedBuy, "fill == quote on a buy");

        uint256 half = got / 2;
        (uint256 quotedSell,) = IDexQuoter(_dexQuoter()).quoteExactInputSingle(
            IDexQuoter.QuoteExactSingleParams({poolKey: k, zeroForOne: false, exactAmount: uint128(half), hookData: ""})
        );
        uint256 before = traders[3].balance;
        (, uint256 back) = _routerSwap(traders[3], token, false, true, half, quotedSell, 0);
        assertEq(back, quotedSell, "fill == quote on a sell");
        assertEq(traders[3].balance - before, back, "the native coin arrived");
        assertEq(_vaultClaims(k.currency0), vault.totalOwed(k.currency0), "the vault holds what it owes");
    }

    /// @notice A launch with a first buy, trades both ways, 70/30 of the tier on a Creator coin, then the sweep and the claim
    ///         empty the books.
    function test_fork_creatorLaunchTradeFeesClaim() public {
        uint256 amount = _trade();
        address token = _launchWith(creator, TAX, _targets()[2], amount / 10);
        assertGt(IERC20(token).balanceOf(creator), 0, "first buy landed");
        assertEq(uint8(vault.launchTypeOf(token)), uint8(LaunchType.Creator));
        _skipSniperWindow(token);

        address t = traders[0];
        (uint256 paid, uint256 got) = _routerSwap(t, token, true, true, amount, 1, amount);
        assertEq(paid, amount);
        assertGt(got, 0);
        (uint256 sold,) = _routerSwap(t, token, false, true, got / 2, 1, 0);
        assertEq(sold, got / 2);

        uint256 coin = vault.coinOwed(token);
        uint256 cut = vault.platformOwed(token);
        uint256 mkt = vault.marketingOwed(token);
        assertGt(coin, 0);
        assertApproxEqRel(coin * 30, (cut + mkt) * 70, 0.001e18, "the coin gets 70% of the tier");

        uint256 before = platform.balance + marketing.balance;
        vm.prank(claimer);
        vault.sweep(_one(token));
        assertEq(platform.balance + marketing.balance - before, cut + mkt);
        before = creator.balance;
        vm.prank(creator);
        vault.claimCreator(token);
        assertEq(creator.balance - before, coin);
        assertEq(vault.totalOwed(NATIVE), 0);
    }

    /// @notice A Pot coin: fees fill its pot, the creator can't claim it, the distributor pays it out, and it can't overspend.
    function test_fork_potCoin() public {
        uint256 amount = _trade();
        StealthFactory.LaunchParams memory p = _params(TAX, _targets()[2], 0);
        p.options = _typed(LaunchType.Pot);
        vm.prank(creator);
        address token = factory.launch(p);
        _skipSniperWindow(token);
        _routerSwap(traders[1], token, true, true, amount, 1, amount);

        uint256 pot = vault.coinOwed(token);
        assertGt(pot, 0, "the pot filled");
        vm.prank(creator);
        vm.expectRevert();
        vault.claimCreator(token);

        address[] memory to = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        to[0] = _actor("holderA");
        to[1] = _actor("holderB");
        amounts[0] = pot / 2;
        amounts[1] = pot - pot / 2 + 1;
        vm.prank(distributor);
        vm.expectRevert();
        vault.withdrawPot(token, to, amounts, 0);
        amounts[1] = pot - pot / 2;
        vm.prank(attacker);
        vm.expectRevert();
        vault.withdrawPot(token, to, amounts, 0);
        vm.prank(distributor);
        assertEq(vault.withdrawPot(token, to, amounts, 0), pot);
        assertEq(to[0].balance, pot / 2);
        assertEq(to[1].balance, pot - pot / 2);
        assertEq(vault.coinOwed(token), 0);
    }

    /// @notice Graduation at the deploy's default target, and trading after it.
    function test_fork_graduates() public {
        address token = _launchWith(creator, TAX, _targets()[2], 0);
        _skipSniperWindow(token);
        vm.deal(traders[2], _targets()[4] * 2);
        _graduate(token, traders[2]);
        assertTrue(hook.graduated(token));
        (, uint256 raised,,) = locker.progress(token);
        assertGe(raised, _targets()[2]);
        uint256 half = IERC20(token).balanceOf(traders[2]) / 2;
        (uint256 sold, uint256 back) = _routerSwap(traders[2], token, false, true, half, 1, 0);
        assertEq(sold, half);
        assertGt(back, 0);
    }
}

/// @notice Base: ETH, so Robinhood's targets as they stand.
contract BaseChainFork is NewChainFork {
    function _index() internal pure override returns (uint256) {
        return 2;
    }

    function _rpcEnv() internal pure override returns (string memory) {
        return "STEALTH_BASE_RPC";
    }

    function _expectedChainId() internal pure override returns (uint256) {
        return 8453;
    }

    function _targets() internal pure override returns (uint256[5] memory) {
        return [uint256(1.5 ether), 2.5 ether, 3.5 ether, 8 ether, 15 ether];
    }

    function _trade() internal pure override returns (uint256) {
        return 0.5 ether;
    }
}

/// @notice Arc: USDC as an 18-decimal native coin, so the same raise in dollars.
contract ArcChainFork is NewChainFork {
    function _index() internal pure override returns (uint256) {
        return 3;
    }

    function _rpcEnv() internal pure override returns (string memory) {
        return "STEALTH_ARC_RPC";
    }

    function _expectedChainId() internal pure override returns (uint256) {
        return 5042;
    }

    function _targets() internal pure override returns (uint256[5] memory) {
        return [uint256(3_500 ether), 5_500 ether, 8_000 ether, 18_000 ether, 35_000 ether];
    }

    function _trade() internal pure override returns (uint256) {
        return 1_000 ether;
    }
}
