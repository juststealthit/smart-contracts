// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain ERC-20 with chosen decimals and an open mint (test quote currency; also deployed on testnet).
contract MockERC20 is ERC20 {
    uint8 internal immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Takes `feeBps` of every transfer (burned), like reflection / tax tokens.
contract FeeOnTransferERC20 is MockERC20 {
    uint256 public immutable feeBps;

    constructor(uint8 decimals_, uint256 feeBps_) MockERC20("Fee Token", "FOT", decimals_) {
        feeBps = feeBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) return super._update(from, to, value);
        uint256 fee = value * feeBps / 10_000;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

/// @notice Charges the sender `fee` on top of each transfer (the receiver gets the full amount).
contract FeeOnTopERC20 is MockERC20 {
    uint256 public immutable fee;

    constructor(uint8 decimals_, uint256 fee_) MockERC20("Fee On Top", "FOTOP", decimals_) {
        fee = fee_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0)) super._update(from, address(0), fee);
    }
}

/// @notice Balances scale with a share price the test can move (a rebasing token). Transfers move exact amounts,
///         so a launch's transfer check cannot see it; listing is the admin's vetting.
contract RebasingERC20 is MockERC20 {
    uint256 public multiplierBps = 10_000;

    constructor() MockERC20("Rebase", "RB", 18) {}

    function rebase(uint256 bps) external {
        multiplierBps = bps;
    }

    function balanceOf(address a) public view override returns (uint256) {
        return super.balanceOf(a) * multiplierBps / 10_000;
    }
}

/// @notice An ERC-20 with no `decimals()`.
contract NoDecimalsToken {
    mapping(address => uint256) public balanceOf;

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }
}
