#!/usr/bin/env python3
"""Download the full HuggingFace snapshot for the miner's resolved model.

vLLM only fetches weight shards; Verathos later needs the complete repo
snapshot (README, LICENSE, configuration.json, etc.) with local_files_only=True.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


def _chain_config_for_network(network: str) -> str | None:
    repo = Path(__file__).resolve().parents[1]
    name = "chain_config_mainnet.json" if network == "finney" else "chain_config_testnet.json"
    path = repo / name
    return str(path) if path.is_file() else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-id", default=os.environ.get("MODEL_ID", "auto"))
    parser.add_argument("--network", default=os.environ.get("NETWORK", "finney"))
    args = parser.parse_args()

    auto = str(args.model_id).lower() in {"", "auto"}
    chain_config = _chain_config_for_network(args.network)

    from neurons.model_resolve import resolve_model_config
    from huggingface_hub import snapshot_download

    resolved = resolve_model_config(
        model_id=None if auto else args.model_id,
        auto=auto,
        chain_config=chain_config,
        subtensor_network=args.network,
    )
    hf_id = resolved.model_id
    print(f"Prefetching HuggingFace snapshot: {hf_id}")
    path = snapshot_download(hf_id)
    print(f"OK: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
