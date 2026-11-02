// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DexBase, DexCallback, IDexManager} from "@dex/Dex.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PoolGeometry} from "../../src/libraries/PoolGeometry.sol";
import {StealthFeeVault} from "../../src/StealthFeeVault.sol";
import {StealthFactory} from "../../src/StealthFactory.sol";

/// @notice Exposes library functions so tests can check their reverts.
contract MathHarness {
    function virtualReserves(uint256 target, uint256 curveSupply, uint256 poolSupply)
        external
        pure
        returns (uint256, uint256)
    {
        return CurveMath.virtualReserves(target, curveSupply, poolSupply);
    }

    function sqrtPriceX96(uint256 e, uint256 t) external pure returns (uint160) {
        return CurveMath.sqrtPriceX96(e, t);
    }

    function geometry(uint256 target) external pure returns (PoolGeometry.Geometry memory) {
        return PoolGeometry.compute(target);
    }
}

/// @notice Sends ETH by self-destructing, bypassing any receive/fallback.
contract ForceSend {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @notice A creator contract that can't receive ETH: its refund fails.
contract RejectingCreator {
    function launch(StealthFactory f, StealthFactory.LaunchParams memory p, uint256 value) external returns (address) {
        return f.launch{value: value}(p);
    }
}

/// @notice Becomes a token's creator and tries to re-enter the vault when it is paid.
contract ReentrantClaimer {
    StealthFeeVault public immutable vault;
    address public token;

    constructor(StealthFeeVault vault_) {
        vault = vault_;
    }

    function setToken(address token_) external {
        token = token_;
    }

    function accept() external {
        vault.acceptCreator(token);
    }

    function claim() external returns (uint256) {
        return vault.claimCreator(token);
    }

    receive() external payable {
        vault.claimCreator(token);
    }
}

/// @notice Launches from inside its own settlement lock, like a flash-accounting router would.
contract UnlockedCaller is DexCallback {
    StealthFactory public immutable factory;
    StealthFactory.LaunchParams internal _params;
    address public lastToken;

    constructor(IDexManager manager_, StealthFactory factory_) DexBase(manager_) {
        factory = factory_;
    }

    function launch(StealthFactory.LaunchParams calldata p) external payable returns (address) {
        _params = p;
        _lockRaw(abi.encode(msg.value));
        return lastToken;
    }

    function _onLock(bytes calldata data) internal override returns (bytes memory) {
        lastToken = factory.launch{value: abi.decode(data, (uint256))}(_params);
        return "";
    }

    receive() external payable {}
}
