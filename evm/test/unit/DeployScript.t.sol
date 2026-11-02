// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Dex} from "@dex/Dex.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthHook} from "../../src/StealthHook.sol";
import {StealthDeploy} from "../../script/lib/StealthDeploy.sol";

/// @notice Pins the deploy library every deployment goes through: the settings it starts from, the address prediction
///         the immutables depend on, and the hook salt.
contract DeployScriptTest is BaseTest {
    function test_config_refusesUnlistedQuotesByDefault() public pure {
        StealthFactory.Config memory c = StealthDeploy.config(8 ether, 16 ether, 30 ether);
        assertEq(c.minTarget, 8 ether);
        assertEq(c.defaultTarget, 16 ether);
        assertEq(c.maxTarget, 30 ether);
        assertEq(c.launchFee, 0, "no launch fee by default");
        assertFalse(c.launchesPaused);
        assertFalse(c.unlistedQuotesAllowed, "mainnet lists each quote");
    }

    /// @notice What `predict` says is what `deploy` builds, and a second deployment from the same deployer works.
    function test_predictMatchesDeploy() public {
        StealthDeploy.Params memory p = _deployParams();
        StealthDeploy.Predicted memory a = StealthDeploy.predict(p, address(this));
        StealthDeploy.System memory s = StealthDeploy.deploy(p, address(this));
        assertEq(address(s.router), a.router);
        assertEq(address(s.feeVault), a.feeVault);
        assertEq(address(s.tokenDeployer), a.tokenDeployer);
        assertEq(address(s.locker), a.locker);
        assertEq(address(s.factory), a.factory);
        assertEq(address(s.hook), a.hook);
        assertEq(s.feeVault.platform(), p.platform, "wallets come from the parameters");
        assertEq(s.feeVault.marketing(), p.marketing);
        assertEq(address(s.router.permit2()), p.permit2);
        assertEq(s.factory.admin(), p.admin);
        assertEq(s.factory.targetFloor(), p.targetFloor);
        assertEq(s.factory.targetCeiling(), p.targetCeiling);
    }

    function test_hookSaltCarriesThePermissionBits() public view {
        bytes32 initHash = keccak256(abi.encodePacked(type(StealthHook).creationCode, abi.encode(manager, vault)));
        (, address mined) = StealthDeploy.mineHookSalt(address(this), initHash);
        assertEq(uint160(mined) & Dex.HOOK_ADDRESS_MASK, Dex.HOOK_ADDRESS_FLAGS);
    }
}
