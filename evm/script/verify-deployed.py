#!/usr/bin/env python3
"""Checks that the code on each chain is this source.

Run `forge build` and `FOUNDRY_PROFILE=infinity forge build` first, then this from evm/. It needs `cast` and reads public RPCs.
Immutables are constructor values, which the compiler leaves blank, so those bytes are ignored on both sides. Everything else,
the metadata hash included, has to be equal.
"""

import json
import subprocess
import sys

RPCS = {
    4663: "https://rpc.mainnet.chain.robinhood.com",
    56: "https://bsc-dataseed.bnbchain.org",
    999: "https://rpc.hyperliquid.xyz/evm",
    8453: "https://mainnet.base.org",
    5042: "https://rpc.mainnet.arc.io",
}
NAMES = {
    "factory": "StealthFactory",
    "tokenDeployer": "StealthTokenDeployer",
    "tokenImplementation": "StealthToken",
    "locker": "StealthLocker",
    "hook": "StealthHook",
    "feeVault": "StealthFeeVault",
    "router": "StealthRouter",
}


def masked(code: str, refs: dict) -> bytes:
    b = bytearray.fromhex(code.removeprefix("0x"))
    for spots in refs.values():
        for s in spots:
            b[s["start"] : s["start"] + s["length"]] = bytes(s["length"])
    return bytes(b)


bad = 0
for chain, rpc in RPCS.items():
    deployed = json.load(open(f"deployments/{chain}.json"))
    build = "infinity" if chain == 56 else "v4"
    for key, name in NAMES.items():
        art = json.load(open(f"out/{build}/{name}.sol/{name}.json"))["deployedBytecode"]
        live = subprocess.run(["cast", "code", deployed[key], "--rpc-url", rpc], capture_output=True, text=True, timeout=60).stdout.strip()
        refs = art.get("immutableReferences", {})
        ok = len(live) == len(art["object"]) and masked(live, refs) == masked(art["object"], refs)
        bad += not ok
        print(f"{chain:<6}{name:<22}{deployed[key]}  {'match' if ok else 'DIFFERENT'}")
sys.exit(1 if bad else 0)
