#!/usr/bin/env bash
# Show EVM wallet balance derived from a Bittensor hotkey.
#
# Usage:
#   ./scripts/miner-evm-balance.sh [--wallet NAME] [--hotkey NAME]
#
# Defaults: WALLET_NAME / HOTKEY_NAME from miner.conf
# Example:
#   ./scripts/miner-evm-balance.sh --hotkey hk_0

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/miner-endpoint.sh" balance "$@"
