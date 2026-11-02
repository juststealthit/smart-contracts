# Licenses

Everything in `evm/src`, `evm/variants`, `evm/script`, `evm/test`, `evm/model`, `solana/`, `docs/` and `assets/` is MIT, as in [LICENSE](LICENSE).

`evm/lib` is vendored third-party code, and each folder keeps its own license:

| Folder | License |
| --- | --- |
| `openzeppelin-contracts` | MIT |
| `forge-std` | MIT or Apache-2.0 |
| `v4-core` | Per file: MIT, or BUSL-1.1 for the core pool files (see `licenses/`) |
| `v4-periphery` | MIT |
| `infinity-core` | Per file: MIT or GPL-2.0-or-later |
| `infinity-periphery` | GPL-2.0-or-later |
| `solmate` | Per file: AGPL-3.0-only or MIT |

What ends up in the deployed contracts:

- **Uniswap v4 build** (Robinhood Chain, HyperEVM, Base, Arc): MIT code only.
- **PancakeSwap Infinity build** (BNB Chain): also includes `FullMath`, `SqrtPriceMath`, `SwapMath`, `TickMath` and `LiquidityAmounts` from PancakeSwap, under GPL-2.0-or-later. That build as a whole is therefore covered by GPL-2.0-or-later, and this repository is its source.

The BUSL-1.1 files in `v4-core` and the solmate files are used by the tests only, not by any deployed contract.
