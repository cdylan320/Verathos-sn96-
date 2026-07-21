#!/usr/bin/env bash
# List active on-chain model indices for a hotkey's EVM wallet, or updateEndpoint.
#
# Usage:
#   ./scripts/miner-endpoint.sh list [--wallet NAME] [--hotkey NAME] [--all]
#   ./scripts/miner-endpoint.sh update --index N --endpoint URL [--wallet NAME] [--hotkey NAME] [--renew]
#
# Defaults: wallet/hotkey/endpoint from miner.conf when present.
# Examples:
#   ./scripts/miner-endpoint.sh list --hotkey hk_0
#   ./scripts/miner-endpoint.sh list --hotkey hk_0 --all
#   ./scripts/miner-endpoint.sh update --hotkey hk_0 --index 61 \
#       --endpoint https://n1.de.clorecloud.net:2687 --renew

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MINER_CONF="${MINER_CONF:-$REPO_ROOT/miner.conf}"

WALLET=""
HOTKEY=""
INDEX=""
ENDPOINT=""
SHOW_ALL=0
DO_RENEW=0
ASSUME_YES=0
RPC_URL="${VERATHOS_RPC_URL:-https://lite.chain.opentensor.ai}"
CHAIN_CONFIG="${VERATHOS_CHAIN_CONFIG:-$REPO_ROOT/chain_config_mainnet.json}"

die() { echo "error: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Manage on-chain model slots for a hotkey's EVM wallet.

Usage:
  ./scripts/miner-endpoint.sh list [--wallet NAME] [--hotkey NAME] [--all]
  ./scripts/miner-endpoint.sh balance [--wallet NAME] [--hotkey NAME]
  ./scripts/miner-endpoint.sh update --index N --endpoint URL [--wallet NAME] [--hotkey NAME] [--renew]
  ./scripts/miner-endpoint.sh deactivate --index N [--wallet NAME] [--hotkey NAME] [--yes]
  ./scripts/miner-endpoint.sh cleanup --index N [--wallet NAME] [--hotkey NAME] [--yes]

Defaults: wallet/hotkey from miner.conf when present.
Probation/score from https://api.verathos.ai/v1/network/stats (best-effort).

cleanup  — remove slot only if expired > 30 days. Uses gas (storage refund may
           lower net cost). Removes from chain array → drops off dashboard.
deactivate — mark inactive now (ACTIVE/probation slots). Uses gas. Hides from
           discovery/dashboard while lease would still be running. Does NOT
           clear probation history for that index.

Examples:
  ./scripts/miner-endpoint.sh list --hotkey hk_0
  ./scripts/miner-endpoint.sh balance --hotkey hk_0
  ./scripts/miner-endpoint.sh deactivate --hotkey hk_0 --index 54 --yes
  ./scripts/miner-endpoint.sh cleanup --hotkey hk_0 --index 0 --yes
EOF
    exit "${1:-0}"
}

load_conf_defaults() {
    if [ -f "$MINER_CONF" ]; then
        # shellcheck source=/dev/null
        source "$MINER_CONF"
        WALLET="${WALLET:-${WALLET_NAME:-}}"
        HOTKEY="${HOTKEY:-${HOTKEY_NAME:-}}"
    fi
}

CMD="${1:-}"
[ -n "$CMD" ] || usage 1
shift || true

case "$CMD" in
    -h|--help|help) usage 0 ;;
    list|update|balance|cleanup|deactivate) ;;
    *) die "unknown command: $CMD (use list|balance|update|deactivate|cleanup)" ;;
esac

load_conf_defaults

while [ $# -gt 0 ]; do
    case "$1" in
        --wallet) WALLET="${2:-}"; shift 2 ;;
        --hotkey) HOTKEY="${2:-}"; shift 2 ;;
        --index) INDEX="${2:-}"; shift 2 ;;
        --endpoint) ENDPOINT="${2:-}"; shift 2 ;;
        --all) SHOW_ALL=1; shift ;;
        --renew) DO_RENEW=1; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --rpc-url) RPC_URL="${2:-}"; shift 2 ;;
        --chain-config) CHAIN_CONFIG="${2:-}"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) die "unknown flag: $1" ;;
    esac
done

[ -n "$WALLET" ] || die "wallet required (--wallet or miner.conf WALLET_NAME)"
[ -n "$HOTKEY" ] || die "hotkey required (--hotkey or miner.conf HOTKEY_NAME)"
[ -f "$CHAIN_CONFIG" ] || die "chain config not found: $CHAIN_CONFIG"

PYTHON=""
for candidate in \
    "$REPO_ROOT/.venv-vllm/bin/python" \
    "$REPO_ROOT/.venv/bin/python" \
    "$(command -v python3 || true)"
do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        PYTHON="$candidate"
        break
    fi
done
[ -n "$PYTHON" ] || die "python not found (expected .venv-vllm)"

export VERATHOS_REPO_ROOT="$REPO_ROOT"
export VERATHOS_WALLET="$WALLET"
export VERATHOS_HOTKEY="$HOTKEY"
export VERATHOS_RPC_URL="$RPC_URL"
export VERATHOS_CHAIN_CONFIG="$CHAIN_CONFIG"
export VERATHOS_CMD="$CMD"
export VERATHOS_INDEX="${INDEX:-}"
export VERATHOS_ENDPOINT="${ENDPOINT:-}"
export VERATHOS_SHOW_ALL="$SHOW_ALL"
export VERATHOS_DO_RENEW="$DO_RENEW"
export VERATHOS_ASSUME_YES="$ASSUME_YES"

cd "$REPO_ROOT"
exec "$PYTHON" - <<'PY'
from __future__ import annotations

import os
import sys
import time

REPO = os.environ["VERATHOS_REPO_ROOT"]
if REPO not in sys.path:
    sys.path.insert(0, REPO)

import bittensor as bt
from neurons.miner import _extract_hotkey_seed
from verallm.chain.config import ChainConfig
from verallm.chain.miner_registry import MinerRegistryClient
from verallm.chain.wallet import derive_evm_address, derive_evm_private_key

wallet_name = os.environ["VERATHOS_WALLET"]
hotkey_name = os.environ["VERATHOS_HOTKEY"]
cmd = os.environ["VERATHOS_CMD"]
show_all = os.environ.get("VERATHOS_SHOW_ALL", "0") == "1"
do_renew = os.environ.get("VERATHOS_DO_RENEW", "0") == "1"
assume_yes = os.environ.get("VERATHOS_ASSUME_YES", "0") == "1"
index_s = os.environ.get("VERATHOS_INDEX", "").strip()
new_endpoint = os.environ.get("VERATHOS_ENDPOINT", "").strip()
rpc_url = os.environ["VERATHOS_RPC_URL"]
chain_config = os.environ["VERATHOS_CHAIN_CONFIG"]
CLEANUP_GRACE_SEC = 30 * 24 * 3600


def fail(msg: str, code: int = 1) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def confirm(msg: str) -> None:
    if assume_yes:
        return
    ans = input(f"{msg} [y/N] ").strip().lower()
    if ans not in ("y", "yes"):
        fail("aborted", 0)


def fetch_proxy_by_index(address: str) -> dict[int, dict]:
    """Map model_index -> proxy stats (probation/score/healthy). Best-effort."""
    out: dict[int, dict] = {}
    try:
        from neurons.network import fetch_stats
        data = fetch_stats()
    except Exception as e:
        print(f"probation: unavailable ({e})", file=sys.stderr)
        return out
    addr = address.lower()
    for m in data.get("miners", []):
        if (m.get("address") or "").lower() != addr:
            continue
        idx = m.get("model_index")
        if idx is None:
            continue
        out[int(idx)] = m
    return out


wallet = bt.Wallet(name=wallet_name, hotkey=hotkey_name)
seed = _extract_hotkey_seed(wallet_name, hotkey_name, wallet)
evm_addr = derive_evm_address(seed)
evm_pk = derive_evm_private_key(seed)

cfg = ChainConfig.from_json(chain_config, rpc_url=rpc_url)
client = MinerRegistryClient(cfg)

try:
    uid = client.get_associated_uid(evm_addr)
except Exception:
    uid = None

bal = client._provider.w3.eth.get_balance(evm_addr) / 1e18
models = client.get_miner_models(evm_addr)
now = int(time.time())
proxy = fetch_proxy_by_index(evm_addr)


def status_of(m):
    if m.active and m.expires_at > now:
        return "ACTIVE"
    if m.active:
        return "EXPIRED"
    return "INACTIVE"


def proxy_cols(i: int) -> tuple[str, str, str]:
    p = proxy.get(i)
    if not p:
        return ("?", "?", "?")
    prob = "YES" if p.get("on_probation") else "no"
    healthy = "ok" if p.get("healthy") else "down"
    score = p.get("score")
    score_s = f"{float(score):.3f}" if score is not None else "?"
    return (prob, healthy, score_s)


print(f"wallet={wallet_name} hotkey={hotkey_name}")
print(f"evm={evm_addr} uid={uid} balance={bal:.6f} TAO slots={len(models)}")

if cmd == "balance":
    # Compact one-liner friendly output after the header above.
    print(f"balance_tao={bal:.6f}")
    print(f"balance_rao={int(bal * 1e9)}")
    if bal < 0.005:
        print("warning: low balance — renewModel/register/updateEndpoint may fail")
    raise SystemExit(0)

if cmd == "list":
    rows = []
    for i, m in enumerate(models):
        st = status_of(m)
        if not show_all and st != "ACTIVE":
            continue
        rem_h = (m.expires_at - now) / 3600
        rows.append((i, st, rem_h, m))
    if not rows:
        print("no matching slots" + ("" if show_all else " (try --all)"))
        raise SystemExit(0)
    print(
        f"{'idx':>4} {'status':8} {'rem_h':>8} {'prob':>4} {'hlth':>4} "
        f"{'score':>6} {'quant':6} {'ctx':>7} endpoint"
    )
    for i, st, rem_h, m in rows:
        prob, healthy, score_s = proxy_cols(i)
        print(
            f"{i:4d} {st:8} {rem_h:+8.1f} {prob:>4} {healthy:>4} "
            f"{score_s:>6} {m.quant:6} {m.max_context_len:7d} {m.endpoint}"
        )
        print(f"     model={m.model_id}")
    n_prob = sum(1 for i, *_ in rows if proxy.get(i, {}).get("on_probation"))
    print(f"probation_slots={n_prob} (from api.verathos.ai; ? = not in proxy view)")
    raise SystemExit(0)


def require_index() -> int:
    if not index_s.isdigit():
        fail("--index N required")
    idx = int(index_s)
    if idx < 0 or idx >= len(models):
        fail(f"index {idx} out of range (0..{len(models)-1})")
    return idx


if cmd == "deactivate":
    index = require_index()
    m = models[index]
    st = status_of(m)
    prob, healthy, score_s = proxy_cols(index)
    print(f"deactivate idx={index} status={st} rem_h={(m.expires_at-now)/3600:+.2f}")
    print(f"probation={prob} healthy={healthy} score={score_s}")
    print(f"model={m.model_id} endpoint={m.endpoint}")
    print("note: uses gas; hides from dashboard/discovery; does not clear probation")
    if st != "ACTIVE" and not m.active:
        print("already inactive")
        raise SystemExit(0)
    confirm(f"deactivate index {index}?")
    tx = client.deactivate_model(index, private_key=evm_pk)
    print(f"deactivateModel tx={tx}")
    time.sleep(6)
    client._cache._store.clear()
    m = client.get_miner_models(evm_addr)[index]
    print(f"after: active={m.active} status={status_of(m)}")
    print(f"balance={client._provider.w3.eth.get_balance(evm_addr)/1e18:.6f} TAO")
    print("OK")
    raise SystemExit(0)

if cmd == "cleanup":
    index = require_index()
    m = models[index]
    st = status_of(m)
    rem_h = (m.expires_at - now) / 3600
    eligible_at = m.expires_at + CLEANUP_GRACE_SEC
    days_left = (eligible_at - now) / (24 * 3600)
    print(f"cleanup idx={index} status={st} rem_h={rem_h:+.2f}")
    print(f"model={m.model_id} endpoint={m.endpoint}")
    print("note: uses gas (storage refund may reduce net cost); removes array slot")
    if now < eligible_at:
        fail(
            f"not eligible yet — need expiresAt+30d "
            f"(~{days_left:.1f} days left). For ACTIVE/probation use: "
            f"deactivate --index {index}"
        )
    confirm(f"cleanup (delete) index {index}? swap-and-pop may move last slot into {index}")
    tx = client.cleanup(evm_addr, index, private_key=evm_pk)
    print(f"cleanup tx={tx}")
    time.sleep(6)
    client._cache._store.clear()
    left = client.get_miner_model_count(evm_addr)
    print(f"after: slots={left}")
    print(f"balance={client._provider.w3.eth.get_balance(evm_addr)/1e18:.6f} TAO")
    print("OK")
    raise SystemExit(0)

# update
index = require_index()
if not new_endpoint:
    fail("--endpoint URL required for update")

m = models[index]
st = status_of(m)
prob, healthy, score_s = proxy_cols(index)
print(f"before: idx={index} status={st} rem_h={(m.expires_at-now)/3600:+.2f}")
print(f"before: probation={prob} healthy={healthy} score={score_s}")
print(f"before: model={m.model_id} quant={m.quant} ctx={m.max_context_len}")
print(f"before: endpoint={m.endpoint}")
print(f"after : endpoint={new_endpoint}")
if st != "ACTIVE":
    print(
        "note: slot is not ACTIVE — updateEndpoint allowed, but renewModel "
        "will fail; miner registerModel can reactivate this index if "
        "modelId+endpoint+quant match after the URL change. Probation sticks to the index."
    )
if prob == "YES":
    print("warning: this index is on probation — updateEndpoint keeps that index/probation")

if m.endpoint == new_endpoint:
    print("endpoint already set — nothing to update")
else:
    print(f"calling updateEndpoint({index}, {new_endpoint}) ...")
    tx = client.update_endpoint(index, new_endpoint, private_key=evm_pk)
    print(f"updateEndpoint tx={tx}")

if do_renew:
    # renew only works while lease not fully expired
    client._cache._store.clear()
    models = client.get_miner_models(evm_addr)
    m2 = models[index]
    if m2.expires_at <= int(time.time()):
        fail("lease already expired — cannot renew; re-register instead")
    print(f"calling renewModel({index}) ...")
    tx2 = client.renew_model(index, private_key=evm_pk)
    print(f"renewModel tx={tx2}")

time.sleep(6)
client._cache._store.clear()
models = client.get_miner_models(evm_addr)
m = models[index]
now = int(time.time())
owner = client._provider.call_with_retry(
    lambda: client._contract.functions.getEndpointOwner(new_endpoint).call()
)
print("--- verified ---")
print(f"idx={index} status={status_of(m)} rem_h={(m.expires_at-now)/3600:+.2f}")
print(f"endpoint={m.endpoint}")
print(f"endpoint_owner={owner}")
print(f"balance={client._provider.w3.eth.get_balance(evm_addr)/1e18:.6f} TAO")
if m.endpoint != new_endpoint:
    fail("endpoint not updated on-chain")
print("OK")
PY
