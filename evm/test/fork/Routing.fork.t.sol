// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IDexManager} from "@dex/Dex.sol";
import {DexFork} from "@dex/DexFork.sol";
import {RoutingBase} from "../utils/RoutingBase.sol";
import {MockERC20} from "../utils/MockTokens.sol";

/// @notice The routing suite on live DEX state: the v4 build on Robinhood Chain and HyperEVM, the Infinity build on BNB
///         Chain, native pairs and ERC-20 pairs. Public RPCs from foundry.toml only. Read-only forks: the system is
///         deployed into the local fork and nothing is broadcast. Needs STEALTH_FORK=true; skips cleanly without it, and
///         if the chain's RPC cannot be reached.
abstract contract RoutingForkBase is RoutingBase {
    DexFork.Chain internal live;

    /// @dev Which of the build's chains (see variants/*/DexFork.sol).
    function _chainIndex() internal pure virtual returns (uint256);

    function setUp() public virtual override {
        if (!vm.envOr("STEALTH_FORK", false) || _chainIndex() >= DexFork.CHAINS) {
            vm.skip(true);
            return;
        }
        live = DexFork.chain(_chainIndex());
        // Fork a few blocks behind the head (public RPCs keep only recent state) unless STEALTH_FORK_BLOCK pins one.
        uint256 pinned = vm.envOr("STEALTH_FORK_BLOCK", uint256(0));
        if (!_fork(live.rpc, pinned)) {
            console2.log("skipping: cannot reach", live.rpc);
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, live.chainId, "wrong chain");
        super.setUp();
    }

    function _fork(string memory rpc, uint256 pinned) internal returns (bool) {
        if (pinned != 0) {
            try vm.createSelectFork(rpc, pinned) returns (uint256) {
                return true;
            } catch {
                return false;
            }
        }
        try vm.createSelectFork(rpc) returns (uint256) {
            try vm.rollFork(block.number - 20) {
                return true;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    /// @dev A deterministic test address can collide with a contract on a live chain, so salt every actor.
    function _actorSalt() internal pure override returns (string memory) {
        return "@stealth-fork";
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

    function test_fork_liveAddresses() public view {
        assertEq(DexFork.wiring(live), "", "live wiring");
    }
}

/// @notice Robinhood Chain on the v4 build, BNB Chain on the Infinity build.
abstract contract PrimaryChain is RoutingForkBase {
    function _chainIndex() internal pure override returns (uint256) {
        return 0;
    }
}

/// @notice HyperEVM on the v4 build. The Infinity build has one chain, so this skips there.
abstract contract SecondaryChain is RoutingForkBase {
    function _chainIndex() internal pure override returns (uint256) {
        return 1;
    }
}

contract RoutingForkPrimaryNative is PrimaryChain {}

contract RoutingForkPrimaryErc20Six is PrimaryChain {
    function _makeQuote() internal override returns (address) {
        return address(new MockERC20("Mock USD6", "mUSD6", 6));
    }
}

/// @notice A real ERC-20 as the quote, where the build lists one (BSC USDT on Infinity); skips otherwise.
contract RoutingForkPrimaryRealQuote is PrimaryChain {
    function setUp() public override {
        if (DexFork.chain(0).realQuote == address(0)) {
            vm.skip(true);
            return;
        }
        super.setUp();
    }

    function _makeQuote() internal view override returns (address) {
        return live.realQuote;
    }
}

contract RoutingForkSecondaryNative is SecondaryChain {}

contract RoutingForkSecondaryErc20Six is SecondaryChain {
    function _makeQuote() internal override returns (address) {
        return address(new MockERC20("Mock USD6", "mUSD6", 6));
    }
}
