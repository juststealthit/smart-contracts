// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Currency} from "@dex/Dex.sol";
import {StealthConstants as C} from "./libraries/StealthConstants.sol";
import {StealthToken} from "./StealthToken.sol";
import {StealthTokenDeployer} from "./StealthTokenDeployer.sol";
import {StealthLocker} from "./StealthLocker.sol";
import {IStealthFeeVault, LaunchType, TeamShare} from "./interfaces/IStealth.sol";

/// @title StealthFactory
/// @notice Launches Stealth tokens and holds the configuration that applies to future launches only.
///         A launch deploys the token with its metadata on-chain, opens its pool with the whole supply locked in it,
///         and runs the launcher's optional first buy, all in one transaction.
///         A token is paired with the native coin (the default, `quote = address(0)`) or with an ERC-20 quote: a token
///         the admin has listed (with its own graduation-target range), or, if the admin allows it, any other ERC-20
///         within generic bounds set by its decimals.
/// @dev The admin can change future-launch settings within hard caps compiled into bytecode, and within the native
///      target floor and ceiling fixed at deploy. It has no power over any live token. The tax tiers and the sniper
///      fee are constants: not even the admin can move them.
contract StealthFactory is ReentrancyGuardTransient {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    struct Config {
        uint128 minTarget; // native targets (wei)
        uint128 maxTarget;
        uint128 defaultTarget; // shown by the launch wizard
        uint96 launchFee; // always in the native coin, whatever the quote
        bool launchesPaused;
        bool unlistedQuotesAllowed; // ERC-20 quotes the admin has not listed, within the generic bounds
    }

    /// @notice An ERC-20 the admin has listed as a quote, with its graduation-target range in raw units.
    struct QuoteConfig {
        bool listed;
        uint8 decimals;
        uint128 minTarget;
        uint128 defaultTarget;
        uint128 maxTarget;
    }

    /// @notice Terms the launcher fixes for good at launch. All zero = Creator type, no limits, no lock.
    struct LaunchOptions {
        LaunchType launchType;
        TeamShare[] team; // Team type only: 2-10 wallets whose bps sum to 10,000; empty otherwise
        uint16 maxWalletBps; // 0 or 50-500 (0.5%-5% of supply)
        uint16 maxBuyBps; // 0 or 10-500 (0.1%-5% of supply), per transaction
        uint32 limitsWindow; // seconds the max wallet and max buy apply (1-3600 if either is set)
        uint32 firstBuyLock; // seconds the launcher's first-buy tokens stay locked (0-90 days)
    }

    struct LaunchParams {
        string name;
        string symbol;
        string logo; // image URL (https or ipfs)
        string description;
        StealthToken.Socials socials;
        uint16 taxBps; // one of the five tiers; 0 = the default tier (1.25%)
        address quote; // the currency to pair with: address(0) = the native coin, else an ERC-20
        uint256 target; // graduation target in raw units of the quote, within the quote's range
        uint256 quoteAmount; // ERC-20 quote only: the first buy, pulled from the caller (native: msg.value - launch fee)
        uint256 minTokensOut; // slippage limit on the first buy
        uint64 configVersion; // the `configVersion` the caller saw; the launch reverts if the config changed since
        address creator; // the coin's creator (paid under the Creator type); address(0) = the caller
        LaunchOptions options;
    }

    StealthLocker public immutable locker;
    IStealthFeeVault public immutable feeVault;
    StealthTokenDeployer public immutable tokenDeployer;
    address internal immutable _hook;
    address internal immutable _poolManager;
    address internal immutable _settlement;
    /// @notice Lowest native graduation target this deployment can ever allow.
    uint256 public immutable targetFloor;
    /// @notice Highest native graduation target this deployment can ever allow.
    uint256 public immutable targetCeiling;

    Config internal _config;
    mapping(address quote => QuoteConfig) internal _quotes;
    /// @notice Bumped by every config change. A launch must name the version it was prepared against, so the admin
    ///         can never change a launch's terms between signing and execution.
    uint64 public configVersion;
    address public admin;
    address public pendingAdmin;
    /// @notice Per-launcher counter that makes each launch's CREATE2 base salt unique.
    mapping(address launcher => uint256) public launchNonce;

    /// @param creator The coin's creator.
    /// @param launcher The wallet that sent the launch (paid for it and received any first-buy tokens).
    event Launched(
        address indexed token,
        address indexed creator,
        bytes32 indexed poolId,
        address launcher,
        address quote,
        string name,
        string symbol,
        uint16 taxBps,
        LaunchType launchType,
        uint256 target
    );
    event ConfigChanged(bytes32 indexed key, uint256 oldValue, uint256 newValue);
    event QuoteListed(
        address indexed quote, uint8 decimals, uint256 minTarget, uint256 defaultTarget, uint256 maxTarget
    );
    event QuoteDelisted(address indexed quote);
    event AdminProposed(address indexed current, address indexed proposed);
    event AdminChanged(address indexed previous, address indexed current);

    error ZeroAddress();
    error NotAdmin();
    error NotPendingAdmin();
    error WiringMismatch();
    error InvalidBounds();
    error OutOfRange();
    error LaunchesPaused();
    error InvalidName();
    error InvalidSymbol();
    error InvalidMetadata();
    error InvalidTax();
    error InvalidTarget();
    error InsufficientLaunchFee();
    error InvalidValue();
    error StaleConfig();
    error InvalidCreator();
    error InvalidQuote();
    error QuoteNotListed();
    error UnsupportedQuote();
    error InvalidOptions();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @dev For config setters: admin only, and bumps `configVersion`.
    modifier configChange() {
        if (msg.sender != admin) revert NotAdmin();
        ++configVersion;
        _;
    }

    /// @param admin_ Factory admin.
    /// @param locker_ StealthLocker.
    /// @param feeVault_ StealthFeeVault.
    /// @param tokenDeployer_ StealthTokenDeployer.
    /// @param targetFloor_ Lowest native target this deployment will ever allow. Immutable.
    /// @param targetCeiling_ Highest native target this deployment will ever allow. Immutable.
    /// @param config_ Initial future-launch configuration.
    constructor(
        address admin_,
        address locker_,
        address feeVault_,
        address tokenDeployer_,
        uint256 targetFloor_,
        uint256 targetCeiling_,
        Config memory config_
    ) {
        if (admin_ == address(0) || locker_ == address(0) || feeVault_ == address(0) || tokenDeployer_ == address(0))
        {
            revert ZeroAddress();
        }
        if (targetFloor_ < C.MIN_TARGET_FLOOR || targetCeiling_ > C.MAX_TARGET_CEILING || targetFloor_ > targetCeiling_)
        {
            revert InvalidBounds();
        }
        locker = StealthLocker(payable(locker_));
        feeVault = IStealthFeeVault(feeVault_);
        tokenDeployer = StealthTokenDeployer(tokenDeployer_);
        targetFloor = targetFloor_;
        targetCeiling = targetCeiling_;
        _hook = address(StealthLocker(payable(locker_)).hook());
        _poolManager = address(StealthLocker(payable(locker_)).poolManager());
        _settlement = address(StealthLocker(payable(locker_)).settlement());

        if (
            StealthLocker(payable(locker_)).factory() != address(this)
                || IStealthFeeVault(feeVault_).factory() != address(this) || IStealthFeeVault(feeVault_).hook() != _hook
                || StealthTokenDeployer(tokenDeployer_).factory() != address(this)
        ) revert WiringMismatch();

        _checkTargets(config_.minTarget, config_.defaultTarget, config_.maxTarget, targetFloor_, targetCeiling_);
        if (config_.launchFee > C.MAX_LAUNCH_FEE) revert OutOfRange();
        _config = config_;
        configVersion = 1;

        admin = admin_;
        emit AdminChanged(address(0), admin_);
    }

    // ---------------------------------------------------------------------
    // Launch
    // ---------------------------------------------------------------------

    /// @notice Launches a token. `msg.value` covers the launch fee (native, always) plus, for a native pair, an
    ///         optional first buy. For an ERC-20 pair the caller approves this factory for `quoteAmount` (the first
    ///         buy) or, if larger, `quoteProbeAmount(quote)`: the launch pulls that much, checks it moved exactly
    ///         (fee-on-transfer and similar tokens are refused), and returns whatever the first buy did not use.
    /// @dev Callable by anyone. The first buy pays the token's tier (not the sniper fee), is capped at 5% of supply,
    ///      and any quote beyond what it uses is refunded to the caller. The caller receives the first-buy tokens.
    ///      Nothing about the token can change after launch, except the creator through the vault's hand-off or
    ///      takeover.
    function launch(LaunchParams calldata p) external payable nonReentrant returns (address token) {
        Config memory cfg = _config;
        (uint8 decimals, uint16 taxBps) = _validateLaunch(p, cfg);

        bytes32 salt = keccak256(abi.encode(msg.sender, launchNonce[msg.sender]++));
        token = tokenDeployer.deploy(salt, _tokenArgs(p, msg.sender));
        address creator = p.creator == address(0) ? msg.sender : p.creator;
        _checkRecipient(creator);
        feeVault.registerToken(token, creator, Currency.wrap(p.quote), p.options.launchType, p.options.team, taxBps);
        if (cfg.launchFee != 0) feeVault.creditLaunchFee{value: cfg.launchFee}(token);

        _openPool(token, p, taxBps, cfg, decimals);
        _emitLaunched(token, creator, taxBps, p);
    }

    /// @notice The address `launcher`'s next launch with these parameters will deploy to.
    function predictTokenAddress(address launcher, LaunchParams calldata p) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(launcher, launchNonce[launcher]));
        return tokenDeployer.predict(salt, _tokenArgs(p, launcher));
    }

    function config() external view returns (Config memory) {
        return _config;
    }

    /// @notice The admin's listing for an ERC-20 quote (`listed` false if none).
    function quoteConfig(address quote) external view returns (QuoteConfig memory) {
        return _quotes[quote];
    }

    /// @notice Graduation-target bounds, in raw units, for an ERC-20 quote with `decimals` decimals: 0.01 to 10^12
    ///         whole units. Listed quotes' ranges must sit inside them; unlisted quotes use them directly.
    function quoteTargetBounds(uint8 decimals) public pure returns (uint256 minTarget, uint256 maxTarget) {
        if (decimals < C.MIN_QUOTE_DECIMALS || decimals > C.MAX_QUOTE_DECIMALS) revert UnsupportedQuote();
        minTarget = 10 ** (decimals - C.QUOTE_TARGET_MIN_EXP);
        maxTarget = 10 ** (decimals + C.QUOTE_TARGET_MAX_EXP);
    }

    /// @notice How much of an ERC-20 quote a launch pulls at least (and returns, minus any first buy), to check
    ///         the token moves exactly: 10^(decimals - 4) raw units, at least 10,000.
    function quoteProbeAmount(address quote) external view returns (uint256) {
        return _probeAmount(_decimals(quote));
    }

    // ---------------------------------------------------------------------
    // Admin: future launches only
    // ---------------------------------------------------------------------

    /// @notice Sets the native graduation target range for future launches. Admin only; within the deploy-time bounds.
    function setTargetRange(uint256 minTarget, uint256 defaultTarget, uint256 maxTarget) external configChange {
        _checkTargets(minTarget, defaultTarget, maxTarget, targetFloor, targetCeiling);
        Config storage cfg = _config;
        emit ConfigChanged("minTarget", cfg.minTarget, minTarget);
        emit ConfigChanged("defaultTarget", cfg.defaultTarget, defaultTarget);
        emit ConfigChanged("maxTarget", cfg.maxTarget, maxTarget);
        cfg.minTarget = minTarget.toUint128();
        cfg.defaultTarget = defaultTarget.toUint128();
        cfg.maxTarget = maxTarget.toUint128();
    }

    /// @notice Lists (or re-lists) an ERC-20 as a quote with its target range in raw units. Admin only; the range
    ///         must sit inside `quoteTargetBounds(decimals)`. Listing is the admin's vetting: the token must be a
    ///         plain ERC-20 (no fee on transfer, no rebasing); launches still check each transfer.
    function listQuote(address quote, uint256 minTarget, uint256 defaultTarget, uint256 maxTarget)
        external
        configChange
    {
        uint8 decimals = _decimals(quote);
        (uint256 lo, uint256 hi) = quoteTargetBounds(decimals);
        _checkTargets(minTarget, defaultTarget, maxTarget, lo, hi);
        _quotes[quote] = QuoteConfig({
            listed: true,
            decimals: decimals,
            minTarget: minTarget.toUint128(),
            defaultTarget: defaultTarget.toUint128(),
            maxTarget: maxTarget.toUint128()
        });
        emit QuoteListed(quote, decimals, minTarget, defaultTarget, maxTarget);
    }

    /// @notice Removes an ERC-20 quote's listing. Admin only. Live tokens paired with it are unaffected.
    function delistQuote(address quote) external configChange {
        if (!_quotes[quote].listed) revert QuoteNotListed();
        delete _quotes[quote];
        emit QuoteDelisted(quote);
    }

    /// @notice Allows or refuses launches paired with ERC-20s the admin has not listed. Admin only.
    function setUnlistedQuotesAllowed(bool allowed) external configChange {
        emit ConfigChanged("unlistedQuotesAllowed", _config.unlistedQuotesAllowed ? 1 : 0, allowed ? 1 : 0);
        _config.unlistedQuotesAllowed = allowed;
    }

    /// @notice Sets the launch fee (native) for future launches. Admin only; never above `MAX_LAUNCH_FEE`.
    function setLaunchFee(uint256 launchFee) external configChange {
        if (launchFee > C.MAX_LAUNCH_FEE) revert OutOfRange();
        emit ConfigChanged("launchFee", _config.launchFee, launchFee);
        _config.launchFee = launchFee.toUint96();
    }

    /// @notice Pauses or resumes new launches. Admin only. Live tokens are unaffected.
    function setLaunchesPaused(bool paused) external configChange {
        emit ConfigChanged("launchesPaused", _config.launchesPaused ? 1 : 0, paused ? 1 : 0);
        _config.launchesPaused = paused;
    }

    /// @notice Step one of an admin transfer. Admin only. Proposing address(0) cancels.
    function proposeAdmin(address proposed) external onlyAdmin {
        pendingAdmin = proposed;
        emit AdminProposed(admin, proposed);
    }

    /// @notice Step two of an admin transfer. Callable by the proposed admin only.
    function acceptAdmin() external {
        address proposed = pendingAdmin;
        if (proposed == address(0) || msg.sender != proposed) revert NotPendingAdmin();
        emit AdminChanged(admin, proposed);
        admin = proposed;
        pendingAdmin = address(0);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Hands the pool to the locker with the quote for the first buy: as value for the native coin, or pulled
    ///      from the caller straight to the locker for an ERC-20 (at least the probe amount, checked to the unit).
    function _openPool(address token, LaunchParams calldata p, uint16 taxBps, Config memory cfg, uint8 decimals)
        internal
    {
        StealthLocker.LaunchInput memory input = StealthLocker.LaunchInput({
            token: token,
            launcher: msg.sender,
            quote: Currency.wrap(p.quote),
            taxBps: taxBps,
            target: p.target,
            maxWalletBps: p.options.maxWalletBps,
            maxBuyBps: p.options.maxBuyBps,
            limitsWindow: p.options.limitsWindow,
            firstBuyLock: p.options.firstBuyLock,
            quoteIn: 0,
            devBuy: 0,
            minTokensOut: p.minTokensOut
        });
        if (p.quote == address(0)) {
            input.quoteIn = msg.value - cfg.launchFee;
            input.devBuy = input.quoteIn;
            locker.launch{value: input.quoteIn}(input);
            return;
        }
        uint256 probe = _probeAmount(decimals);
        input.quoteIn = p.quoteAmount > probe ? p.quoteAmount : probe;
        input.devBuy = p.quoteAmount;
        _pullExact(IERC20(p.quote), input.quoteIn);
        locker.launch(input);
    }

    function _emitLaunched(address token, address creator, uint16 taxBps, LaunchParams calldata p) internal {
        emit Launched(
            token,
            creator,
            StealthToken(token).poolId(),
            msg.sender,
            p.quote,
            p.name,
            p.symbol,
            taxBps,
            p.options.launchType,
            p.target
        );
    }

    /// @dev Moves `amount` of `quote` from the caller to the locker and refuses anything but an exact move on both
    ///      sides (fee-on-transfer, burn-on-transfer and similar tokens).
    function _pullExact(IERC20 quote, uint256 amount) internal {
        address to = address(locker);
        uint256 fromBefore = quote.balanceOf(msg.sender);
        uint256 toBefore = quote.balanceOf(to);
        quote.safeTransferFrom(msg.sender, to, amount);
        if (quote.balanceOf(msg.sender) + amount != fromBefore || quote.balanceOf(to) != toBefore + amount) {
            revert UnsupportedQuote();
        }
    }

    function _tokenArgs(LaunchParams calldata p, address launcher) internal pure returns (StealthToken.Args memory) {
        return StealthToken.Args({
            name: p.name,
            symbol: p.symbol,
            logo: p.logo,
            description: p.description,
            socials: p.socials,
            deployer: launcher,
            quote: p.quote,
            maxWalletBps: p.options.maxWalletBps,
            limitsWindow: p.options.maxWalletBps == 0 ? 0 : p.options.limitsWindow,
            firstBuyLock: p.options.firstBuyLock
        });
    }

    /// @dev A creator or team wallet that is one of the system's own contracts could never claim, stranding its share.
    function _checkRecipient(address wallet) internal view {
        if (
            wallet == address(this) || wallet == address(locker) || wallet == address(feeVault) || wallet == _hook
                || wallet == address(tokenDeployer) || wallet == _poolManager || wallet == _settlement
        ) revert InvalidCreator();
    }

    /// @return decimals The quote's decimals (18 for the native coin).
    /// @return taxBps The launch's tier.
    function _validateLaunch(LaunchParams calldata p, Config memory cfg)
        internal
        view
        returns (uint8 decimals, uint16 taxBps)
    {
        if (cfg.launchesPaused) revert LaunchesPaused();
        if (p.configVersion != configVersion) revert StaleConfig();
        uint256 nameLength = bytes(p.name).length;
        uint256 symbolLength = bytes(p.symbol).length;
        if (nameLength == 0 || nameLength > C.MAX_NAME_LENGTH) revert InvalidName();
        if (symbolLength == 0 || symbolLength > C.MAX_SYMBOL_LENGTH) revert InvalidSymbol();
        if (
            bytes(p.logo).length > C.MAX_LOGO_LENGTH || bytes(p.description).length > C.MAX_DESCRIPTION_LENGTH
                || bytes(p.socials.twitter).length > C.MAX_SOCIAL_LENGTH
                || bytes(p.socials.telegram).length > C.MAX_SOCIAL_LENGTH
                || bytes(p.socials.discord).length > C.MAX_SOCIAL_LENGTH
                || bytes(p.socials.website).length > C.MAX_SOCIAL_LENGTH
                || bytes(p.socials.farcaster).length > C.MAX_SOCIAL_LENGTH
        ) revert InvalidMetadata();
        taxBps = p.taxBps == 0 ? C.DEFAULT_TAX_BPS : p.taxBps;
        if (
            taxBps != C.TAX_TIER_1 && taxBps != C.TAX_TIER_2 && taxBps != C.TAX_TIER_3 && taxBps != C.TAX_TIER_4
                && taxBps != C.TAX_TIER_5
        ) revert InvalidTax();
        _validateOptions(p.options);
        if (p.quote == address(0)) {
            if (p.quoteAmount != 0) revert InvalidValue();
            if (p.target < cfg.minTarget || p.target > cfg.maxTarget) revert InvalidTarget();
            if (msg.value < cfg.launchFee) revert InsufficientLaunchFee();
            return (18, taxBps);
        }
        _checkQuoteAddress(p.quote);
        decimals = _decimals(p.quote);
        QuoteConfig memory q = _quotes[p.quote];
        uint256 lo;
        uint256 hi;
        if (q.listed) {
            (lo, hi) = (q.minTarget, q.maxTarget);
        } else {
            if (!cfg.unlistedQuotesAllowed) revert QuoteNotListed();
            (lo, hi) = quoteTargetBounds(decimals);
        }
        if (p.target < lo || p.target > hi) revert InvalidTarget();
        if (msg.value != cfg.launchFee) revert InvalidValue();
    }

    /// @dev Launch type, team, limits and lock.
    function _validateOptions(LaunchOptions calldata o) internal view {
        if (o.launchType == LaunchType.Team) {
            uint256 n = o.team.length;
            if (n < C.MIN_TEAM_SIZE || n > C.MAX_TEAM_SIZE) revert InvalidOptions();
            uint256 sum;
            for (uint256 i; i < n; ++i) {
                address wallet = o.team[i].wallet;
                if (wallet == address(0) || o.team[i].bps == 0) revert InvalidOptions();
                _checkRecipient(wallet);
                sum += o.team[i].bps;
                for (uint256 j; j < i; ++j) {
                    if (o.team[j].wallet == wallet) revert InvalidOptions();
                }
            }
            if (sum != C.BPS) revert InvalidOptions();
        } else if (o.team.length != 0) {
            revert InvalidOptions();
        }
        if (o.maxWalletBps != 0 && (o.maxWalletBps < C.MIN_MAX_WALLET_BPS || o.maxWalletBps > C.MAX_MAX_WALLET_BPS)) {
            revert InvalidOptions();
        }
        if (o.maxBuyBps != 0 && (o.maxBuyBps < C.MIN_MAX_BUY_BPS || o.maxBuyBps > C.MAX_MAX_BUY_BPS)) {
            revert InvalidOptions();
        }
        bool limited = (o.maxWalletBps | o.maxBuyBps) != 0;
        if (limited ? (o.limitsWindow == 0 || o.limitsWindow > C.MAX_LIMITS_WINDOW) : o.limitsWindow != 0) {
            revert InvalidOptions();
        }
        if (o.firstBuyLock > C.MAX_FIRST_BUY_LOCK) revert InvalidOptions();
    }

    /// @dev An ERC-20 quote must be a contract and not one of the system's own contracts.
    function _checkQuoteAddress(address quote) internal view {
        if (
            quote.code.length == 0 || quote == address(this) || quote == address(locker) || quote == address(feeVault)
                || quote == _hook || quote == address(tokenDeployer) || quote == _poolManager || quote == _settlement
        ) revert InvalidQuote();
    }

    /// @dev The quote's `decimals()`, which must exist and be 6 to 18.
    function _decimals(address quote) internal view returns (uint8 decimals) {
        if (quote.code.length == 0) revert InvalidQuote();
        try IERC20Metadata(quote).decimals() returns (uint8 d) {
            decimals = d;
        } catch {
            revert InvalidQuote();
        }
        if (decimals < C.MIN_QUOTE_DECIMALS || decimals > C.MAX_QUOTE_DECIMALS) revert UnsupportedQuote();
    }

    function _probeAmount(uint8 decimals) internal pure returns (uint256 amount) {
        amount = 10 ** (decimals - C.PROBE_UNIT_EXP);
        if (amount < C.PROBE_MIN_RAW) amount = C.PROBE_MIN_RAW;
    }

    function _checkTargets(uint256 minTarget, uint256 defaultTarget, uint256 maxTarget, uint256 floor, uint256 ceiling)
        internal
        pure
    {
        if (minTarget < floor || maxTarget > ceiling || minTarget > defaultTarget || defaultTarget > maxTarget) {
            revert OutOfRange();
        }
    }
}
