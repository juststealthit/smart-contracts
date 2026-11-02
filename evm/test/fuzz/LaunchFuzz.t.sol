// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthConstants as C} from "../../src/libraries/StealthConstants.sol";
import {StealthDeploy} from "../../script/lib/StealthDeploy.sol";
import {Currency} from "@dex/Dex.sol";
import {MockERC20} from "../utils/MockTokens.sol";
import {tierOf} from "../utils/Tiers.sol";

/// @notice Every launch works: any target, any tier, any first buy. The first buy's quote is exact, the refund is
///         exact, and every token ends up in the pool or with the creator.
abstract contract LaunchFuzzBase is BaseTest {
    function _minTarget() internal view virtual returns (uint256);
    function _maxTarget() internal view virtual returns (uint256);

    function setUp() public virtual override {
        super.setUp();
        vm.deal(creator, 1_000_000 ether);
    }

    function testFuzz_launch(uint16 taxSeed, uint256 targetSeed, uint256 devEth) public {
        uint16 tax = tierOf(taxSeed);
        uint256 target = bound(targetSeed, _minTarget(), _maxTarget());
        devEth = bound(devEth, 0, target);
        (uint256 quotedTokens, uint256 quotedEth) = locker.quoteLaunchBuy(target, tax, devEth);
        if (devEth > 0 && quotedTokens == 0) {
            vm.prank(creator);
            vm.expectRevert(StealthLocker.ZeroAmount.selector);
            factory.launch{value: devEth}(_params(tax, target, 0));
            return;
        }

        uint256 before = creator.balance;
        address token = _launchWith(creator, tax, target, devEth);
        StealthLocker.PoolInfo memory info = locker.getPool(token);

        assertEq(IERC20(token).balanceOf(creator), quotedTokens, "tokens match the quote to the wei");
        assertEq(before - creator.balance, quotedEth, "kept exactly what the quote said; the rest refunded");
        assertLe(quotedTokens, C.LAUNCH_ALLOWANCE, "never more than 5%");
        assertEq(IERC20(token).balanceOf(address(locker)), 0, "no token left with the locker");
        assertEq(
            IERC20(token).balanceOf(settlementAddr) + quotedTokens, IERC20(token).totalSupply(), "pool + creator = supply"
        );
        assertLe(_sqrtPrice(token), info.startSqrtPriceX96);
        assertFalse(hook.graduated(token), "a first buy never graduates");
        assertApproxEqRel(info.graduationQuote, target, 3e15);
        // The first buy's fee went to the vault in native, at the tier: the rate on what was kept, plus at
        // most the rate on the few wei the cap left unswapped.
        uint256 fee = _vaultClaims();
        assertEq(fee, vault.totalOwed(NATIVE), "vault claims == owed");
        assertGe(fee, _feeOnInput(quotedEth, uint24(tax) * 100), "at least the tax on the native kept");
        assertLe(fee, _feeOnInput(quotedEth + 2_000, uint24(tax) * 100), "never more than the tax plus rounding wei");
    }
}

contract LaunchFuzzMainnet is LaunchFuzzBase {
    function _minTarget() internal pure override returns (uint256) {
        return 4 ether;
    }

    function _maxTarget() internal pure override returns (uint256) {
        return 10 ether;
    }
}

contract LaunchFuzzTestnet is LaunchFuzzBase {
    function _deployParams() internal override returns (StealthDeploy.Params memory p) {
        p = super._deployParams();
        p.targetFloor = 0.01 ether;
        p.targetCeiling = 1 ether;
        p.config = StealthDeploy.config(0.01 ether, 0.075 ether, 0.1875 ether);
    }

    function _minTarget() internal pure override returns (uint256) {
        return 0.01 ether;
    }

    function _maxTarget() internal pure override returns (uint256) {
        return 0.1875 ether;
    }
}

contract LaunchFuzzExtremes is LaunchFuzzBase {
    function _deployParams() internal override returns (StealthDeploy.Params memory p) {
        p = super._deployParams();
        p.targetFloor = C.MIN_TARGET_FLOOR;
        p.targetCeiling = C.MAX_TARGET_CEILING;
        p.config.minTarget = uint128(C.MIN_TARGET_FLOOR);
        p.config.defaultTarget = uint128(C.MIN_TARGET_FLOOR);
        p.config.maxTarget = uint128(C.MAX_TARGET_CEILING);
    }

    function _minTarget() internal pure override returns (uint256) {
        return C.MIN_TARGET_FLOOR;
    }

    function _maxTarget() internal pure override returns (uint256) {
        return C.MAX_TARGET_CEILING;
    }

    /// @dev Graduation works at the extremes too.
    function testFuzz_graduateAnyTarget(uint16 taxSeed, uint256 targetSeed) public {
        uint16 tax = tierOf(taxSeed);
        uint256 target = bound(targetSeed, C.MIN_TARGET_FLOOR, C.MAX_TARGET_CEILING);
        address token = _launchWith(creator, tax, target, 0);
        _skipSniperWindow(token);
        _graduate(token, traders[0]);
        (, uint256 raised,, bool graduated) = locker.progress(token);
        assertTrue(graduated);
        assertGe(raised, locker.getPool(token).graduationQuote);
    }
}

/// @notice The same guarantees for tokens paired with an ERC-20, across the whole generic target range of its
///         decimals: the first buy is exact, the unused quote (and the transfer-check probe) comes back to the unit.
abstract contract LaunchFuzzQuoteBase is BaseTest {
    MockERC20 internal q;

    function _decimals() internal pure virtual returns (uint8);

    function setUp() public override {
        super.setUp();
        q = new MockERC20("Fuzz Quote", "FQ", _decimals());
        vm.prank(admin);
        factory.setUnlistedQuotesAllowed(true);
        _syncConfig();
    }

    function testFuzz_launchQuote(uint16 taxSeed, uint256 targetSeed, uint256 devSeed) public {
        uint16 tax = tierOf(taxSeed);
        (uint256 lo, uint256 hi) = factory.quoteTargetBounds(_decimals());
        uint256 target = bound(targetSeed, lo, hi);
        uint256 dev = bound(devSeed, 0, target);
        (uint256 quotedTokens, uint256 quotedUsed) = locker.quoteLaunchBuy(target, tax, dev);
        uint256 probe = factory.quoteProbeAmount(address(q));
        uint256 pull = dev > probe ? dev : probe;
        q.mint(creator, pull);
        vm.prank(creator);
        q.approve(address(factory), pull);
        if (dev > 0 && quotedTokens == 0) {
            vm.prank(creator);
            vm.expectRevert(StealthLocker.ZeroAmount.selector);
            factory.launch(_paramsQ(address(q), tax, target, dev, 0));
            return;
        }
        vm.prank(creator);
        address token = factory.launch(_paramsQ(address(q), tax, target, dev, 0));
        Currency qc = Currency.wrap(address(q));
        assertEq(IERC20(token).balanceOf(creator), quotedTokens, "tokens match the quote to the unit");
        assertEq(pull - q.balanceOf(creator), quotedUsed, "kept exactly what the quote said; the rest refunded");
        assertLe(quotedTokens, C.LAUNCH_ALLOWANCE);
        assertEq(q.balanceOf(address(locker)) + q.balanceOf(address(factory)), 0, "no quote left behind");
        assertEq(
            IERC20(token).balanceOf(settlementAddr) + quotedTokens, IERC20(token).totalSupply(), "pool + creator = supply"
        );
        assertFalse(hook.graduated(token), "a first buy never graduates");
        assertApproxEqRel(locker.getPool(token).graduationQuote, target, 3e15);
        uint256 fee = _vaultClaims(qc);
        assertEq(fee, vault.totalOwed(qc), "vault claims == owed");
        assertGe(fee, _feeOnInput(quotedUsed, uint24(tax) * 100), "at least the tax on the quote kept");
        assertLe(fee, _feeOnInput(quotedUsed + 2_000, uint24(tax) * 100), "never more than the tax plus rounding");
    }

    /// @dev Graduation works anywhere in the generic range too.
    function testFuzz_graduateAnyQuoteTarget(uint16 taxSeed, uint256 targetSeed) public {
        uint16 tax = tierOf(taxSeed);
        (uint256 lo, uint256 hi) = factory.quoteTargetBounds(_decimals());
        uint256 target = bound(targetSeed, lo, hi);
        address token = _launchQuote(creator, address(q), tax, target, 0);
        _skipSniperWindow(token);
        _graduate(token, traders[0]);
        (, uint256 raised,, bool graduated) = locker.progress(token);
        assertTrue(graduated);
        assertGe(raised, locker.getPool(token).graduationQuote);
        // Sell everything back: the pool returns to at most the start price and owes nothing.
        _sell(traders[0], token, IERC20(token).balanceOf(traders[0]));
        assertLe(_sqrtPrice(token), locker.getPool(token).startSqrtPriceX96);
        Currency qc = Currency.wrap(address(q));
        assertEq(_vaultClaims(qc), vault.totalOwed(qc));
    }
}

contract LaunchFuzzQuote18 is LaunchFuzzQuoteBase {
    function _decimals() internal pure override returns (uint8) {
        return 18;
    }
}

contract LaunchFuzzQuote6 is LaunchFuzzQuoteBase {
    function _decimals() internal pure override returns (uint8) {
        return 6;
    }
}
