// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Dex, DexBase, DexCallback, IDexManager, PoolKey, BalanceDelta, Currency} from "@dex/Dex.sol";

/// @notice The Permit2 of the DEX: Uniswap's canonical one, or PancakeSwap's own on BNB Chain.
interface IAllowanceTransfer {
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

/// @title StealthRouter
/// @notice The thin router the Stealth site trades through. One single-pool swap per call (exact input or exact
///         output, either direction), paid in the native coin (msg.value; unused value is returned) or an ERC-20 pulled
///         from the caller with a plain approval to this router or through Permit2. Prices are the pool's own: a trade
///         costs the same through any router.
/// @dev Holds nothing between calls. No admin, no upgrade path.
contract StealthRouter is DexCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    struct Swap {
        PoolKey key;
        bool zeroForOne;
        bool exactInput;
        uint128 amount; // exact input, or exact output
        uint128 limit; // minimum output (exact input) or maximum input (exact output)
        address recipient; // receives the output
        bool usePermit2; // ERC-20 input: pull through Permit2 instead of a plain approval
        uint256 deadline;
    }

    IAllowanceTransfer public immutable permit2;

    event Swapped(address indexed trader, bytes32 indexed poolId, bool zeroForOne, uint256 amountIn, uint256 amountOut);

    error Expired();
    error ZeroAmount();
    error TooLittleReceived();
    error TooMuchRequested();
    error RefundFailed();

    constructor(IDexManager poolManager_, IAllowanceTransfer permit2_) DexBase(poolManager_) {
        permit2 = permit2_;
    }

    /// @notice Runs one swap for the caller. Returns what it paid and what the recipient got.
    function swap(Swap calldata s) external payable nonReentrant returns (uint256 amountIn, uint256 amountOut) {
        if (block.timestamp > s.deadline) revert Expired();
        if (s.amount == 0) revert ZeroAmount();
        (amountIn, amountOut) = abi.decode(_lockRaw(abi.encode(msg.sender, s)), (uint256, uint256));
        uint256 left = address(this).balance;
        if (left != 0) {
            (bool ok,) = msg.sender.call{value: left}("");
            if (!ok) revert RefundFailed();
        }
        emit Swapped(msg.sender, Dex.id(s.key), s.zeroForOne, amountIn, amountOut);
    }

    function _onLock(bytes calldata data) internal override returns (bytes memory) {
        (address trader, Swap memory s) = abi.decode(data, (address, Swap));
        int256 specified = s.exactInput ? -int256(uint256(s.amount)) : int256(uint256(s.amount));
        BalanceDelta d = poolManager.swap(
            s.key,
            IDexManager.SwapParams({
                zeroForOne: s.zeroForOne,
                amountSpecified: specified,
                sqrtPriceLimitX96: s.zeroForOne ? Dex.MIN_SQRT_PRICE + 1 : Dex.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 inDelta, int128 outDelta) = s.zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        uint256 amountIn = uint256(uint128(-inDelta));
        uint256 amountOut = uint256(uint128(outDelta));
        if (s.exactInput ? amountOut < s.limit : amountIn > s.limit) {
            if (s.exactInput) revert TooLittleReceived();
            revert TooMuchRequested();
        }
        (Currency cIn, Currency cOut) =
            s.zeroForOne ? (s.key.currency0, s.key.currency1) : (s.key.currency1, s.key.currency0);
        _pay(cIn, trader, amountIn, s.usePermit2);
        if (amountOut != 0) _take(cOut, s.recipient, amountOut);
        return abi.encode(amountIn, amountOut);
    }

    function _pay(Currency currency, address payer, uint256 amount, bool usePermit2) internal {
        if (amount == 0) return;
        _sync(currency);
        if (Dex.isNative(currency)) {
            _settleNative(amount);
            return;
        }
        address token = Currency.unwrap(currency);
        if (usePermit2) permit2.transferFrom(payer, address(settlement), amount.toUint160(), token);
        else IERC20(token).safeTransferFrom(payer, address(settlement), amount);
        _settle();
    }
}
