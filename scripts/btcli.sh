#!/bin/bash
# Run btcli without conflicting with the miner (.venv-vllm) dependencies.
# Usage:  ./scripts/btcli.sh wallet overview --wallet.name sn59_babelbit3
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$REPO/.venv-btcli"

if [ ! -x "$VENV/bin/btcli" ]; then
    echo "btcli not installed. Run:  ./scripts/install-btcli.sh"
    exit 1
fi
exec "$VENV/bin/btcli" "$@"
