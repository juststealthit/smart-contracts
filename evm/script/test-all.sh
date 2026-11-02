#!/usr/bin/env bash
# Every local test on both builds.
set -euo pipefail
cd "$(dirname "$0")/.."
forge test "$@"
FOUNDRY_PROFILE=infinity forge test "$@"
