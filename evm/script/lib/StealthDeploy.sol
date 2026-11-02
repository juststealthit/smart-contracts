// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Dex, IDexManager} from "@dex/Dex.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";
import {StealthLocker} from "../../src/StealthLocker.sol";
import {StealthHook} from "../../src/StealthHook.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";
import {StealthTokenDeployer} from "../../src/StealthTokenDeployer.sol";
import {StealthRouter, IAllowanceTransfer} from "../../src/StealthRouter.sol";
import {IStealthFeeVault} from "../../src/interfaces/IStealth.sol";

/// @title StealthDeploy
/// @notice Deploys and wires the whole system. Shared by the tests and the deploy script, so both run the same code.
/// @dev Contracts reference each other through immutables. Their addresses are predicted from the deployer's nonce
///      before anything is deployed. Order: StealthRouter (n), StealthFeeVault (n+1), StealthTokenDeployer (n+2, which
///      deploys the token implementation), StealthLocker (n+3, which deploys the hook with CREATE2), StealthFactory
///      (n+4). The StealthLocker and StealthFactory constructors revert if any prediction was wrong. On Uniswap v4 the
///      hook's salt is mined against the predicted locker; on Infinity the mask is 0, so salt 0 is taken.
library StealthDeploy {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant MAX_SALT_ITERATIONS = 1_000_000;

    struct Params {
        IDexManager poolManager;
        address admin;
        address platform;
        address marketing;
        address creatorManager;
        address distributor;
        address permit2;
        uint256 reassignNotice;
        uint256 targetFloor;
        uint256 targetCeiling;
        StealthFactory.Config config;
    }

    struct System {
        StealthRouter router;
        StealthFeeVault feeVault;
        StealthTokenDeployer tokenDeployer;
        StealthLocker locker;
        StealthHook hook;
        StealthFactory factory;
    }

    struct Predicted {
        address router;
        address feeVault;
        address tokenDeployer;
        address locker;
        address factory;
        address hook;
        bytes32 hookSalt;
    }

    /// @notice Predicts every address `deploy` will produce from `deployer`'s current nonce, and mines the hook salt.
    function predict(Params memory p, address deployer) internal view returns (Predicted memory a) {
        uint64 nonce = vm.getNonce(deployer);
        a.router = vm.computeCreateAddress(deployer, nonce);
        a.feeVault = vm.computeCreateAddress(deployer, nonce + 1);
        a.tokenDeployer = vm.computeCreateAddress(deployer, nonce + 2);
        a.locker = vm.computeCreateAddress(deployer, nonce + 3);
        a.factory = vm.computeCreateAddress(deployer, nonce + 4);
        bytes32 hookInitHash =
            keccak256(abi.encodePacked(type(StealthHook).creationCode, abi.encode(p.poolManager, a.feeVault)));
        (a.hookSalt, a.hook) = mineHookSalt(a.locker, hookInitHash);
    }

    /// @notice Deploys every contract from `deployer`, whose next five CREATE nonces must be used by nothing else.
    function deploy(Params memory p, address deployer) internal returns (System memory s) {
        Predicted memory a = predict(p, deployer);
        s.router = new StealthRouter(p.poolManager, IAllowanceTransfer(p.permit2));
        s.feeVault = new StealthFeeVault(
            p.poolManager, p.platform, p.marketing, a.hook, a.factory, p.creatorManager, p.distributor, p.reassignNotice
        );
        s.tokenDeployer = new StealthTokenDeployer(
            a.factory, a.locker, a.hook, a.feeVault, address(p.poolManager), address(s.feeVault.settlement())
        );
        s.locker = new StealthLocker(p.poolManager, IStealthFeeVault(a.feeVault), a.factory, a.hookSalt);
        s.factory = _deployFactory(p, a);
        s.hook = s.locker.hook();

        require(address(s.router) == a.router, "StealthDeploy: router address");
        require(address(s.feeVault) == a.feeVault, "StealthDeploy: fee vault address");
        require(address(s.tokenDeployer) == a.tokenDeployer, "StealthDeploy: token deployer address");
        require(address(s.locker) == a.locker, "StealthDeploy: locker address");
        require(address(s.factory) == a.factory, "StealthDeploy: factory address");
        require(address(s.hook) == a.hook, "StealthDeploy: hook address");
    }

    function _deployFactory(Params memory p, Predicted memory a) private returns (StealthFactory) {
        return new StealthFactory(
            p.admin, a.locker, a.feeVault, a.tokenDeployer, p.targetFloor, p.targetCeiling, p.config
        );
    }

    /// @notice Finds a salt that gives the hook exactly its permission bits when deployed by `locker`.
    function mineHookSalt(address locker, bytes32 initCodeHash) internal view returns (bytes32 salt, address hook) {
        for (uint256 i; i < MAX_SALT_ITERATIONS; ++i) {
            salt = bytes32(i);
            hook = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), locker, salt, initCodeHash)))));
            if (uint160(hook) & Dex.HOOK_ADDRESS_MASK == Dex.HOOK_ADDRESS_FLAGS && hook.code.length == 0) {
                return (salt, hook);
            }
        }
        revert("StealthDeploy: no hook salt found");
    }

    /// @notice Settings the tests and the mainnet deploy start from; unlisted ERC-20 quotes refused (the admin lists
    ///         each quote). Targets are passed in: they are per chain, in that chain's native coin.
    function config(uint256 minTarget, uint256 defaultTarget, uint256 maxTarget)
        internal
        pure
        returns (StealthFactory.Config memory)
    {
        return StealthFactory.Config({
            minTarget: uint128(minTarget),
            maxTarget: uint128(maxTarget),
            defaultTarget: uint128(defaultTarget),
            launchFee: 0,
            launchesPaused: false,
            unlistedQuotesAllowed: false
        });
    }
}
