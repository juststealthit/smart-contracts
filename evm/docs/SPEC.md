# Stealth EVM contracts: specification

Status: **deployed on five chains, not audited.** Addresses are in [`../deployments`](../deployments), and [`docs/chains.md`](../../docs/chains.md) lists them per chain. This describes the source in this repository, which matches the deployed bytecode on every chain.

## 1. What it is

A token launchpad on five chains.

| Chain | Id | Gas | DEX | Build |
| --- | --- | --- | --- | --- |
| Robinhood Chain | 4663 | ETH | Uniswap v4 | default |
| HyperEVM | 999 | HYPE | Uniswap v4 | default |
| Base | 8453 | ETH | Uniswap v4 | default |
| Arc | 5042 | USDC (native, 18 decimals) | Uniswap v4 | default |
| BNB Chain | 56 | BNB | PancakeSwap Infinity CL | `FOUNDRY_PROFILE=infinity` |

Every launch deploys a token and opens its pool in one transaction, with the whole supply locked in two positions
shaped like a bonding curve: 800M tokens from the launch price to the graduation price, 200M from there to the bottom
of the range. There is no migration: graduation is a price level, flagged by the hook. The pool trades on any route of
its DEX from the first block. Nothing can remove the liquidity, and the pool's LP fee is 0: the hook takes the tax.

Quotes: the chain's native coin by default, or an ERC-20 the admin listed (or any ERC-20 with 6-18 decimals that moves
exactly, where `unlistedQuotesAllowed` is on; off by default). The token's address is always above its quote's, so the
quote is always currency0 and one set of curve maths serves every pair.

## 2. One codebase, two builds

`src/` is one set of contracts. The only thing that differs between builds is the `@dex/` remapping, which picks
`variants/v4/` or `variants/infinity/`. Each holds:

- `Dex.sol`: the DEX's types, the pool key, tick maths names and one-line settlement forwards (`DexBase`, `DexCallback`,
  `DexHook`). No Stealth logic.
- `DexTest.sol`: installs the production bytecode at its real addresses for tests, and reads pool state.
- `UniversalRouterLib.sol`: the exact router encoding the front end must send, per build.
- `DexTrustTests.sol`: tests of what the DEX's owner can do, which differ per DEX.

Forge compiles only what `src/`, `test/` and `script/` reach, so each build sees one variant. `forge test` runs v4;
`FOUNDRY_PROFILE=infinity forge test` runs Infinity; the same test files run on both. The differences that matter:

| | Uniswap v4 | PancakeSwap Infinity |
| --- | --- | --- |
| Settlement | on the PoolManager (`unlock`) | on the Vault (`lock`) |
| Hook permissions | bits in the hook's address, salt mined at deploy | `getHooksRegistrationBitmap`, repeated in the pool key's `parameters` |
| ERC-6909 ids | `currency.toId()` | the currency |
| Owner powers | protocol fee up to 0.1% per direction | pause of swaps and liquidity; protocol fee up to 0.4% per direction |
| Permit2 | Uniswap's canonical | PancakeSwap's own, `0x31c2...c768` |

## 3. Contracts

| Contract | Role |
| --- | --- |
| `StealthFactory` | launches tokens; future-launch config within hard caps; two-step admin |
| `StealthTokenDeployer` | holds the token implementation; deploys one EIP-1167 clone per launch with CREATE2 |
| `StealthToken` | the ERC-20: a clone whose name, metadata and terms are in its own bytecode |
| `StealthLocker` | opens and seeds each pool, runs the capped first buy, owns the liquidity forever. Deploys the hook |
| `StealthHook` | takes the tax on the quote leg in all four swap modes, sniper fee, max buy, locker-only pool creation and liquidity, no donations, graduation flag, price guard |
| `StealthFeeVault` | books every fee as ERC-6909 claims per currency; claims, sweep, skim, holders and general pots, buyback, hand-off, takeover |
| `StealthRouter` | the site's thin router: one swap per call, exact in or out, native or ERC-20, plain approval or Permit2 |

## 4. Roles

| Role | Can | Cannot |
| --- | --- | --- |
| Factory admin (Safe on mainnet) | future-launch settings within compiled caps; list quotes; pause new launches; replace distributor and creator manager; rotate the platform and marketing wallets; cancel a takeover | touch a live token, its tier, its liquidity or its launch type; change tiers or the sniper fee (constants) |
| Platform wallet | receives the platform share and launch fees | nothing else |
| Marketing wallet | receives the coin's part on the Marketing type | nothing else |
| Distributor (ops bot) | pay a Holders or Pot coin's pot to any address; spend a Buyback coin's pot on `buyback` | touch any other balance; withdraw a Buyback pot to an address |
| Creator manager | propose a takeover, with notice; the admin can cancel | take effect without the notice and the new creator's acceptance |
| Creator | claim its balance (Creator type); hand the role over | change the tier, the type or the split |
| Team wallet | claim its share | move its share to another address (see section 11) |
| Anyone | sweep to the two wallets; skim excess to the platform wallet; launch | choose where a sweep or skim pays |

The platform and marketing wallets come from the constructor (`script/Deploy.s.sol` reads them from the environment) and
must be the same addresses on all chains. No wallet address is compiled in.

**Trust assumption: the distributor holds every Holders and Pot coin's pot.** A compromised distributor can pay a Holders
or Pot pot to any address, up to all of it. Nothing on chain checks who a pot is for: the amounts and recipients are worked
out off chain and `withdrawPot` takes them as given. The nonce stops a resend, not a theft. The loss is bounded by the
pots, and by what the admin's `setDistributor` stops once it notices. A key that holds this role should be treated as
holding those balances.

## 5. Fees

### Tiers

Five tax tiers, picked at launch and locked, with no way to change them: **1.25%, 2.25%, 3.25%, 4.25%, 5.75%** of each
trade. `taxBps = 0` at launch means the default, 1.25%. Anything else reverts `InvalidTax`.

### Where the tax is taken

Always on the quote leg, in pips, rounded up (rounding never favours the trader). `f` is the rate.

| Swap | Quote is | Hook | Fee |
| --- | --- | --- | --- |
| exact-in buy | specified input | `beforeSwap` | `ceil(G·f)` of the gross input G |
| exact-out sell | specified output | `beforeSwap` | `ceil(X·f/(1-f))` on top of the net output X |
| exact-out buy | computed input | `afterSwap` | `ceil(P·f/(1-f))` on top of what the pool took |
| exact-in sell | computed output | `afterSwap` | `ceil(G·f)` of what the pool paid |

All four charge the same fraction of the gross quote leg. A price-limited exact-in buy or exact-out sell that would
stop early reverts `PartialFill`, since its fee was sized on the full amount. The first buy is the one exception (it
stops at its cap by design, and the fee is on the amount it sized).

The fee is an ERC-6909 claim minted to the fee vault during the swap. Nothing moves until the swap's own lock settles,
so the fee never depends on other pools' balances.

### The split

`StealthFeeVault.credit` books every unit of the fee, in the quote. `tier` is the coin's tier in pips, stored in its `Coin`
slot at launch, and `rate` what the hook charged:

```
coin     = fee × (tier × 70%) / rate   (70% of the tier on the trade, in all four modes, at any rate; rounded down)
platform = fee − coin                  (the rest of the tax: 30% of the tier, plus everything above the tier)
```

So every unit is booked and rounding goes to the platform. `tier × 70%` is a whole number of pips at all five tiers. The
hook's `rate` is never under the tier, so the coin's part is always below the fee; `fee × share` cannot overflow, since a
fee fits in 127 bits and the share in 16.

| Tier | Coin (70%) | Platform (30%) |
| --- | --- | --- |
| 1.25% | 0.875% | 0.375% |
| 2.25% | 1.575% | 0.675% |
| 3.25% | 2.275% | 0.975% |
| 4.25% | 2.975% | 1.275% |
| 5.75% | 4.025% | 1.725% |

All of the coin's part goes one way, by launch type. There is no marketing share on any type but `Marketing`.

| Type | Value | The coin's part goes to | Paid by |
| --- | --- | --- | --- |
| `Creator` (default) | 0 | the creator's wallet | `claimCreator` |
| `Team` | 1 | 2-10 wallets by bps, fixed at launch | each wallet's `claimCreator` |
| `Marketing` | 2 | the marketing wallet | `sweep` |
| `Holders` | 3 | a pot | distributor `withdrawPot` |
| `Buyback` | 4 | a pot | distributor `buyback` |
| `Pot` | 5 | a general pot, for launch types run off chain by the ops bot | distributor `withdrawPot` |

The values, and `Role`'s in the `Paid` event, are ABI: new ones go at the end and none ever moves. `Role.Pot` is 7.

On a Team coin a wallet's lifetime earnings are `floor(teamAccrued × bps / 10,000)`, and wallet 0 takes what that rounding
leaves, so they always sum to `teamAccrued`. A claim writes only that wallet's `memberPaid`, and swaps never touch the
wallets, so a rejecting wallet hurts only itself.

### Anti-sniper

The same line as Meteora launches on Solana: 90% in the launch's second, then
`900,000 − (900,000 − tier) × elapsed / 15` pips, one step per whole second, reaching the tier at 15 seconds. The first
buy, in the launch transaction, pays the tier. Buys and sells pay the same rate.

**Decision: the sniper surplus goes to the platform wallet.** Inside the window the coin still gets 70% of its tier on the
trade, not 70% of the rate, and the platform wallet keeps everything above it. On Solana's Meteora launches the pool's fee
is split in fixed shares, so the coin shares the surplus there. Here it does not, because a launcher must gain nothing by
sniping their own coin. A self-snipe gets back what the same trade would earn the coin at the tier, and pays the rate: at
the top tier in the window's last second, the closest it comes, it pays 11.37% and gets 4.025% back.

### Launch fee

Native, 0 by default, capped at 0.1 of the native coin, paid straight to the platform wallet in the launch.

## 6. Buyback

`buyback(token, amount, minTokensOut, deadline, nonce)`, on the fee vault.

- **Role:** the distributor only (`NotDistributor`). Rotating the distributor moves the right at once.
- **Spends only that coin's pot:** the coin must be `Buyback` type (`WrongLaunchType`) and `amount` at most its
  `coinOwed` (`AmountTooHigh`). The pot has no other way out: `withdrawPot` refuses Buyback coins.
- **Slippage:** `minTokensOut` must be non-zero (`ZeroAmount`) and the buy reverts under it (`Slippage`). `deadline` stops
  a stuck transaction running later at a stale price. The bot computes the minimum from a quote at send time.
- **Burns, not a dead address.** The vault takes the tokens and calls the token's own `burn`, so `totalSupply` falls by
  exactly what was bought. Reasons: supply on every explorer is right without a dead-address convention; nothing needs
  trusting that a dead address is dead; and no tokens sit anywhere for anyone to count.
- **Retry:** a revert changes nothing, including the nonce, so any failure can be resent as it is. `nonce` must equal
  `potNonce(token)` and moves on success, so resending a buyback that did land reverts `StaleNonce` instead of spending
  twice. The bot needs no idea whether its last transaction landed.
- **Normal trade:** the buy pays the coin's tier. The platform gets its share and the coin's part of that tax returns to
  the pot, so `potAfter` is above `pot − amount`. It respects the max buy in a limits window. It is refused in the sniper
  window (`SniperWindowOpen`), where it would pay up to 90%. The vault is exempt from the max wallet for the moment it
  holds the tokens.
- **Paid from claims:** the swap's quote comes from burning the vault's own claim, so no quote leaves the settlement
  contract, and the claims invariant holds through the buy.
- **Events:** `BuybackBurned(token, nonce, quoteSpent, tokensBurned, potAfter)`, plus the hook's `SwapFee` and the DEX's
  `Swap`, and the token's `Transfer` to the zero address.

`withdrawPot` carries the same nonce, so a resent pot payout cannot pay twice.

## 6a. Pots

`Holders`, `Buyback` and `Pot` coins keep the coin's part in `coinOwed`. A `Pot` coin's pot is general: it is for launch
types run off chain by the ops bot, and the contract does not know what any of them is for.

- Only the distributor pays a pot, with `withdrawPot` (`NotDistributor`), carrying `potNonce` (`StaleNonce`), up to
  `coinOwed` (`AmountTooHigh`). The `Paid` event carries `Role.Holders` or `Role.Pot` by the coin's type.
- `buyback` refuses a `Pot` coin (`WrongLaunchType`). Only a `Buyback` coin can use it, and it cannot use `withdrawPot`.
- `claimCreator` and `claimCreatorAmount` refuse the creator on a pot coin (`NotCreator`). A hand-off or takeover moves the
  role and not one unit of the pot, and leaves no `legacyOwed`.
- `sweep` never touches a pot.
- See the trust assumption in section 4.

## 7. Launch

`StealthFactory.launch(LaunchParams)`: name, symbol, logo, description, socials; `taxBps`; `quote`; `target`; `quoteAmount`
(ERC-20 first buy); `minTokensOut`; `configVersion` (the launch reverts if the config changed since the launcher saw it);
`creator`; `options` (`launchType`, `team`, `maxWalletBps`, `maxBuyBps`, `limitsWindow`, `firstBuyLock`).

Launch options: first buy (launcher only, same transaction, capped at 5% of supply,
pays the tier, excess refunded, `minTokensOut`); max wallet 0.5-5% and max buy per transaction 0.1-5% for up to 60 minutes;
first-buy lock up to 90 days; ERC-20 quote transfer checks; takeovers and hand-offs.

## 8. Gas

Launch cost is the constraint: HyperEVM's small blocks have a 3M limit, and were 2M recently. See section 12 for numbers.
What keeps it down:

- **Clones.** A token is a 45-byte EIP-1167 proxy plus its own data, instead of about 8 KB of code.
- **Metadata in the clone's bytecode**, at 200 gas per byte, instead of storage at 690 gas per byte, in a compact encoding
  (2-byte lengths). The addresses every token shares are immutables of the one implementation.
- **The supply is minted straight into the settlement contract**, for exactly what the positions took. No mint to the
  locker, no transfer, no dust burn.
- **One slot per launch in the locker** (the target). Everything else in `PoolInfo` follows from it, or lives in the hook,
  the token or the vault; `getPool` and `progress` work it out when read.
- **Two slots in the hook, one in the vault** (nothing else for a native Creator launch; no team arrays). The vault's `Coin`
  packs the creator (20 bytes), launch type (1) and tier (2) into one word, with 9 bytes free. The tier adds no write to a
  launch and no cold read to a swap, which reads that word anyway.
- **Packed books**: platform and marketing share one slot, which saves a first buy a write and a swap about 5k.

A clone costs each token transfer a `DELEGATECALL`: about 2,700 gas the first time in a transaction. `_update` reads its
terms from its own code and touches no extra storage unless the token has a max wallet or a first-buy lock.

The worst case is bounded too, since a launch that only sometimes fits a block is a launch that sometimes fails: all
metadata at its limit, a 10-wallet team, both limits, a lock, and a first buy in an ERC-20.

## 10. Guarantees (tested on both builds)

The vault's claim equals the sum owed per currency, to the unit; no Stealth contract
holds Stealth tokens after a transaction; the locker and hook hold no funds or claims; both locked positions are
unchanged and no other liquidity exists; the price never passes the launch price; the DEX's quoter equals the fill in all
four modes; credited minus paid equals owed per token and role; the fee equals `ceil(rate × gross quote leg)`.

New: the split is exact for every tier, type and swap mode; the coin gets 70% of its tier and no more in every second of the
sniper window, so a self-snipe always loses money; the coin's part never exceeds the fee; paying every role leaves the
vault with exactly nothing; team earnings sum to `teamAccrued`; a pot pays only through its own path; `totalSupply` only
falls, by exactly what was burned.

## 11. Open risks, for the audit

- **New code.** The clone, the clone-data encoding and the buyback path are new on both builds.
- **Distributor.** It can pay a Holders or Pot pot to any address (section 4), and can spend a Buyback pot at a bad price (a
  compromised bot can set a 1-wei minimum and sandwich itself). Bounded by the pots, but not prevented. Consider a Safe, per-call caps or an on-chain price bound.
- **The launcher's own trades are cheap.** Whoever holds the coin's part gets 70% of the tier back on its own trades,
  first buy included, so wash volume and a first buy cost 30% of the tier. Flipping the one-way `graduated` flag with a
  round trip on a 1.25% coin costs about 0.76% of the target. `graduated` moves no money on chain, but nothing
  off chain should treat it, or volume, as proof of demand.
- **Max buy and big pots.** In a limits window a Buyback pot can be larger than one transaction may buy. The buy reverts
  `MaxBuyExceeded`, changing nothing, and the bot retries smaller.
- **Admin rotating wallets** redirects future sweeps of the platform and marketing shares, unpaid balances included. Use a
  Safe. It can no longer freeze creators: claims do not touch those wallets.
- **Team wallets cannot rotate.** A lost or compromised team wallet keeps its share for good.
- **`uint128` books.** A token's unpaid platform or marketing share, and their lifetime sums, revert past 2^128 raw units.
  No listed quote gets near it, but an unlisted quote with an absurd supply could freeze its own pool's swaps.
- **Scanners read clones as proxies.** Token-risk tools may flag `is_proxy`. It is not upgradeable, but expect to explain it.
- **The creator-manager takeover** is unchanged and is real power under notice.
- **Tax-free side pools**: anyone can open a plain pool for a Stealth token without the hook.
- **Max wallet** does not see tokens held as ERC-6909 claims; max buy does.
- **Quote tokens** that rebase, pause, blacklist or upgrade after launch. Contained per token and currency. Mainnet ships
  with `unlistedQuotesAllowed = false`.
- **DEX owners**: section 2. A protocol fee changes the pool's cut, not the hook's books, and `quoteLaunchBuy` assumes 0.
- **Arc's gas coin is USDC.** Native USDC has 18 decimals and its ERC-20 face (`0x3600000000000000000000000000000000000000`) has 6, on one balance. Pools pair with the native side, so targets are USD-sized numbers of 18-decimal units. Never list the ERC-20 face as a quote: it would be the same money under a second currency and a third of the decimals. Circle can block an address, which stops native USDC too.
- **Sequencer timestamps** decide the sniper steps and windows. On Robinhood Chain the sequencer sets them.
- **HyperEVM** deploys need big blocks. Launches were measured against bytecode identical to Robinhood's, not on HyperEVM.
- **Team and metadata calldata** on rollups pays for L1 data on top of the L2 gas here, on Robinhood Chain.
- **`_paid` lifetime sums** cannot be cleared: past 2^128 raw units a sweep reverts for that token for good.
- **`StealthRouter` takes any pool key**, Stealth hook or not. It only pulls from `msg.sender`. Reviewed by reading, not tested.
- **The max buy counts per transaction in transient storage.** Forge's default test mode is one long transaction, so its
  test runs isolated.
- **Router encoding.** The Universal Routers on Robinhood Chain and HyperEVM read six-field swap params
  (`minHopPriceX36`). A five-field encoding only works on native pairs, by luck. The front
  end must send `variants/v4/UniversalRouterLib.sol`'s encoding.

## 12. Gas, measured

Launches are the gas each transaction would use against the production DEX bytecode, intrinsic gas, calldata and refunds
included: simulated by `forge script` against a local anvil, without `--broadcast`, so nothing was sent. Nothing here was measured on a live chain.


| Launch | Uniswap v4 | Infinity |
| --- | --- | --- |
| No first buy | 668,919 | 798,599 |
| With first buy | **862,340** | 1,021,383 |
| With first buy, Buyback type | 828,152 | 970,095 |
| Worst case: all metadata at its limit, 10-wallet team, limits, lock, ERC-20 first buy | **1,892,122** | 2,070,646 |

The worst case on the v4 build uses 63% of HyperEVM's 3M limit, with 37% to spare. The stricter 2.0M target is met with 57% to
spare on an ordinary launch and 5% on the worst case. The limit forge's coarse search settled on for the worst case was 2.13M: enough, but not the minimum. It is under 3M too; a 2M
block would need the real limit checked on the chain. The worst case scales with metadata at about 260 gas per byte (code, calldata, hashing), so lowering the limits buys margin. The limits
match Solana's form (description 1000, socials 256 each). BNB Chain has no small blocks, so the Infinity worst case above 2M
does not matter there.

Other actions, each its own cold transaction (`forge test --isolate --match-path test/gas/Gas.t.sol -vv`). Swaps through
`TestRouter` or `StealthRouter`; the Universal Router differs a little.

| Action | Uniswap v4 | Infinity |
| --- | --- | --- |
| Buy, exact in, first swap of the pool's steady state | 180,721 | 205,083 |
| Buy, exact in, `StealthRouter` | 170,862 | 194,733 |
| Buy, exact out | 156,726 | 180,766 |
| Sell, exact in | 161,426 | 185,382 |
| Sell, exact in, `StealthRouter` | 156,950 | 180,675 |
| Sell, exact out | 157,586 | 181,419 |
| Buy that graduates | 240,213 | 266,188 |
| Buyback | 199,986 | 223,245 |
| `claimCreator` | 88,379 | 88,777 |
| `sweep`, one token, Creator coin (platform only) | 84,875 | 85,273 |
| `sweep`, five tokens, Creator coins | 217,615 | 218,013 |
