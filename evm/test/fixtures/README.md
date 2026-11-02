Runtime bytecode the local tests place at the real addresses, so immutables line up and the tests run the code that is
live, not the repos. Fetched read-only with `cast code` from public RPCs.

| File | Address | Source |
| --- | --- | --- |
| PoolManager.robinhood.hex | 0x8366a39CC670B4001A1121B8F6A443A643e40951 | Robinhood Chain 4663, identical to live on 2026-10-30 (v4-core v4.0.0). HyperEVM's PoolManager differs only in its own address (the NoDelegateCall immutable), checked byte for byte the same day |
| UniversalRouter.robinhood.hex | 0x8876789976dEcBfCbBbe364623C63652db8C0904 | Robinhood Chain 4663, fetched 2026-10-30 |
| V4Quoter.robinhood.hex | 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94 | Robinhood Chain 4663, fetched 2026-10-30 |
| Permit2.robinhood.hex | 0x000000000022D473030F116dDEE9F6B43aC78BA3 | Robinhood Chain 4663, fetched 2026-10-30 |
| Vault.bsc.hex | 0x238a358808379702088667322f80aC48bAd5e6c4 | BSC 56: infinity-core 3891d0c, byte-identical |
| CLPoolManager.bsc.hex | 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b | BSC 56: infinity-core 3891d0c, byte-identical (immutables masked) |
| CLQuoter.bsc.hex | 0xd0737C9762912dD34c3271197E362Aa736Df0926 | BSC 56: infinity-periphery b22d04b, byte-identical (immutables masked) |
| UniversalRouter.bsc.hex | 0xd9C500DfF816a1Da21A48A732d3498Bf09dc9AEB | BSC 56: infinity-universal-router (deployed build) |
| Permit2.bsc.hex | 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768 | BSC 56: PancakeSwap's Permit2 |
