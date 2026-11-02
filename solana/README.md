# Solana configs

Just Stealth It has no program of its own on Solana. Coins launch on Pump.fun, Raydium LaunchLab and Meteora, through these public configs. All of them were checked on mainnet.

| File | What it holds |
| --- | --- |
| [`raydium-platforms.json`](raydium-platforms.json) | The five LaunchLab platforms, one per tax tier |
| [`meteora-configs.json`](meteora-configs.json) | The 20 shared Meteora configs on the 1.25% tier |
| [`lookup-table.json`](lookup-table.json) | The address lookup table launches share |

## Programs

| Venue | Program |
| --- | --- |
| Pump.fun | [`6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P`](https://solscan.io/account/6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P) |
| PumpSwap | [`pAMMBay6oceH9fJKBRHGP5D4bD4sWpmSwMn52FMfXEA`](https://solscan.io/account/pAMMBay6oceH9fJKBRHGP5D4bD4sWpmSwMn52FMfXEA) |
| Raydium LaunchLab | [`LanMV9sAd7wArD4vJFi2qDdfnVhFxYSUg6eADduJ3uj`](https://solscan.io/account/LanMV9sAd7wArD4vJFi2qDdfnVhFxYSUg6eADduJ3uj) |
| Raydium CPMM | [`CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C`](https://solscan.io/account/CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C) |
| Meteora DBC | [`dbcij3LWUppWqq96dh6gJWwBifmcGfLSB5D4DuSMaqN`](https://solscan.io/account/dbcij3LWUppWqq96dh6gJWwBifmcGfLSB5D4DuSMaqN) |
| Meteora DAMM v2 | [`cpamdpZCGKUy5JxQXB4dcpGPiikHawvSWAd6mEn1sGG`](https://solscan.io/account/cpamdpZCGKUy5JxQXB4dcpGPiikHawvSWAd6mEn1sGG) |

## Raydium LaunchLab

Each tax tier is its own platform, because the platform holds the rate. The coin's creator fee is capped at 0.5% on the curve, so higher tiers add only to the platform's part. The rates below were read from the accounts on chain.

| Tier | Raydium | Platform | Coin | Graduates to CPMM config |
| --- | --- | --- | --- | --- |
| 1.25% | 0.25% | 0.50% | 0.50% | 0.75% LP + 0.5% coin |
| 2.25% | 0.25% | 1.50% | 0.50% | 0.7% LP + 0.8% coin |
| 3.25% | 0.25% | 2.50% | 0.50% | 0.7% LP + 0.8% coin |
| 4.25% | 0.25% | 3.50% | 0.50% | 0.7% LP + 0.8% coin |
| 5.75% | 0.25% | 5.00% | 0.50% | 0.7% LP + 0.8% coin |

Every coin has 1B tokens with 6 decimals. 793.1M sell on the curve, and the LP is locked at graduation.

## Meteora

A Dynamic Bonding Curve config holds one quote mint and one rate, so each pair on the 1.25% tier has a shared config. Configs can't be changed once made. Any other pair or rate makes its own config at launch, which costs the launcher about 0.006 SOL.

Every config has:

- 1B tokens with 6 decimals, and fees collected in the pair token
- Meteora's 20% of the pool fee, then 70 / 30 between the coin and the platform
- An anti-sniper fee of 90%, stepping down each second for 15 seconds
- A first bundled buy at the tier
- Migration to a DAMM v2 pool with its fee capped at 10% and the LP locked

`targetUnits` in the file is the raise in whole pair tokens. On volatile pairs that target drifts from its dollar value over time.

| Pair | Raise | Config |
| --- | --- | --- |
| SOL | 85 | `D28DJbYAeZGQfdiTEa8L4Bso71RmYJ4STmE8o47P6XCE` |
| USDC | 8,000 | `57HfLa2MPz3YLV4UN7QFqMtgZ5aUQkTAVgP3BETXknGv` |
| USDT | 8,000 | `J9MjcaNQ2rUm9eLaG8MtWsgXJFFrupASN8fz5c9YjuhR` |
| USD1 | 8,000 | `321scyzh41gkLjz5JfAdLsBCxHq8FSZ2nyGiWWmDCbXG` |

The other 16 are in [`meteora-configs.json`](meteora-configs.json).

## Pump.fun

No config to publish. Pump.fun sets its own fee. Every launch locks the creator fee's split on chain, 70% to the coin's escrow and 30% to the platform, with the sharing config's admin revoked.

## What's enforced where

On Solana, only Pump.fun's split is locked by a program. On Raydium and Meteora, the coin's creator is an escrow, and Just Stealth It's bot claims from it and applies the launch type stored with the coin. That's a trust assumption, unlike the EVM contracts, where the split is in the code.
