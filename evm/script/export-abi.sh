#!/usr/bin/env bash
# ABIs for the front end and the indexer, per build, into abi/<build>/.
set -euo pipefail
cd "$(dirname "$0")/.."
for build in v4 infinity; do
  mkdir -p "abi/$build"
  for c in StealthFactory StealthFeeVault StealthHook StealthLocker StealthRouter StealthToken StealthTokenDeployer; do
    python3 -c "import json,sys;print(json.dumps(json.load(open('out/$build/$c.sol/$c.json'))['abi'],indent=1))" > "abi/$build/$c.json"
  done
done
