// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Dex, Currency} from "@dex/Dex.sol";
import {StealthConstants as C} from "./libraries/StealthConstants.sol";

/// @title StealthTokenArgs
/// @notice Packs a launch's terms and metadata into a token's clone data (layout in StealthToken).
library StealthTokenArgs {
    /// @dev Strings are limited by the factory; their lengths fit in 2 bytes.
    function encode(StealthToken.Args calldata a) internal pure returns (bytes memory) {
        return bytes.concat(
            abi.encodePacked(a.maxWalletBps, a.limitsWindow, a.firstBuyLock, uint16(0), a.quote, a.deployer),
            abi.encodePacked(_field(a.name), _field(a.symbol), _field(a.logo), _field(a.description)),
            abi.encodePacked(_field(a.socials.twitter), _field(a.socials.telegram), _field(a.socials.discord)),
            abi.encodePacked(_field(a.socials.website), _field(a.socials.farcaster))
        );
    }

    function _field(string calldata s) private pure returns (bytes memory) {
        return abi.encodePacked(uint16(bytes(s).length), s);
    }
}

/// @title StealthToken
/// @notice The ERC-20 of one Stealth launch. Each token is a minimal-proxy clone of one implementation, with its name,
///         metadata and launch terms written into the clone's own bytecode: a launch writes no metadata to storage,
///         which is what makes a launch light enough for HyperEVM's small blocks. No storage slot, role or function
///         can change the implementation: the clone is EIP-1167, not upgradeable.
///         The locker mints the supply once, straight into the token's pool, in the launch transaction, so the token
///         trades on any route of its DEX from its first block. The pool pairs it with its `quote`: the native coin
///         (address 0) or an ERC-20, whose address is always below this token's.
///         No owner, no mint after launch, no pause, no blacklist and no transfer tax: the trading fee lives in the
///         pool. `deployer` is attribution only. Any holder may burn their own balance.
///         Launch safety, fixed at launch: an optional max wallet (0.5-5% of supply) for the first minutes (up to
///         60), which no wallet but the pool's settlement contract, the locker, the hook and the fee vault may
///         exceed; and an optional lock on the launcher's first-buy tokens until `unlockTime` (up to 90 days), which
///         no transfer, sale or burn can get around. (The max buy per transaction is enforced by the hook.)
/// @dev Clone data, after the 45 bytes of proxy code: 2 bytes max wallet bps, 4 limits window, 4 first-buy lock, 2
///      unused, 20 quote, 20 deployer, then nine strings, each as a 2-byte length and its bytes: name, symbol, logo,
///      description, twitter, telegram, discord, website, farcaster. The clone's address must not depend on the
///      launch time, so times live in storage, and only for tokens that use them.
contract StealthToken is ERC20, ERC20Burnable {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct Args {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address deployer; // the wallet that launched it
        address quote; // the pool's other currency: address(0) for the native coin, else an ERC-20 below this address
        uint16 maxWalletBps; // 0 = no max wallet
        uint32 limitsWindow; // seconds after launch the max wallet applies
        uint32 firstBuyLock; // seconds after launch the first-buy tokens stay locked; 0 = no lock
    }

    /// @dev Set only for a token with a max wallet or a first-buy lock. Packed with the locked account.
    struct Terms {
        address lockedAccount;
        uint40 limitsEnd;
        uint40 unlockTime;
    }

    error ZeroAddress();
    error NotLocker();
    error AlreadyMinted();
    error LockAlreadySet();
    error MaxWalletExceeded();
    error FirstBuyLocked();

    event FirstBuyLockSet(address indexed account, uint256 amount, uint256 unlockTime);

    /// @dev Offset of the first string in the clone data.
    uint256 private constant STRINGS_OFFSET = 52;
    uint256 private constant FIELD_SOCIALS = 4;

    /// @notice The StealthFactory that launches tokens.
    address public immutable launchFactory;
    /// @notice The StealthLocker that owns every token's pool liquidity forever.
    address public immutable locker;
    /// @notice The StealthHook on every token's pool.
    address public immutable hook;
    /// @notice The StealthFeeVault (holds a token only inside a buyback, and burns it there).
    address public immutable feeVault;
    /// @notice The DEX's pool manager.
    address public immutable poolManager;
    /// @notice The DEX contract that holds the pool's tokens, exempt from the max wallet.
    address public immutable settlement;

    Terms private _terms;
    /// @notice How many first-buy tokens are locked.
    uint256 public lockedAmount;

    /// @dev Runs once, for the implementation. The six addresses are the same for every clone.
    constructor(
        address launchFactory_,
        address locker_,
        address hook_,
        address feeVault_,
        address poolManager_,
        address settlement_
    ) ERC20("", "") {
        if (
            launchFactory_ == address(0) || locker_ == address(0) || hook_ == address(0) || feeVault_ == address(0)
                || poolManager_ == address(0) || settlement_ == address(0)
        ) revert ZeroAddress();
        launchFactory = launchFactory_;
        locker = locker_;
        hook = hook_;
        feeVault = feeVault_;
        poolManager = poolManager_;
        settlement = settlement_;
    }

    /// @notice Mints the supply to the pool's settlement contract and starts the token's time limits.
    /// @dev Locker only, once, in the launch transaction, for exactly what the pool's positions took.
    function mintSupply(address to, uint256 amount) external {
        if (msg.sender != locker) revert NotLocker();
        if (totalSupply() != 0) revert AlreadyMinted();
        uint256 w = _head();
        if (w >> 160 != 0) {
            uint32 limitsWindow = uint32(w >> 208);
            uint32 firstBuyLock = uint32(w >> 176);
            _terms = Terms({
                lockedAccount: address(0),
                limitsEnd: limitsWindow == 0 ? 0 : uint40(block.timestamp) + limitsWindow,
                unlockTime: firstBuyLock == 0 ? 0 : uint40(block.timestamp) + firstBuyLock
            });
        }
        _mint(to, amount);
    }

    /// @notice Locks `amount` of `account`'s tokens (the launcher's first buy) until `unlockTime`.
    /// @dev Locker only, once, in the launch transaction.
    function setFirstBuyLock(address account, uint256 amount) external {
        if (msg.sender != locker) revert NotLocker();
        if (_terms.lockedAccount != address(0)) revert LockAlreadySet();
        _terms.lockedAccount = account;
        lockedAmount = amount;
        emit FirstBuyLockSet(account, amount, _terms.unlockTime);
    }

    // ---------------------------------------------------------------------
    // ERC-20
    // ---------------------------------------------------------------------

    /// @dev Every balance change goes through here (transfers, transferFrom, burns). A token with no limits and no
    ///      lock pays one read of its own code and touches no extra storage.
    function _update(address from, address to, uint256 value) internal override {
        if (_head() >> 160 == 0) {
            super._update(from, to, value);
            return;
        }
        Terms memory t = _terms;
        if (from != address(0) && from == t.lockedAccount && block.timestamp < t.unlockTime) {
            if (balanceOf(from) < value + lockedAmount) revert FirstBuyLocked();
        }
        super._update(from, to, value);
        if (
            block.timestamp < t.limitsEnd && to != address(0) && to != settlement && to != locker && to != hook
                && to != feeVault && balanceOf(to) > maxWallet()
        ) revert MaxWalletExceeded();
    }

    function name() public view override returns (string memory) {
        return _string(0);
    }

    function symbol() public view override returns (string memory) {
        return _string(1);
    }

    // ---------------------------------------------------------------------
    // Launch terms and metadata
    // ---------------------------------------------------------------------

    /// @notice The currency the token is paired with: address(0) for the native coin, else an ERC-20.
    function quote() public view returns (address) {
        return address(uint160(_head()));
    }

    /// @notice The wallet that launched the token. Attribution only.
    function deployer() public view returns (address) {
        address a;
        assembly ("memory-safe") {
            extcodecopy(address(), 0x0c, 0x4d, 0x14) // the 20 bytes at offset 32 of the data, right-aligned at 0x00
            a := shr(96, shl(96, mload(0x00)))
        }
        return a;
    }

    /// @notice The token's pool id (quote / token, LP fee 0, tick spacing 10, the Stealth hook).
    function poolId() external view returns (bytes32) {
        return Dex.id(Dex.key(Currency.wrap(quote()), address(this), hook, poolManager, C.POOL_FEE, C.TICK_SPACING));
    }

    /// @notice Most tokens one wallet may hold until `limitsEnd` (0 = no limit).
    function maxWallet() public view returns (uint256) {
        return C.TOTAL_SUPPLY * uint16(_head() >> 240) / C.BPS;
    }

    /// @notice When the max wallet stops applying (0 if there is none).
    function limitsEnd() external view returns (uint256) {
        return uint16(_head() >> 240) == 0 ? 0 : _terms.limitsEnd;
    }

    /// @notice When the launcher's first-buy tokens unlock (0 if there is no lock).
    function unlockTime() external view returns (uint256) {
        return _terms.unlockTime;
    }

    /// @notice The wallet whose first-buy tokens are locked.
    function lockedAccount() external view returns (address) {
        return _terms.lockedAccount;
    }

    /// @notice Tokens of `account` that cannot move yet.
    function lockedBalanceOf(address account) external view returns (uint256) {
        return account == _terms.lockedAccount && block.timestamp < _terms.unlockTime ? lockedAmount : 0;
    }

    function logo() public view returns (string memory) {
        return _string(2);
    }

    function description() public view returns (string memory) {
        return _string(3);
    }

    /// @notice The token's social links.
    function socials()
        public
        view
        returns (
            string memory twitter,
            string memory telegram,
            string memory discord,
            string memory website,
            string memory farcaster
        )
    {
        return (
            _string(FIELD_SOCIALS),
            _string(FIELD_SOCIALS + 1),
            _string(FIELD_SOCIALS + 2),
            _string(FIELD_SOCIALS + 3),
            _string(FIELD_SOCIALS + 4)
        );
    }

    /// @notice Creator and metadata in the launcher-compatible tuple.
    function getTokenInfo()
        external
        view
        returns (
            address tokenDeployer,
            string memory tokenLogo,
            string memory tokenDescription,
            Socials memory tokenSocials
        )
    {
        (string memory tw, string memory tg, string memory dc, string memory web, string memory fc) = socials();
        return (deployer(), logo(), description(), Socials(tw, tg, dc, web, fc));
    }

    /// @notice Which launchpad created this token.
    function launchpad() external pure returns (string memory) {
        return C.LAUNCHPAD_NAME;
    }

    // ---------------------------------------------------------------------
    // Clone data
    // ---------------------------------------------------------------------

    /// @dev The first 32 bytes of the clone data: limits and lock terms in the top 12 bytes, the quote below.
    function _head() private view returns (uint256 w) {
        assembly ("memory-safe") {
            extcodecopy(address(), 0x00, 0x2d, 0x20)
            w := mload(0x00)
        }
    }

    /// @dev The `index`th string of the clone data.
    function _string(uint256 index) private view returns (string memory) {
        bytes memory data = Clones.fetchCloneArgs(address(this));
        uint256 at = STRINGS_OFFSET;
        for (uint256 i; i < index; ++i) {
            at += 2 + _length(data, at);
        }
        uint256 length = _length(data, at);
        bytes memory out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = data[at + 2 + i];
        }
        return string(out);
    }

    function _length(bytes memory data, uint256 at) private pure returns (uint256) {
        return (uint256(uint8(data[at])) << 8) | uint8(data[at + 1]);
    }
}
