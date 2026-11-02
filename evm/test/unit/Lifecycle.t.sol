// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthToken} from "../../src/StealthToken.sol";
import {StealthConstants as C} from "../../src/libraries/StealthConstants.sol";

/// @notice End to end: launch with a first buy, sniper window, trading, graduation, fees in native, sweep and claims.
contract LifecycleTest is BaseTest {
    function test_deploymentWiring() public view {
        assertEq(hook.locker(), address(locker));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(address(hook.settlement()), settlementAddr);
        assertEq(address(locker.hook()), address(hook));
        assertEq(address(locker.feeVault()), address(vault));
        assertEq(address(locker.settlement()), settlementAddr);
        assertEq(address(locker.poolManager()), address(manager));
        assertEq(locker.factory(), address(factory));
        assertEq(vault.hook(), address(hook));
        assertEq(address(vault.settlement()), settlementAddr);
        assertEq(vault.platform(), platform);
        assertEq(vault.marketing(), marketing);
        assertEq(vault.distributor(), distributor);
        assertEq(vault.creatorManager(), creatorManager);
        assertEq(address(hook.feeVault()), address(vault));
        assertEq(vault.factory(), address(factory));
        assertEq(tokenDeployer.factory(), address(factory));
        assertEq(address(factory.locker()), address(locker));
        assertEq(address(factory.tokenDeployer()), address(tokenDeployer));
        assertEq(factory.admin(), admin);
    }

    function test_fullLifecycle() public {
        // Launch: the 4.25% tier, 4 native target, a 1 native first buy (more than 5% of supply costs).
        uint256 creatorBefore = creator.balance;
        address token = _launchWith(creator, TAX, 4 ether, 1 ether);
        StealthToken t = StealthToken(token);
        assertEq(t.deployer(), creator);
        assertEq(t.launchFactory(), address(factory));
        assertEq(t.poolId(), _poolId(token), "token knows its pool");
        assertEq(t.launchpad(), "Stealth");
        assertLe(IERC20(token).balanceOf(creator), C.LAUNCH_ALLOWANCE, "first buy capped at 5%");
        assertApproxEqRel(IERC20(token).balanceOf(creator), C.LAUNCH_ALLOWANCE, 1e12);
        assertLt(creatorBefore - creator.balance, 0.1 ether, "unused native refunded");
        assertEq(IERC20(token).balanceOf(address(locker)), 0, "every token placed");

        // Inside the window everyone else pays the 90% sniper fee, in native.
        assertEq(hook.currentFee(token), 900_000);
        uint256 c0 = _vaultClaims();
        uint256 sniped = _buy(sniper, token, 1 ether);
        assertGt(sniped, 0);
        assertEq(_vaultClaims() - c0, 0.9 ether);

        // After the window: the tier.
        _skipSniperWindow(token);
        assertEq(hook.currentFee(token), TAX_PIPS);
        uint256 got = _buy(traders[0], token, 1 ether);
        _sell(traders[0], token, got / 2);

        // Graduate, then trade on.
        _graduate(token, traders[1]);
        (, uint256 raised,, bool graduated) = locker.progress(token);
        assertTrue(graduated);
        assertGe(raised, locker.getPool(token).graduationQuote);
        _buy(traders[2], token, 0.5 ether);
        _buyExactOut(traders[3], token, 1_000_000e18, 1 ether);
        _sell(traders[2], token, IERC20(token).balanceOf(traders[2]) / 2);
        _sellExactOut(traders[3], token, 0.01 ether);

        // Every fee is already in the vault, as native claims: nothing sits in the pool or the locker.
        assertEq(_vaultClaims(), _vaultOwed(_one(token)), "vault holds exactly what it owes");
        assertEq(address(locker).balance, 0, "locker keeps no native");
        assertEq(IERC20(token).balanceOf(address(locker)), 0, "locker keeps no tokens");
        assertEq(IERC20(token).balanceOf(address(vault)), 0, "vault keeps no tokens");

        uint256 m = vault.marketingOwed(token);
        uint256 p = vault.platformOwed(token);
        uint256 cOwed = vault.coinOwed(token);
        uint256 mb = marketing.balance;
        uint256 tb = platform.balance;
        uint256 cb = creator.balance;
        vault.sweep(_one(token));
        vm.prank(creator);
        vault.claimCreator(token);
        assertEq(marketing.balance - mb, m);
        assertEq(platform.balance - tb, p);
        assertEq(creator.balance - cb, cOwed);
        assertEq(_vaultClaims(), 0, "vault fully paid out");
        assertEq(vault.totalOwed(NATIVE), 0);
    }
}
