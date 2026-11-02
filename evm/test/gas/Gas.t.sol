// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Dex, IDexManager, PoolKey} from "@dex/Dex.sol";
import {TestRouter} from "../utils/TestRouter.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthToken} from "../../src/StealthToken.sol";
import {LaunchType} from "../../src/interfaces/IStealth.sol";
import {MockERC20} from "../utils/MockTokens.sol";

/// @notice Gas per action. Run with `forge test --isolate --match-path test/gas/Gas.t.sol`, so each call is its own
///         transaction with cold storage, as on chain.
///         local anvil. Swaps include the test router's own overhead (roughly what a router adds in production).
contract GasTest is BaseTest {
    /// @dev The hard constraint for the v4 build: HyperEVM small blocks had a 2M limit recently. BNB Chain has no such
    ///      limit; its ceiling here only guards against regressions.
    uint256 internal immutable LAUNCH_GAS_LIMIT =
        keccak256(bytes(Dex.NAME)) == keccak256("uniswap-v4") ? 2_000_000 : 2_200_000;

    function _snap(string memory name) internal {
        vm.snapshotGasLastCall(name);
        console2.log(name, vm.lastCallGas().gasTotalUsed);
    }

    function test_gas_actions() public {
        StealthFactory.LaunchParams memory p = _params(TAX, TARGET, 0);
        vm.prank(creator);
        factory.launch(p);
        _snap("launch");
        assertLe(vm.lastCallGas().gasTotalUsed, LAUNCH_GAS_LIMIT);

        vm.prank(creator2);
        address token = factory.launch{value: 0.05 ether}(p);
        _snap("launch_withFirstBuy");
        assertLe(vm.lastCallGas().gasTotalUsed, LAUNCH_GAS_LIMIT);

        _swapGas(traders[0], token, true, -0.1 ether, 0.1 ether);
        _snap("buy_inSniperWindow");
        _skipSniperWindow(token);

        _swapGas(traders[1], token, true, -0.5 ether, 0.5 ether);
        _snap("buy_exactIn");
        _swapGas(traders[1], token, true, 1_000_000e18, 1 ether);
        _snap("buy_exactOut");

        uint256 half = IERC20(token).balanceOf(traders[1]) / 2;
        vm.prank(traders[1]);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        _swapGas(traders[1], token, false, -int256(half), 0);
        _snap("sell_exactIn");
        _swapGas(traders[1], token, false, 0.01 ether, 0);
        _snap("sell_exactOut");

        uint256 fee = hook.currentFee(token);
        (, uint256 raised,,) = locker.progress(token);
        uint256 need = (locker.getPool(token).graduationQuote - raised) * 1_000_000 / (1_000_000 - fee) * 101 / 100;
        vm.deal(traders[2], need);
        _swapGas(traders[2], token, true, -int256(need), need);
        _snap("buy_thatGraduates");

        vm.prank(creator2);
        vault.claimCreator(token);
        _snap("claimCreator");
        vm.prank(claimer);
        vault.sweep(_one(token));
        _snap("sweep_oneToken");

        address[] memory five = new address[](5);
        for (uint256 i; i < 5; ++i) {
            vm.prank(traders[i]);
            five[i] = factory.launch(_params(TAX, TARGET, 0));
        }
        _skipSniperWindow(five[4]);
        for (uint256 i; i < 5; ++i) {
            _swapGas(traders[5], five[i], true, -0.1 ether, 0.1 ether);
        }
        vm.prank(claimer);
        vault.sweep(five);
        _snap("sweep_fiveTokens");
    }

    function test_gas_routerSwaps() public {
        address token = _launch(TAX, TARGET);
        _swapGas(traders[0], token, true, -0.5 ether, 0.5 ether); // the pool's first trade, for steady-state numbers
        _routerSwap(traders[1], token, true, true, 0.1 ether, 0, 0.1 ether);
        _snap("router_buy_exactIn");
        vm.prank(traders[1]);
        IERC20(token).approve(address(stealthRouter), type(uint256).max);
        uint256 half = IERC20(token).balanceOf(traders[1]) / 2;
        _routerSwap(traders[1], token, false, true, half, 0, 0);
        _snap("router_sell_exactIn");
    }

    function test_gas_buyback() public {
        address token = _launchOpts(creator, TAX, 0, _typed(LaunchType.Buyback));
        _skipSniperWindow(token);
        _swapGas(traders[0], token, true, -5 ether, 5 ether);
        uint256 pot = vault.coinOwed(token);
        uint256 deadline = block.timestamp;
        vm.prank(distributor);
        vault.buyback(token, pot / 2, 1, deadline, 0);
        _snap("buyback");
    }

    /// @dev ERC-20 launches: the transfer check, and the token-address search (one try for most quotes; a quote at
    ///      0xff00... needs about 256).
    function test_gas_erc20Launches() public {
        vm.prank(admin);
        factory.setUnlistedQuotesAllowed(true);
        _syncConfig();
        MockERC20 q = new MockERC20("Q", "Q", 18);
        q.mint(creator, 1_000e18);
        vm.prank(creator);
        q.approve(address(factory), type(uint256).max);
        StealthFactory.LaunchParams memory p = _paramsQ(address(q), TAX, 4e18, 0, 0);
        vm.prank(creator);
        factory.launch(p);
        _snap("launch_erc20_probeOnly");
        p = _paramsQ(address(q), TAX, 4e18, 1e18, 0);
        vm.prank(creator);
        factory.launch(p);
        _snap("launch_erc20_withFirstBuy");
        assertLe(vm.lastCallGas().gasTotalUsed, LAUNCH_GAS_LIMIT);

        address high = address(uint160(0xff) << 152);
        deployCodeTo("MockTokens.sol:MockERC20", abi.encode("High", "HI", uint8(18)), high);
        MockERC20(high).mint(creator, 1_000e18);
        vm.prank(creator);
        MockERC20(high).approve(address(factory), type(uint256).max);
        p = _paramsQ(high, TAX, 4e18, 0, 0);
        vm.prank(creator);
        factory.launch(p);
        _snap("launch_erc20_quoteAt0xff00");
    }

    /// @notice The heaviest launch the contracts accept with the default salt search: all metadata at its limit, a
    ///         10-wallet team, max wallet, max buy, a first-buy lock and a first buy paid in an ERC-20. It must fit too:
    ///         a launch that only sometimes fits a small block is a launch that sometimes fails.
    function test_gas_worstCaseLaunch() public {
        MockERC20 q = _listedQuote("Q", 18, 1, 1_000_000);
        q.mint(creator, 1_000e18);
        vm.prank(creator);
        q.approve(address(factory), type(uint256).max);
        StealthFactory.LaunchParams memory p = _paramsQ(address(q), 575, 4e18, 1e16, 0);
        p.name = _fill(64);
        p.symbol = _fill(32);
        p.logo = _fill(512);
        p.description = _fill(1024);
        p.socials = StealthToken.Socials(_fill(256), _fill(256), _fill(256), _fill(256), _fill(256));
        address[] memory wallets = new address[](10);
        uint16[] memory bps = new uint16[](10);
        for (uint256 i; i < 10; ++i) {
            wallets[i] = makeAddr(string.concat("team", vm.toString(i)));
            bps[i] = 1_000;
        }
        p.options = _teamOf(wallets, bps);
        p.options.maxWalletBps = 500;
        p.options.maxBuyBps = 500;
        p.options.limitsWindow = 3600;
        p.options.firstBuyLock = 90 days;
        vm.prank(creator);
        factory.launch(p);
        _snap("launch_worstCase");
        assertLe(vm.lastCallGas().gasTotalUsed, LAUNCH_GAS_LIMIT);
    }

    function _fill(uint256 length) internal pure returns (string memory) {
        bytes memory b = new bytes(length);
        for (uint256 i; i < length; ++i) {
            b[i] = bytes1(uint8(97 + i % 26));
        }
        return string(b);
    }

    function _swapGas(address who, address token, bool zeroForOne, int256 amount, uint256 value) internal {
        IDexManager.SwapParams memory sp = IDexManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        TestRouter.TestSettings memory settings = TestRouter.TestSettings({takeClaims: false, settleUsingBurn: false});
        PoolKey memory key = _key(token); // before the prank: it is an external call
        vm.prank(who);
        swapRouter.swap{value: value}(key, sp, settings, "");
    }
}
