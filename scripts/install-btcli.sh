#!/bin/bash
# Install bittensor-cli (btcli) in an isolated venv — safe alongside .venv-vllm.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$REPO/.venv-btcli"

echo ""
echo "Installing btcli into $VENV ..."
python3 -m venv "$VENV"
"$VENV/bin/pip" install -q -U pip
"$VENV/bin/pip" install -q bittensor-cli

echo ""
"$VENV/bin/btcli" --version
echo ""
echo "Use btcli via:"
echo "  ./scripts/btcli.sh <command>"
echo "  ./miner btcli <command>"
echo ""
echo "Example — register on subnet 96:"
echo "  ./miner btcli subnet register --wallet.name sn59_babelbit3 --hotkey hk_0 --netuid 96 --subtensor.network finney"
