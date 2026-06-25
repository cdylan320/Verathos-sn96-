#!/bin/bash
# Fix scalecodec/cyscale conflict in .venv-vllm (breaks: import bittensor).
#
# Cause: installing bittensor-cli into .venv-vllm pulls async-substrate-interface 2.x
# and scalecodec, which conflicts with bittensor 10.x + cyscale.
#
# Usage:  bash scripts/fix-miner-venv.sh
#         ./miner fix-venv
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$REPO/.venv-vllm/bin/python"

if [ ! -x "$VENV" ]; then
    echo "ERROR: $VENV not found. Run ./miner install first."
    exit 1
fi

echo ""
echo "============================================================"
echo "  Fixing miner Python environment (.venv-vllm)"
echo "============================================================"
echo ""

echo "  1/4 Removing conflicting packages..."
"$VENV" -m pip uninstall -y scalecodec cyscale 2>/dev/null || true

echo "  2/4 Reinstalling cyscale..."
"$VENV" -m pip install --no-cache-dir cyscale --force-reinstall 2>&1 | tail -3

echo "  3/4 Pinning async-substrate-interface <2 (required by bittensor 10.x)..."
"$VENV" -m pip install --no-cache-dir 'async-substrate-interface>=1.6,<2' 2>&1 | tail -3

echo "  4/4 Verifying bittensor import..."
"$VENV" -c "import bittensor as bt; print('  OK: bittensor', getattr(bt, '__version__', '?'))"

echo ""
echo "============================================================"
echo "  Fixed. Restart miner:"
echo "    pm2 delete miner 2>/dev/null; ./miner start"
echo ""
echo "  For btcli, use the ISOLATED venv (never pip install into .venv-vllm):"
echo "    ./miner btcli --version"
echo "    bash scripts/install-btcli.sh"
echo "============================================================"
echo ""
