// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Dex, IDexManager} from "@dex/Dex.sol";
import {StealthDeploy} from "./lib/StealthDeploy.sol";
import {StealthFactory} from "../src/StealthFactory.sol";

/// @title Deploy
/// @notice Deploys Stealth on one chain. Every address and target comes from the environment; nothing is hardcoded.
///         A DRY RUN BY DEFAULT: without `STEALTH_BROADCAST=true` the script only simulates (it never opens a
///         broadcast, so `--broadcast` on the command line has nothing to send), logs what it would deploy, and writes
///         no file. To go live both are needed: `STEALTH_BROADCAST=true` and `--broadcast`, and
///         `STEALTH_CONFIRM_CHAIN` must repeat the chain id.
///
///         Build and chain must match: `forge script` (Uniswap v4) for Robinhood Chain 4663, HyperEVM 999, Base 8453, Arc
///         5042, Ethereum 1, Arbitrum One 42161, Avalanche C-Chain 43114 and the testnets 46630, 998; `FOUNDRY_PROFILE=infinity forge script` (PancakeSwap Infinity) for BNB Chain 56 and
///         its testnet 97. HyperEVM deploys need big blocks, which need a HyperCore account for the deployer.
///
///         A live run on a mainnet refuses `DEPLOYER_PK`: sign with `--ledger` or `--account`, with `--sender` equal to
///         `STEALTH_DEPLOYER`.
///
///         Environment (all required unless marked):
///           STEALTH_DEPLOYER          the address that deploys (its next five nonces are used)
///           STEALTH_POOL_MANAGER      Uniswap v4 PoolManager, or Infinity CLPoolManager
///           STEALTH_PERMIT2           the DEX's Permit2
///           STEALTH_ADMIN             factory admin
///           STEALTH_PLATFORM_WALLET   platform wallet (the same address on every chain)
///           STEALTH_MARKETING_WALLET  marketing wallet (the same address on every chain)
///           STEALTH_CREATOR_MANAGER   proposes takeovers
///           STEALTH_DISTRIBUTOR       the ops bot: pays holders and general pots, spends buyback pots
///           STEALTH_TARGET_FLOOR, STEALTH_TARGET_CEILING        immutable native target bounds, wei
///           STEALTH_TARGET_MIN, STEALTH_TARGET_DEFAULT, STEALTH_TARGET_MAX   the first target range, wei
///           STEALTH_REASSIGN_NOTICE   optional, seconds, default 24 hours
///           STEALTH_LAUNCH_FEE        optional, wei, default 0
///           STEALTH_ALLOW_UNLISTED    optional, default false (testnets only: quotes the admin has not listed)
contract Deploy is Script {
    error WrongBuildForChain(uint256 chainId, string build);
    error ConfirmChain(uint256 chainId);
    error KeyFileOnMainnet();

    function run() external returns (StealthDeploy.System memory s) {
        _checkBuild();
        bool live = vm.envOr("STEALTH_BROADCAST", false);
        address deployer = vm.envAddress("STEALTH_DEPLOYER");
        StealthDeploy.Params memory p = params();

        if (live) {
            if (vm.envOr("STEALTH_CONFIRM_CHAIN", uint256(0)) != block.chainid) revert ConfirmChain(block.chainid);
            if (_isMainnet() && vm.envOr("DEPLOYER_PK", uint256(0)) != 0) revert KeyFileOnMainnet();
            uint256 key = vm.envOr("DEPLOYER_PK", uint256(0));
            if (key != 0) vm.startBroadcast(key);
            else vm.startBroadcast(deployer);
        } else {
            vm.startPrank(deployer);
        }
        s = StealthDeploy.deploy(p, deployer);
        if (live) {
            vm.stopBroadcast();
            _write(s);
        } else {
            vm.stopPrank();
        }

        console2.log(live ? "LIVE deploy" : "DRY RUN: nothing was sent", Dex.NAME, block.chainid);
        console2.log("StealthRouter", address(s.router));
        console2.log("StealthFeeVault", address(s.feeVault));
        console2.log("StealthTokenDeployer", address(s.tokenDeployer));
        console2.log("StealthToken implementation", address(s.tokenDeployer.implementation()));
        console2.log("StealthLocker", address(s.locker));
        console2.log("StealthHook", address(s.hook));
        console2.log("StealthFactory", address(s.factory));
    }

    /// @notice The deploy parameters, from the environment.
    function params() public view returns (StealthDeploy.Params memory p) {
        p.poolManager = IDexManager(vm.envAddress("STEALTH_POOL_MANAGER"));
        p.permit2 = vm.envAddress("STEALTH_PERMIT2");
        p.admin = vm.envAddress("STEALTH_ADMIN");
        p.platform = vm.envAddress("STEALTH_PLATFORM_WALLET");
        p.marketing = vm.envAddress("STEALTH_MARKETING_WALLET");
        p.creatorManager = vm.envAddress("STEALTH_CREATOR_MANAGER");
        p.distributor = vm.envAddress("STEALTH_DISTRIBUTOR");
        p.reassignNotice = vm.envOr("STEALTH_REASSIGN_NOTICE", uint256(24 hours));
        p.targetFloor = vm.envUint("STEALTH_TARGET_FLOOR");
        p.targetCeiling = vm.envUint("STEALTH_TARGET_CEILING");
        p.config = StealthDeploy.config(
            vm.envUint("STEALTH_TARGET_MIN"), vm.envUint("STEALTH_TARGET_DEFAULT"), vm.envUint("STEALTH_TARGET_MAX")
        );
        p.config.launchFee = uint96(vm.envOr("STEALTH_LAUNCH_FEE", uint256(0)));
        p.config.unlistedQuotesAllowed = vm.envOr("STEALTH_ALLOW_UNLISTED", false);
    }

    function _isMainnet() internal view returns (bool) {
        return block.chainid == 4663 || block.chainid == 999 || block.chainid == 56 || block.chainid == 8453
            || block.chainid == 5042 || block.chainid == 1 || block.chainid == 42161 || block.chainid == 43114;
    }

    /// @dev A v4 build on BNB Chain, or an Infinity build on the other chains, would deploy against the wrong manager.
    function _checkBuild() internal view {
        bool infinityChain = block.chainid == 56 || block.chainid == 97;
        bool v4Chain =
            block.chainid == 4663 || block.chainid == 46630 || block.chainid == 999 || block.chainid == 998
                || block.chainid == 8453 || block.chainid == 5042 || block.chainid == 1 || block.chainid == 42161
                || block.chainid == 43114;
        bool infinityBuild = keccak256(bytes(Dex.NAME)) == keccak256("pancakeswap-infinity");
        if ((infinityChain && !infinityBuild) || (v4Chain && infinityBuild)) {
            revert WrongBuildForChain(block.chainid, Dex.NAME);
        }
    }

    function _write(StealthDeploy.System memory s) internal {
        string memory o = "deployment";
        vm.serializeString(o, "dex", Dex.NAME);
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "router", address(s.router));
        vm.serializeAddress(o, "feeVault", address(s.feeVault));
        vm.serializeAddress(o, "tokenDeployer", address(s.tokenDeployer));
        vm.serializeAddress(o, "tokenImplementation", address(s.tokenDeployer.implementation()));
        vm.serializeAddress(o, "locker", address(s.locker));
        vm.serializeAddress(o, "hook", address(s.hook));
        string memory json = vm.serializeAddress(o, "factory", address(s.factory));
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
