// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {StealthToken, StealthTokenArgs} from "./StealthToken.sol";
import {StealthConstants as C} from "./libraries/StealthConstants.sol";

/// @title StealthTokenDeployer
/// @notice Holds the one StealthToken implementation and deploys a minimal-proxy clone of it per launch, with CREATE2,
///         with the token's metadata and terms in the clone's bytecode.
/// @dev Callable by the factory only. The factory derives a base salt from the launcher and a per-launcher nonce.
///      Every token's address must be above its quote's (the quote is the pool's currency0, the token currency1),
///      so the deployer tries salts keccak(baseSalt, i) for i = 0, 1, ... and takes the first address above the
///      quote. For the native coin (address 0) that is always i = 0. For an ERC-20 at address q it takes about
///      2^160 / (2^160 - q) tries on average; quotes so high that `MAX_SALT_TRIES` is not enough are refused.
contract StealthTokenDeployer {
    address public immutable factory;
    /// @notice The code every token runs.
    StealthToken public immutable implementation;

    error NotFactory();
    error ZeroAddress();
    error QuoteAddressTooHigh();

    constructor(
        address factory_,
        address locker_,
        address hook_,
        address feeVault_,
        address poolManager_,
        address settlement_
    ) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        implementation = new StealthToken(factory_, locker_, hook_, feeVault_, poolManager_, settlement_);
    }

    /// @notice Deploys a token. Factory only.
    function deploy(bytes32 baseSalt, StealthToken.Args calldata args) external returns (address token) {
        if (msg.sender != factory) revert NotFactory();
        bytes memory code = _initCode(args);
        (bytes32 salt,) = _find(baseSalt, keccak256(code), args.quote);
        return Create2.deploy(0, salt, code);
    }

    /// @notice The address `deploy` would produce for these inputs.
    function predict(bytes32 baseSalt, StealthToken.Args calldata args) external view returns (address token) {
        (, token) = _find(baseSalt, keccak256(_initCode(args)), args.quote);
    }

    /// @dev EIP-1167 with immutable args, byte for byte the initcode of OpenZeppelin's `Clones`, kept here because the
    ///      salt search needs its hash once and `Clones` hashes it again per try.
    function _initCode(StealthToken.Args calldata args) internal view returns (bytes memory) {
        bytes memory data = StealthTokenArgs.encode(args);
        return abi.encodePacked(
            hex"61",
            uint16(data.length + 0x2d),
            hex"3d81600a3d39f3363d3d373d3d3d363d73",
            address(implementation),
            hex"5af43d82803e903d91602b57fd5bf3",
            data
        );
    }

    /// @dev First salt whose CREATE2 address is above the quote and still free.
    function _find(bytes32 baseSalt, bytes32 initCodeHash, address quote)
        internal
        view
        returns (bytes32 salt, address token)
    {
        for (uint256 i; i < C.MAX_SALT_TRIES; ++i) {
            salt = keccak256(abi.encode(baseSalt, i));
            token = Create2.computeAddress(salt, initCodeHash);
            if (token > quote && token.code.length == 0) return (salt, token);
        }
        revert QuoteAddressTooHigh();
    }
}
