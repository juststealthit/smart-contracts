// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {StealthDeploy} from "../../script/lib/StealthDeploy.sol";

/// @notice The deploy script: dry run by default, every address from the environment, refuses a mismatched chain.
contract DeployDryRunTest is BaseTest {
    Deploy internal script;
    address internal dep = makeAddr("freshDeployer");

    function setUp() public override {
        super.setUp();
        script = new Deploy();
        vm.setEnv("STEALTH_DEPLOYER", vm.toString(dep));
        vm.setEnv("STEALTH_POOL_MANAGER", vm.toString(address(manager)));
        vm.setEnv("STEALTH_PERMIT2", vm.toString(_dexPermit2()));
        vm.setEnv("STEALTH_ADMIN", vm.toString(admin));
        vm.setEnv("STEALTH_PLATFORM_WALLET", vm.toString(platform));
        vm.setEnv("STEALTH_MARKETING_WALLET", vm.toString(marketing));
        vm.setEnv("STEALTH_CREATOR_MANAGER", vm.toString(creatorManager));
        vm.setEnv("STEALTH_DISTRIBUTOR", vm.toString(distributor));
        vm.setEnv("STEALTH_TARGET_FLOOR", "4000000000000000000");
        vm.setEnv("STEALTH_TARGET_CEILING", "10000000000000000000");
        vm.setEnv("STEALTH_TARGET_MIN", "4000000000000000000");
        vm.setEnv("STEALTH_TARGET_DEFAULT", "4000000000000000000");
        vm.setEnv("STEALTH_TARGET_MAX", "10000000000000000000");
        vm.setEnv("STEALTH_BROADCAST", "false");
        vm.setEnv("DEPLOYER_PK", "0");
    }

    /// @dev One test on purpose: the environment is shared by every thread of the test run.
    function test_deployScript() public {
        // Dry run by default: deploys only in simulation, with the wallets from the environment, and writes no file.
        StealthDeploy.System memory s = script.run();
        assertEq(s.feeVault.platform(), platform);
        assertEq(s.feeVault.marketing(), marketing);
        assertEq(s.feeVault.distributor(), distributor);
        assertEq(s.factory.admin(), admin);
        assertEq(address(s.feeVault.poolManager()), address(manager));
        assertFalse(vm.exists(string.concat("deployments/", vm.toString(block.chainid), ".json")), "no file");

        // Going live needs the chain repeated.
        vm.setEnv("STEALTH_BROADCAST", "true");
        vm.setEnv("STEALTH_CONFIRM_CHAIN", "1");
        vm.expectRevert(abi.encodeWithSelector(Deploy.ConfirmChain.selector, block.chainid));
        script.run();
        vm.setEnv("STEALTH_BROADCAST", "false");

        // A build on the other DEX's chain is refused.
        uint256 chain = block.chainid;
        vm.chainId(keccak256(bytes(DEX_NAME)) == keccak256("infinity") ? 4663 : 56);
        vm.expectPartialRevert(Deploy.WrongBuildForChain.selector);
        script.run();
        vm.chainId(chain);

        // Base and Arc are v4 chains: the Infinity build is refused there.
        if (keccak256(bytes(DEX_NAME)) == keccak256("infinity")) {
            vm.chainId(8453);
            vm.expectPartialRevert(Deploy.WrongBuildForChain.selector);
            script.run();
            vm.chainId(5042);
            vm.expectPartialRevert(Deploy.WrongBuildForChain.selector);
            script.run();
            vm.chainId(chain);
        }

        // A missing address stops it.
        vm.setEnv("STEALTH_PLATFORM_WALLET", "");
        vm.expectRevert();
        script.run();
    }
}
