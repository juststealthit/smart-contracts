// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Dex, DexBase, DexCallback, IDexManager, BalanceDelta, Currency} from "@dex/Dex.sol";
import {StealthConstants as C} from "./libraries/StealthConstants.sol";
import {LaunchType, TeamShare} from "./interfaces/IStealth.sol";

/// @notice The factory's admin, read live so an admin hand-over applies here too.
interface IFactoryAdmin {
    function admin() external view returns (address);
}

/// @notice The hook's sniper window, read before a buyback.
interface IHookWindow {
    function sniperWindowEnd(address token) external view returns (uint256);
}

/// @title StealthFeeVault
/// @notice Holds every Stealth trading fee and pays it out, in each token's quote currency (the native coin or the
///         ERC-20 it is paired with). Each swap's tax is split on arrival. The coin gets 70% of its tier, and the
///         platform wallet everything else the trade paid, including all of a sniper fee above the tier. The coin's
///         part goes by the launch type picked at launch and locked:
///           - Creator:   the creator's wallet.
///           - Team:      2-10 wallets by bps.
///           - Marketing: the marketing wallet.
///           - Holders:   a pot the distributor pays out to holders.
///           - Buyback:   a pot the distributor spends buying the coin and burning it.
///           - Pot:       a general pot the distributor pays out, for launch types run off chain by the ops bot.
///         Marketing and platform shares go to two wallets (anyone can sweep them). Launch fees are in the native coin,
///         straight to the platform wallet.
/// @dev Fees arrive as ERC-6909 claims on the DEX's settlement contract, minted by the hook during the swap, so this
///      vault's whole balance is claims, tracked per currency (`totalOwed[currency]`). A payout burns the claim and
///      takes the currency straight to the recipient. A default launch writes one slot here, a swap three.
///
///      Each token has one number for its coin part (`coinOwed`), since it has one launch type. On a Team coin the
///      wallets and their bps are fixed at launch, so a member's lifetime earnings follow from `teamAccrued` and a
///      claim touches nothing but that member's `memberPaid`: swaps and claims never loop over members to write.
///
///      Creator role: changes by its own two-step hand-off (the unclaimed balance moves with the role) or by a takeover
///      (creator manager proposes, `reassignNotice` passes, the factory admin can cancel, the new creator accepts;
///      the old creator keeps what it earned as `legacyOwed`). Only the Creator type pays the role; on other types
///      it is attribution.
contract StealthFeeVault is DexCallback, ReentrancyGuardTransient {
    /// @dev `Legacy` is a replaced creator claiming what it earned before a takeover (counted in `creatorClaimed`). The
    ///      order is the `Paid` event's ABI: new roles go at the end.
    enum Role {
        Creator,
        Marketing,
        Platform,
        Legacy,
        Holders,
        Buyback,
        Team,
        Pot
    }

    /// @dev One slot: all a launch of the default type writes here.
    struct Coin {
        address creator;
        LaunchType launchType;
        uint16 taxBps;
    }

    /// @dev One slot, written by every swap, so a swap and a first buy pay for one write, not two. A fee fits in 127 bits
    ///      (the hook's delta is an int128). The sums only overflow past 2^128 raw units, far beyond any listed quote.
    struct Pair {
        uint128 platform;
        uint128 marketing;
    }

    struct Reassignment {
        address to;
        uint64 eta; // the earliest time `to` can accept
        uint32 epoch; // `managerEpoch` when proposed; a replaced manager's proposals can no longer be accepted
    }

    struct Payout {
        Currency currency;
        address to;
        uint256 amount;
    }

    /// @notice The longest takeover notice a deployment can use.
    uint256 public constant MAX_REASSIGN_NOTICE = 7 days;
    /// @notice How long a takeover stays acceptable once its notice has run out.
    uint256 public constant REASSIGN_WINDOW = 7 days;

    /// @notice StealthHook: credits every trading fee.
    address public immutable hook;
    /// @notice StealthFactory: registers tokens and credits launch fees.
    address public immutable factory;
    /// @notice How long a takeover proposal waits before the new creator can accept it (24 hours on mainnet).
    uint256 public immutable reassignNotice;

    /// @notice Receives the platform share. Set at deploy; the factory admin can rotate it.
    address public platform;
    /// @notice Receives the marketing share. Set at deploy; the factory admin can rotate it.
    address public marketing;
    /// @notice Proposes takeovers. Set by the factory admin.
    address public creatorManager;
    /// @notice Bumped each time the creator manager is replaced. Proposals from an earlier epoch are void.
    uint32 public managerEpoch;
    /// @notice Pays out the holders pots and general pots, and spends the buyback pots. Set by the factory admin.
    address public distributor;

    mapping(address token => Coin) internal _coins;
    mapping(address token => address) public pendingCreator;
    /// @notice The open takeover proposal of each token, if any.
    mapping(address token => Reassignment) public reassignment;
    /// @notice The currency each token's fees are in: its pool's quote (address 0 = the native coin).
    mapping(address token => Currency) public quoteOf;

    mapping(address token => Pair) internal _owed;
    mapping(address token => Pair) internal _paid;
    /// @notice The coin's part, unpaid: the creator's balance, the team's, the holders pot, the buyback pot or the
    ///         general pot, by launch type (always 0 on the Marketing type, whose part is `marketingOwed`).
    mapping(address token => uint256) public coinOwed;
    /// @notice Lifetime amounts paid to the creator, a former creator or the team, per token.
    mapping(address token => uint256) public creatorClaimed;
    /// @notice Lifetime amounts paid out of or spent from a holders, buyback or general pot.
    mapping(address token => uint256) public potPaid;
    /// @notice The nonce the next pot call for a token must carry. A call that went through cannot run again, so a
    ///         bot that does not know whether its transaction landed can always just send it again.
    mapping(address token => uint256) public potNonce;
    /// @notice Lifetime launch fees, per token, in the native coin (paid straight to the platform wallet).
    mapping(address token => uint256) public launchFeePaid;

    /// @notice Creator fees a replaced creator earned before a takeover, per token and wallet.
    mapping(address token => mapping(address wallet => uint256)) public legacyOwed;
    /// @notice Sum of `legacyOwed` over every wallet, per token.
    mapping(address token => uint256) public legacyTotal;

    /// @dev Team wallets and bps, fixed at launch: (wallet << 16) | bps. Wallet 0 takes the rounding remainder.
    mapping(address token => uint256[]) internal _team;
    /// @notice The team's lifetime earnings.
    mapping(address token => uint256) public teamAccrued;
    /// @notice What each team wallet has been paid so far.
    mapping(address token => mapping(address wallet => uint256)) public memberPaid;

    /// @notice Sum of everything owed in `currency`, across tokens and roles. Always equals this contract's ERC-6909
    ///         claim for that currency (more only if someone gifts claims).
    mapping(Currency currency => uint256) public totalOwed;

    event TokenRegistered(address indexed token, address indexed creator, Currency quote, LaunchType launchType);
    event TeamSet(address indexed token, address[] wallets, uint16[] bps);
    /// @notice A swap's fee split: `platform` + `marketing` + `coin` is the whole fee. `marketing` is the coin's part on
    ///         the Marketing type and 0 on any other; `coin` is the coin's part on any other type.
    event FeeCredited(address indexed token, uint256 platform, uint256 marketing, uint256 coin);
    event LaunchFeePaid(address indexed token, address indexed to, uint256 amount);
    event Paid(address indexed token, Role indexed role, address indexed to, uint256 amount);
    /// @notice A buyback spent `quoteSpent` of the coin's pot and burned `tokensBurned`, taking `totalSupply` down by
    ///         that much. `potAfter` is the pot after the buyback's own tax came back to it.
    event BuybackBurned(
        address indexed token, uint256 indexed nonce, uint256 quoteSpent, uint256 tokensBurned, uint256 potAfter
    );
    event CreatorOffered(address indexed token, address indexed from, address indexed to);
    event CreatorAccepted(address indexed token, address indexed to);
    event Skimmed(address indexed to, Currency indexed currency, uint256 claims, uint256 native);
    event WalletsSet(address platform, address marketing);
    event CreatorManagerSet(address indexed previous, address indexed current);
    event DistributorSet(address indexed previous, address indexed current);
    event ReassignProposed(address indexed token, address indexed from, address indexed to, uint256 eta);
    event ReassignCancelled(address indexed token, address indexed to, address indexed by);
    event CreatorReassigned(address indexed token, address indexed from, address indexed to, uint256 legacy);

    error NotAuthorized();
    error NotCreator();
    error NotPendingCreator();
    error AlreadyRegistered();
    error NothingToClaim();
    error SkimFailed();
    error LaunchFeeFailed();
    error InvalidNotice();
    error NotCreatorManager();
    error NotAdminOrManager();
    error NotDistributor();
    error UnknownToken();
    error InvalidReassign();
    error NoReassign();
    error NoticeRunning();
    error ReassignExpired();
    error AmountTooHigh();
    error StaleReassign();
    error WrongCurrency();
    error WrongLaunchType();
    error LengthMismatch();
    error StaleNonce();
    error Expired();
    error ZeroAmount();
    error Slippage();
    error SniperWindowOpen();

    modifier onlyCreator(address token) {
        if (msg.sender != _coins[token].creator) revert NotCreator();
        _;
    }

    modifier onlyFactoryAdmin() {
        if (msg.sender != IFactoryAdmin(factory).admin()) revert NotAuthorized();
        _;
    }

    /// @param poolManager_ The chain's pool manager.
    /// @param platform_ Platform recipient.
    /// @param marketing_ Marketing recipient.
    /// @param hook_ StealthHook (credits trading fees).
    /// @param factory_ StealthFactory (registers tokens, credits launch fees; its admin governs roles and takeovers).
    /// @param creatorManager_ First creator manager.
    /// @param distributor_ First distributor (pays out and spends the pots).
    /// @param reassignNotice_ Takeover notice in seconds, 1 second to 7 days (the mainnet deploy uses 24 hours).
    constructor(
        IDexManager poolManager_,
        address platform_,
        address marketing_,
        address hook_,
        address factory_,
        address creatorManager_,
        address distributor_,
        uint256 reassignNotice_
    ) DexBase(poolManager_) {
        if (
            platform_ == address(0) || marketing_ == address(0) || hook_ == address(0) || factory_ == address(0)
                || creatorManager_ == address(0) || distributor_ == address(0)
        ) revert ZeroAddress();
        if (reassignNotice_ == 0 || reassignNotice_ > MAX_REASSIGN_NOTICE) revert InvalidNotice();
        platform = platform_;
        marketing = marketing_;
        hook = hook_;
        factory = factory_;
        reassignNotice = reassignNotice_;
        creatorManager = creatorManager_;
        distributor = distributor_;
        emit WalletsSet(platform_, marketing_);
        emit CreatorManagerSet(address(0), creatorManager_);
        emit DistributorSet(address(0), distributor_);
    }

    // ---------------------------------------------------------------------
    // Crediting
    // ---------------------------------------------------------------------

    /// @notice Records a token's creator, quote, launch type and team.
    /// @dev Callable by the factory only, once per token. The factory has checked the team.
    function registerToken(
        address token,
        address creator,
        Currency quote,
        LaunchType launchType,
        TeamShare[] calldata teamShares,
        uint16 taxBps
    ) external {
        if (msg.sender != factory) revert NotAuthorized();
        if (creator == address(0)) revert ZeroAddress();
        if (_coins[token].creator != address(0)) revert AlreadyRegistered();
        _coins[token] = Coin(creator, launchType, taxBps);
        // The native coin is address 0, so the default launch writes no quote.
        if (Currency.unwrap(quote) != address(0)) quoteOf[token] = quote;
        emit TokenRegistered(token, creator, quote, launchType);
        if (teamShares.length != 0) _storeTeam(token, teamShares);
    }

    function _storeTeam(address token, TeamShare[] calldata teamShares) internal {
        uint256[] storage shares = _team[token];
        address[] memory wallets = new address[](teamShares.length);
        uint16[] memory bps = new uint16[](teamShares.length);
        for (uint256 i; i < teamShares.length; ++i) {
            wallets[i] = teamShares[i].wallet;
            bps[i] = teamShares[i].bps;
            shares.push((uint256(uint160(teamShares[i].wallet)) << 16) | teamShares[i].bps);
        }
        emit TeamSet(token, wallets, bps);
    }

    /// @notice Books a trading fee the hook has just minted to this vault as a claim on `currency`, charged at `rate`
    ///         pips: 70% of the coin's tier for the coin, the rest for the platform wallet, the coin's part by launch
    ///         type.
    /// @dev Callable by the hook only. No external calls, so it can never make a swap fail (the currency always
    ///      matches: the hook mints in the pool's currency0, which is the token's registered quote). `fee * share / rate`
    ///      is 70% of the tier in all four swap modes, since `fee` is `rate` of the gross quote leg in all of them. The
    ///      hook's rate is never under the tier, so `share < rate` and the coin's part is always below the fee.
    function credit(address token, Currency currency, uint256 fee, uint24 rate) external {
        if (msg.sender != hook) revert NotAuthorized();
        if (!(currency == quoteOf[token])) revert WrongCurrency();
        totalOwed[currency] += fee;
        Coin storage c = _coins[token];
        LaunchType launchType = c.launchType;
        uint256 coin = fee * (uint256(c.taxBps) * C.PIPS_PER_BPS * C.COIN_TAX_BPS / C.BPS) / rate;
        uint256 mkt = launchType == LaunchType.Marketing ? coin : 0;
        uint256 main = coin - mkt;
        uint256 toPlatform = fee - coin;
        Pair storage owed = _owed[token];
        owed.platform += uint128(toPlatform);
        owed.marketing += uint128(mkt);
        if (main != 0) {
            coinOwed[token] += main;
            if (launchType == LaunchType.Team) teamAccrued[token] += main;
        }
        emit FeeCredited(token, toPlatform, mkt, main);
    }

    /// @notice Pays a launch fee (`msg.value`, the native coin) straight to the platform wallet and records it.
    /// @dev Callable by the factory only. The platform wallet must accept the native coin.
    function creditLaunchFee(address token) external payable {
        if (msg.sender != factory) revert NotAuthorized();
        if (msg.value == 0) return;
        launchFeePaid[token] += msg.value;
        address to = platform;
        emit LaunchFeePaid(token, to, msg.value);
        (bool ok,) = to.call{value: msg.value}("");
        if (!ok) revert LaunchFeeFailed();
    }

    // ---------------------------------------------------------------------
    // Payouts
    // ---------------------------------------------------------------------

    /// @notice Pays the caller its whole balance on `token` (the creator of a Creator coin, or a team wallet). Pays no
    ///         one else, so no other wallet's behaviour can hold a claim up: the admin's rotation of the platform and
    ///         marketing wallets gives it no way to freeze creators.
    function claimCreator(address token) external nonReentrant returns (uint256 amount) {
        amount = claimable(token, msg.sender);
        _claim(token, amount, msg.sender);
    }

    /// @notice Like `claimCreator`, but pays only `amount` of the caller's balance, to `to`, and leaves the rest owed.
    function claimCreatorAmount(address token, uint256 amount, address to) external nonReentrant {
        _claim(token, amount, to);
    }

    /// @notice Pays the creator fees the caller earned on `token` before a takeover replaced it, to `to`.
    function claimLegacy(address token, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = legacyOwed[token][msg.sender];
        if (amount == 0) revert NothingToClaim();
        Currency currency = quoteOf[token];
        legacyOwed[token][msg.sender] = 0;
        legacyTotal[token] -= amount;
        creatorClaimed[token] += amount;
        totalOwed[currency] -= amount;
        emit Paid(token, Role.Legacy, to, amount);
        _pay1(currency, to, amount);
    }

    /// @notice Pays a Holders or Pot coin's pot out to the given recipients, in its quote. The distributor (ops bot)
    ///         works out the amounts off chain. `nonce` must equal `potNonce(token)`.
    function withdrawPot(address token, address[] calldata to, uint256[] calldata amounts, uint256 nonce)
        external
        nonReentrant
        returns (uint256 total)
    {
        if (msg.sender != distributor) revert NotDistributor();
        LaunchType launchType = _coins[token].launchType;
        if (launchType != LaunchType.Holders && launchType != LaunchType.Pot) revert WrongLaunchType();
        Role role = launchType == LaunchType.Pot ? Role.Pot : Role.Holders;
        if (to.length != amounts.length) revert LengthMismatch();
        if (nonce != potNonce[token]) revert StaleNonce();
        Currency currency = quoteOf[token];
        Payout[] memory payouts = new Payout[](to.length);
        for (uint256 i; i < to.length; ++i) {
            if (to[i] == address(0)) revert ZeroAddress();
            payouts[i] = Payout(currency, to[i], amounts[i]);
            total += amounts[i];
            emit Paid(token, role, to[i], amounts[i]);
        }
        if (total == 0) revert NothingToClaim();
        uint256 owed = coinOwed[token];
        if (total > owed) revert AmountTooHigh();
        potNonce[token] = nonce + 1;
        coinOwed[token] = owed - total;
        potPaid[token] += total;
        totalOwed[currency] -= total;
        _run(payouts);
    }

    /// @notice Spends `amount` of a Buyback coin's pot buying the coin from its pool, and burns every token bought:
    ///         `totalSupply` goes down by `tokensBurned`. Distributor only. The buy is a normal trade: it pays the
    ///         coin's tier, whose coin part comes back to the pot.
    /// @dev Spends claims, so no funds leave the settlement contract except to the pool. Reverts change nothing, so
    ///      the bot can retry any failure. `nonce` must equal `potNonce(token)`, so resending a buyback that did land
    ///      reverts instead of spending twice.
    /// @param minTokensOut The least the buy may return: the bot's own quote less its slippage. Must not be 0.
    /// @param deadline Last timestamp the buyback may run at, so a stuck transaction cannot run at a stale price.
    /// @param nonce `potNonce(token)` as the bot read it.
    function buyback(address token, uint256 amount, uint256 minTokensOut, uint256 deadline, uint256 nonce)
        external
        nonReentrant
        returns (uint256 tokensBurned)
    {
        if (msg.sender != distributor) revert NotDistributor();
        if (_coins[token].launchType != LaunchType.Buyback) revert WrongLaunchType();
        if (block.timestamp > deadline) revert Expired();
        if (amount == 0 || minTokensOut == 0) revert ZeroAmount();
        if (nonce != potNonce[token]) revert StaleNonce();
        // In the sniper window the buy would pay up to 90% of the pot as tax.
        if (block.timestamp < IHookWindow(hook).sniperWindowEnd(token)) revert SniperWindowOpen();
        uint256 owed = coinOwed[token];
        if (amount > owed) revert AmountTooHigh();
        Currency currency = quoteOf[token];
        potNonce[token] = nonce + 1;
        coinOwed[token] = owed - amount;
        potPaid[token] += amount;
        totalOwed[currency] -= amount;
        tokensBurned = abi.decode(_lockRaw(abi.encode(true, abi.encode(token, currency, amount))), (uint256));
        if (tokensBurned < minTokensOut) revert Slippage();
        // The token's own burn: supply really falls, with no dead-address balance for anyone to count or trust.
        ERC20Burnable(token).burn(tokensBurned);
        emit Paid(token, Role.Buyback, address(0), amount);
        emit BuybackBurned(token, nonce, amount, tokensBurned, coinOwed[token]);
    }

    /// @notice Pays each token's marketing share to `marketing` and platform share to `platform`, each in the token's
    ///         quote currency. Anyone may call; the caller chooses nothing but the list. Tokens with nothing owed are
    ///         skipped. Consecutive tokens with the same quote are paid out together, so callers should group them.
    /// @return marketingTotal Sum of the marketing payouts (raw units; mixes currencies if the tokens do).
    /// @return platformTotal Sum of the platform payouts (same).
    function sweep(address[] calldata tokens)
        external
        nonReentrant
        returns (uint256 marketingTotal, uint256 platformTotal)
    {
        Payout[] memory payouts = new Payout[](tokens.length * 2);
        address marketingWallet = marketing;
        address platformWallet = platform;
        uint256 n;
        for (uint256 i; i < tokens.length; ++i) {
            (uint256 m, uint256 p) = _book(tokens[i], marketingWallet, platformWallet);
            if (m + p == 0) continue;
            Currency currency = quoteOf[tokens[i]];
            totalOwed[currency] -= m + p;
            marketingTotal += m;
            platformTotal += p;
            if (n != 0 && payouts[n - 2].currency == currency) {
                payouts[n - 2].amount += m;
                payouts[n - 1].amount += p;
            } else {
                payouts[n++] = Payout(currency, marketingWallet, m);
                payouts[n++] = Payout(currency, platformWallet, p);
            }
        }
        if (n == 0) return (0, 0);
        assembly ("memory-safe") {
            mstore(payouts, n)
        }
        _run(payouts);
    }

    /// @notice Sends anything the vault holds beyond what it owes to the platform wallet: claims on `currency` that
    ///         someone minted or transferred to it, and any native coin forced in with selfdestruct. Anyone may call.
    ///         Owed balances are never touched.
    function skim(Currency currency) external nonReentrant returns (uint256 claims, uint256 native) {
        uint256 held = _claimOf(address(this), currency);
        uint256 owed = totalOwed[currency];
        claims = held > owed ? held - owed : 0;
        native = address(this).balance;
        if (claims == 0 && native == 0) return (0, 0);
        address to = platform;
        emit Skimmed(to, currency, claims, native);
        if (claims != 0) _pay1(currency, to, claims);
        if (native != 0) {
            (bool ok,) = to.call{value: native}("");
            if (!ok) revert SkimFailed();
        }
    }

    // ---------------------------------------------------------------------
    // Team
    // ---------------------------------------------------------------------

    /// @notice A Team coin's wallets and their bps (empty for other launch types).
    function team(address token) external view returns (address[] memory wallets, uint16[] memory bps) {
        uint256[] storage shares = _team[token];
        wallets = new address[](shares.length);
        bps = new uint16[](shares.length);
        for (uint256 i; i < shares.length; ++i) {
            wallets[i] = address(uint160(shares[i] >> 16));
            bps[i] = uint16(shares[i]);
        }
    }

    /// @notice What `wallet` could claim from the coin's part now: the creator's balance on a Creator coin, a team
    ///         wallet's unpaid earnings on a Team coin, otherwise nothing.
    function claimable(address token, address wallet) public view returns (uint256) {
        Coin memory c = _coins[token];
        if (c.launchType == LaunchType.Creator) return wallet == c.creator ? coinOwed[token] : 0;
        if (c.launchType != LaunchType.Team) return 0;
        return _earned(token, wallet) - memberPaid[token][wallet];
    }

    /// @dev A team wallet's lifetime earnings: its bps of `teamAccrued`, rounded down; wallet 0 takes what the
    ///      rounding leaves, so the wallets' earnings always sum to `teamAccrued`.
    function _earned(address token, address wallet) internal view returns (uint256 earned) {
        uint256[] storage shares = _team[token];
        uint256 n = shares.length;
        uint256 accrued = teamAccrued[token];
        uint256 others;
        bool first;
        for (uint256 i; i < n; ++i) {
            uint256 s = shares[i];
            address w = address(uint160(s >> 16));
            if (i == 0) {
                first = w == wallet;
                continue;
            }
            uint256 share = accrued * uint16(s) / C.BPS;
            others += share;
            if (w == wallet) return share;
        }
        return first ? accrued - others : 0;
    }

    function _isTeamWallet(address token, address wallet) internal view returns (bool) {
        uint256[] storage shares = _team[token];
        for (uint256 i; i < shares.length; ++i) {
            if (address(uint160(shares[i] >> 16)) == wallet) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------------
    // Creator hand-off (two-step)
    // ---------------------------------------------------------------------

    /// @notice Offers the creator role for `token` to `to`. Offering address(0) cancels.
    /// @dev Callable by the current creator only. The creator's unclaimed balance moves with the role. Does not
    ///      touch an open takeover proposal.
    function offerCreator(address token, address to) external onlyCreator(token) {
        pendingCreator[token] = to;
        emit CreatorOffered(token, msg.sender, to);
    }

    /// @notice Accepts a pending creator offer.
    /// @dev Callable by the offered address only. An open takeover proposal for the same address is settled by
    ///      the hand-off, so it is cleared.
    function acceptCreator(address token) external {
        address pending = pendingCreator[token];
        if (pending == address(0) || msg.sender != pending) revert NotPendingCreator();
        _coins[token].creator = pending;
        delete pendingCreator[token];
        emit CreatorAccepted(token, pending);
        if (reassignment[token].to == pending) {
            delete reassignment[token];
            emit ReassignCancelled(token, pending, pending);
        }
    }

    // ---------------------------------------------------------------------
    // Roles and takeovers (creator manager, with notice)
    // ---------------------------------------------------------------------

    /// @notice Rotates the platform and marketing wallets. Factory admin only. Takes effect on the next sweep; what is
    ///         owed to these two roles is the only money it can redirect.
    function setWallets(address platform_, address marketing_) external onlyFactoryAdmin {
        if (platform_ == address(0) || marketing_ == address(0)) revert ZeroAddress();
        platform = platform_;
        marketing = marketing_;
        emit WalletsSet(platform_, marketing_);
    }

    /// @notice Replaces the creator manager. Factory admin only. Every open proposal the previous manager made
    ///         becomes void (it can no longer be accepted), so a stolen manager key is neutralised in one call.
    function setCreatorManager(address manager) external onlyFactoryAdmin {
        if (manager == address(0)) revert ZeroAddress();
        emit CreatorManagerSet(creatorManager, manager);
        creatorManager = manager;
        ++managerEpoch;
    }

    /// @notice Replaces the distributor. Factory admin only.
    function setDistributor(address distributor_) external onlyFactoryAdmin {
        if (distributor_ == address(0)) revert ZeroAddress();
        emit DistributorSet(distributor, distributor_);
        distributor = distributor_;
    }

    /// @notice Proposes `to` as `token`'s new creator. `to` can accept once `reassignNotice` has passed, for
    ///         `REASSIGN_WINDOW`. A new proposal replaces an open one and restarts the notice.
    /// @dev Callable by the creator manager only.
    function proposeReassign(address token, address to) external {
        if (msg.sender != creatorManager) revert NotCreatorManager();
        address current = _coins[token].creator;
        if (current == address(0)) revert UnknownToken();
        if (to == address(0) || to == current) revert InvalidReassign();
        uint256 eta = block.timestamp + reassignNotice;
        reassignment[token] = Reassignment(to, uint64(eta), managerEpoch);
        emit ReassignProposed(token, current, to, eta);
    }

    /// @notice Cancels `token`'s open takeover proposal. Callable by the factory admin or the creator manager.
    function cancelReassign(address token) external {
        if (msg.sender != IFactoryAdmin(factory).admin() && msg.sender != creatorManager) revert NotAdminOrManager();
        address to = reassignment[token].to;
        if (to == address(0)) revert NoReassign();
        delete reassignment[token];
        emit ReassignCancelled(token, to, msg.sender);
    }

    /// @notice Accepts a takeover proposal once its notice has passed. The replaced creator keeps what it had
    ///         earned (`legacyOwed`, claimable with `claimLegacy`).
    /// @dev Callable by the proposed address only. Clears any pending voluntary offer (emitting a cancelled offer).
    function acceptReassign(address token) external {
        Reassignment memory r = reassignment[token];
        if (r.to == address(0) || msg.sender != r.to) revert NoReassign();
        if (r.epoch != managerEpoch) revert StaleReassign();
        if (block.timestamp < r.eta) revert NoticeRunning();
        if (block.timestamp > uint256(r.eta) + REASSIGN_WINDOW) revert ReassignExpired();
        Coin storage coin = _coins[token];
        address from = coin.creator;
        uint256 backlog = coin.launchType == LaunchType.Creator ? coinOwed[token] : 0;
        if (backlog != 0) {
            coinOwed[token] = 0;
            legacyOwed[token][from] += backlog;
            legacyTotal[token] += backlog;
        }
        coin.creator = r.to;
        if (pendingCreator[token] != address(0)) {
            delete pendingCreator[token];
            emit CreatorOffered(token, from, address(0));
        }
        delete reassignment[token];
        emit CreatorReassigned(token, from, r.to, backlog);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function creatorOf(address token) external view returns (address) {
        return _coins[token].creator;
    }

    function launchTypeOf(address token) external view returns (LaunchType) {
        return _coins[token].launchType;
    }

    function platformOwed(address token) external view returns (uint256) {
        return _owed[token].platform;
    }

    function marketingOwed(address token) external view returns (uint256) {
        return _owed[token].marketing;
    }

    function platformPaid(address token) external view returns (uint256) {
        return _paid[token].platform;
    }

    function marketingPaid(address token) external view returns (uint256) {
        return _paid[token].marketing;
    }

    /// @notice Unpaid and lifetime-paid amounts for the main roles of `token`, in its quote currency.
    function balances(address token)
        external
        view
        returns (
            uint256 coinUnpaid,
            uint256 marketingUnpaid,
            uint256 platformUnpaid,
            uint256 creatorPaidOut,
            uint256 marketingPaidOut,
            uint256 platformPaidOut
        )
    {
        Pair memory owed = _owed[token];
        Pair memory paid = _paid[token];
        return (coinOwed[token], owed.marketing, owed.platform, creatorClaimed[token], paid.marketing, paid.platform);
    }

    /// @notice Everything `token` still owes, every role and pot.
    function tokenOwed(address token) external view returns (uint256) {
        Pair memory owed = _owed[token];
        return coinOwed[token] + owed.marketing + owed.platform + legacyTotal[token];
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Pays `amount` of the caller's balance on `token` to `to`.
    function _claim(address token, uint256 amount, address to) internal {
        Coin memory c = _coins[token];
        bool isTeam = c.launchType == LaunchType.Team;
        if (isTeam ? !_isTeamWallet(token, msg.sender) : c.launchType != LaunchType.Creator || msg.sender != c.creator) {
            revert NotCreator();
        }
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert NothingToClaim();
        if (amount > claimable(token, msg.sender)) revert AmountTooHigh();
        Currency currency = quoteOf[token];
        if (isTeam) memberPaid[token][msg.sender] += amount;
        coinOwed[token] -= amount;
        creatorClaimed[token] += amount;
        totalOwed[currency] -= amount;
        emit Paid(token, isTeam ? Role.Team : Role.Creator, to, amount);
        _pay1(currency, to, amount);
    }

    /// @dev Zeroes `token`'s marketing and platform shares, books them as paid and emits the payouts. The caller
    ///      lowers `totalOwed` and sends the funds.
    function _book(address token, address marketingWallet, address platformWallet)
        internal
        returns (uint256 m, uint256 p)
    {
        Pair memory owed = _owed[token];
        m = owed.marketing;
        p = owed.platform;
        if (m + p == 0) return (0, 0);
        delete _owed[token];
        Pair storage paid = _paid[token];
        paid.marketing += uint128(m);
        paid.platform += uint128(p);
        if (m != 0) emit Paid(token, Role.Marketing, marketingWallet, m);
        if (p != 0) emit Paid(token, Role.Platform, platformWallet, p);
    }

    function _pay1(Currency currency, address to, uint256 amount) internal {
        Payout[] memory p = new Payout[](1);
        p[0] = Payout(currency, to, amount);
        _run(p);
    }

    // ---------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------

    /// @dev Pays inside a lock: directly if someone already holds the settlement lock (this contract's deltas still
    ///      net to zero before it returns), otherwise through a lock of its own.
    function _run(Payout[] memory payouts) internal {
        if (_isLocked()) _pay(payouts);
        else _lockRaw(abi.encode(false, abi.encode(payouts)));
    }

    function _onLock(bytes calldata data) internal override returns (bytes memory) {
        (bool isBuyback, bytes memory payload) = abi.decode(data, (bool, bytes));
        if (isBuyback) {
            (address token, Currency currency, uint256 amount) = abi.decode(payload, (address, Currency, uint256));
            return abi.encode(_buy(token, currency, amount));
        }
        _pay(abi.decode(payload, (Payout[])));
        return "";
    }

    /// @dev The buyback's swap: exact-input buy, paid by burning this vault's claim on the quote. The tokens come here
    ///      for `buyback` to burn. The hook's fee is a claim back to this vault and a `credit` like any other swap's.
    function _buy(address token, Currency currency, uint256 amount) internal returns (uint256 tokensOut) {
        BalanceDelta delta = poolManager.swap(
            Dex.key(currency, token, hook, address(poolManager), C.POOL_FEE, C.TICK_SPACING),
            IDexManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: Dex.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        tokensOut = uint256(uint128(delta.amount1()));
        _burnClaim(address(this), currency, amount);
        _take(Currency.wrap(token), address(this), tokensOut);
    }

    /// @dev For each payout: burns that much of this vault's claim and takes the currency to the recipient.
    function _pay(Payout[] memory payouts) internal {
        for (uint256 i; i < payouts.length; ++i) {
            Payout memory p = payouts[i];
            if (p.amount == 0) continue;
            _burnClaim(address(this), p.currency, p.amount);
            _take(p.currency, p.to, p.amount);
        }
    }
}
