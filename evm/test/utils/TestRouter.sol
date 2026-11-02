// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Dex, DexBase, DexCallback, IDexManager, PoolKey, BalanceDelta, Currency} from "@dex/Dex.sol";

/// @notice Minimal test router (in the role of v4's PoolSwapTest / PoolDonateTest / PoolModifyLiquidityTest): runs one
///         swap, donation or liquidity change inside a settlement lock, pays what the caller owes (native from
///         msg.value, ERC-20 by transferFrom from the caller, so approve this router), sends the caller what it is
///         owed, and refunds unused native.
contract TestRouter is DexCallback {
    using SafeERC20 for IERC20;

    struct TestSettings {
        bool takeClaims; // receive outputs as ERC-6909 claims instead of the currency
        bool settleUsingBurn; // pay inputs by burning the caller's ERC-6909 claims (the caller must approve this router)
    }

    enum Kind {
        Swap,
        Donate,
        Modify
    }

    struct Data {
        Kind kind;
        address sender;
        PoolKey key;
        bytes params;
        TestSettings settings;
        bytes hookData;
    }

    constructor(IDexManager manager_) DexBase(manager_) {}

    function manager() external view returns (IDexManager) {
        return poolManager;
    }

    function swap(
        PoolKey memory key,
        IDexManager.SwapParams memory params,
        TestSettings memory settings,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta) {
        delta = _lock(Data(Kind.Swap, msg.sender, key, abi.encode(params), settings, hookData));
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        delta = _lock(Data(Kind.Donate, msg.sender, key, abi.encode(amount0, amount1), TestSettings(false, false), hookData));
    }

    function modifyLiquidity(PoolKey memory key, IDexManager.ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        delta = _lock(Data(Kind.Modify, msg.sender, key, abi.encode(params), TestSettings(false, false), hookData));
    }

    function _onLock(bytes calldata raw) internal override returns (bytes memory) {
        Data memory d = abi.decode(raw, (Data));
        BalanceDelta delta;
        if (d.kind == Kind.Swap) {
            delta = poolManager.swap(d.key, abi.decode(d.params, (IDexManager.SwapParams)), d.hookData);
        } else if (d.kind == Kind.Donate) {
            (uint256 a0, uint256 a1) = abi.decode(d.params, (uint256, uint256));
            delta = poolManager.donate(d.key, a0, a1, d.hookData);
        } else {
            (delta,) = poolManager.modifyLiquidity(
                d.key, abi.decode(d.params, (IDexManager.ModifyLiquidityParams)), d.hookData
            );
        }
        _resolve(d.key.currency0, delta.amount0(), d.sender, d.settings);
        _resolve(d.key.currency1, delta.amount1(), d.sender, d.settings);
        return abi.encode(delta);
    }

    function _lock(Data memory d) internal returns (BalanceDelta delta) {
        delta = abi.decode(_lockRaw(abi.encode(d)), (BalanceDelta));
        uint256 left = address(this).balance;
        if (left != 0) {
            (bool ok,) = d.sender.call{value: left}("");
            require(ok, "refund failed");
        }
    }

    function _resolve(Currency currency, int128 amount, address sender, TestSettings memory s) internal {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (s.settleUsingBurn) {
                _burnClaim(sender, currency, owed);
            } else if (Dex.isNative(currency)) {
                _sync(currency);
                _settleNative(owed);
            } else {
                _sync(currency);
                IERC20(Currency.unwrap(currency)).safeTransferFrom(sender, address(settlement), owed);
                _settle();
            }
        } else if (amount > 0) {
            if (s.takeClaims) _mintClaim(sender, currency, uint256(uint128(amount)));
            else _take(currency, sender, uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}
