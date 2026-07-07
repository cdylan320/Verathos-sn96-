#!/bin/bash
# Shared helpers for Verathos miner starter scripts.
# Source this file — do not execute directly.

set -euo pipefail

# ── Colors (disabled when not a TTY) ─────────────────────────────────────────
if [ -t 1 ]; then
    _C_RESET='\033[0m'
    _C_BOLD='\033[1m'
    _C_DIM='\033[2m'
    _C_GREEN='\033[0;32m'
    _C_YELLOW='\033[1;33m'
    _C_RED='\033[0;31m'
    _C_CYAN='\033[0;36m'
    _C_BLUE='\033[0;34m'
else
    _C_RESET=''
    _C_BOLD=''
    _C_DIM=''
    _C_GREEN=''
    _C_YELLOW=''
    _C_RED=''
    _C_CYAN=''
    _C_BLUE=''
fi

miner_banner() {
    echo ""
    echo -e "${_C_BOLD}${_C_CYAN}============================================================${_C_RESET}"
    echo -e "${_C_BOLD}${_C_CYAN}  Verathos Miner Starter${_C_RESET}"
    echo -e "${_C_BOLD}${_C_CYAN}============================================================${_C_RESET}"
    echo ""
}

miner_step() {
    echo -e "${_C_BOLD}${_C_BLUE}▶ $*${_C_RESET}"
}

miner_ok() {
    echo -e "  ${_C_GREEN}✓${_C_RESET} $*"
}

miner_warn() {
    echo -e "  ${_C_YELLOW}!${_C_RESET} $*"
}

miner_fail() {
    echo -e "  ${_C_RED}✗${_C_RESET} $*"
}

miner_info() {
    echo -e "  ${_C_DIM}$*${_C_RESET}"
}

miner_die() {
    miner_fail "$*"
    echo ""
    echo "  Run:  ./miner help"
    exit 1
}

# Repo root (directory containing pyproject.toml)
miner_find_repo() {
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")/.." && pwd)"
    if [ ! -f "$dir/pyproject.toml" ]; then
        miner_die "Cannot find Verathos repo root (expected pyproject.toml in $dir)"
    fi
    echo "$dir"
}

miner_load_config() {
    local repo="$1"
    MINER_CONF="${MINER_CONF:-$repo/miner.conf}"
    if [ ! -f "$MINER_CONF" ]; then
        miner_die "Config not found: $MINER_CONF\n  Run first:  ./miner setup"
    fi
    # shellcheck source=/dev/null
    source "$MINER_CONF"
    : "${WALLET_NAME:=miner}"
    : "${HOTKEY_NAME:=default}"
    : "${NETUID:=96}"
    : "${NETWORK:=finney}"
    : "${ENDPOINT:=}"
    : "${HTTPS_PORT:=443}"
    : "${BACKEND_PORT:=8000}"
    : "${MODEL_ID:=auto}"
    : "${PM2_NAME:=miner}"
    : "${USE_PM2:=true}"
    : "${HF_TOKEN:=}"
}

miner_source_env() {
    local repo="$1"
    if [ -f "$repo/.env.sh" ]; then
        # shellcheck source=/dev/null
        source "$repo/.env.sh"
    fi
    if [ -f "$repo/.venv-vllm/bin/activate" ]; then
        # shellcheck source=/dev/null
        source "$repo/.venv-vllm/bin/activate"
    fi
}

miner_prefetch_hf_model() {
    local repo="$1"
    local python="$repo/.venv-vllm/bin/python"
    local script="$repo/scripts/prefetch_hf_model.py"
    if [ ! -x "$python" ] || [ ! -f "$script" ]; then
        return 0
    fi
    miner_step "Prefetching HuggingFace model snapshot"
    miner_info "Ensures README/LICENSE/config files exist (vLLM only downloads weights)"
    if "$python" "$script" --model-id "$MODEL_ID" --network "$NETWORK"; then
        miner_ok "Model snapshot ready"
    else
        miner_warn "Model prefetch failed — start may fail if HF cache is incomplete"
    fi
    echo ""
}

miner_detect_public_ip() {
    curl -sf --max-time 5 ifconfig.me 2>/dev/null \
        || curl -sf --max-time 5 icanhazip.com 2>/dev/null \
        || echo ""
}

miner_check_gpu() {
    if ! command -v nvidia-smi &>/dev/null; then
        miner_fail "nvidia-smi not found — NVIDIA GPU required"
        return 1
    fi
    local name vram_mb
    name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [ -z "$name" ]; then
        miner_fail "No GPU detected"
        return 1
    fi
    miner_ok "GPU: $name (${vram_mb} MB VRAM)"
    if [ "${vram_mb:-0}" -lt 20000 ] 2>/dev/null; then
        miner_warn "VRAM below 24 GB minimum — mining may fail"
    fi
    return 0
}

miner_check_wallet() {
    local wallet="$1" hotkey="$2"
    local hk_path="$HOME/.bittensor/wallets/${wallet}/hotkeys/${hotkey}"
    if [ ! -f "$hk_path" ]; then
        miner_fail "Wallet not found: $wallet / $hotkey"
        miner_info "Create on this machine OR copy hotkey from your laptop:"
        miner_info "  btcli wallet create --wallet.name $wallet"
        miner_info "  btcli wallet regen-hotkey --wallet.name $wallet --hotkey $hotkey"
        return 1
    fi
    miner_ok "Wallet: $wallet / $hotkey"
    return 0
}

miner_generate_ecosystem() {
    local repo="$1"
    local out="$repo/ecosystem.config.js"
    if [ -f "$out" ] && grep -qE 'name:\s*"miner-[0-9]+"' "$out" 2>/dev/null; then
        miner_warn "Keeping multi-GPU ecosystem.config.js (start with: pm2 start ecosystem.config.js)"
        return 0
    fi
    local env_block=""
    if [ -n "${HF_TOKEN:-}" ] || [ -n "${HF_HOME:-}" ]; then
        env_block="
      env: {"
        if [ -n "${HF_TOKEN:-}" ]; then
            env_block+="
        HF_TOKEN: \"${HF_TOKEN}\","
        fi
        if [ -n "${HF_HOME:-}" ]; then
            env_block+="
        HF_HOME: \"${HF_HOME}\","
        fi
        env_block+="
      },"
    fi
    cat > "$out" <<EOF
// Auto-generated by miner-starter.sh — edit miner.conf and re-run: ./miner configure
module.exports = {
  apps: [
    {
      name: "${PM2_NAME}",
      script: ".venv-vllm/bin/python",
      args: "-u -m neurons.miner --wallet ${WALLET_NAME} --hotkey ${HOTKEY_NAME} --netuid ${NETUID} --subtensor-network ${NETWORK} --model-id ${MODEL_ID} --endpoint ${ENDPOINT} --auto-update",
      cwd: "${repo}",${env_block}
      autorestart: false,
      max_restarts: 0,
      merge_logs: true,
      log_date_format: "YYYY-MM-DD HH:mm:ss",
      max_size: "50M",
      retain: 3,
    },
  ],
};
EOF
    miner_ok "Wrote $out"
}

miner_prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default_val="${3:-}"
    local input
    if [ -n "$default_val" ]; then
        read -r -p "  $prompt_text [$default_val]: " input
        input="${input:-$default_val}"
    else
        read -r -p "  $prompt_text: " input
    fi
    printf -v "$var_name" '%s' "$input"
}

miner_prompt_yesno() {
    local prompt_text="$1"
    local default_yes="${2:-y}"
    local input hint="Y/n"
    [ "$default_yes" = "n" ] && hint="y/N"
    read -r -p "  $prompt_text [$hint]: " input
    input="${input:-$default_yes}"
    case "${input,,}" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Return PM2 log text for the miner process (empty if unavailable).
miner_pm2_log_text() {
    local pm2_name="$1"
    local lines="${2:-500}"
    if ! command -v pm2 &>/dev/null; then
        return 1
    fi
    pm2 logs "$pm2_name" --nostream --lines "$lines" 2>/dev/null
}

# Scan miner logs for capacity-audit worker state.
miner_check_capacity_audit_worker_logs() {
    local pm2_name="$1"
    local log_text=""

    if ! command -v pm2 &>/dev/null; then
        miner_warn "PM2 not installed — cannot inspect capacity-audit worker logs"
        return 2
    fi
    if ! pm2 describe "$pm2_name" &>/dev/null; then
        miner_fail "Miner process '$pm2_name' is not running"
        miner_info "Start first: ./miner start"
        return 1
    fi
    miner_ok "PM2 process '$pm2_name' is running"

    log_text="$(miner_pm2_log_text "$pm2_name" 800 || true)"
    if [ -z "$log_text" ]; then
        miner_warn "Could not read PM2 logs for '$pm2_name'"
        return 2
    fi

    if echo "$log_text" | grep -qiE "Capacity audit miner worker disabled|hot-capacity workspace extension unavailable"; then
        miner_fail "Capacity-audit worker disabled in miner logs"
        echo "$log_text" | grep -iE "Capacity audit miner worker disabled|hot-capacity workspace extension unavailable" | tail -3 | while read -r line; do
            miner_info "$line"
        done
        miner_info "Fix: bash scripts/setup_miner.sh && ./miner restart"
        return 1
    fi

    if echo "$log_text" | grep -q "Capacity audit miner worker started"; then
        worker_line="$(echo "$log_text" | grep "Capacity audit miner worker started" | tail -1)"
        miner_ok "Capacity-audit worker started"
        miner_info "$(echo "$worker_line" | sed 's/^[[:space:]]*//')"
    else
        miner_fail "No 'Capacity audit miner worker started' line in recent logs"
        miner_info "Miner may be on old code or still booting — wait 2 min and re-run ./miner check-audit"
        return 1
    fi

    if echo "$log_text" | grep -q "Capacity audit publish has no validator endpoints"; then
        miner_fail "Miner logs show no validator audit ingest endpoints"
        return 1
    fi

    if echo "$log_text" | grep -q "Capacity audit publish error"; then
        miner_warn "Recent capacity-audit publish transport errors in logs"
        echo "$log_text" | grep "Capacity audit publish error" | tail -3 | while read -r line; do
            miner_info "$line"
        done
        miner_info "Check outbound firewall to validator ingest ports (usually :8091)"
        return 2
    fi

    if echo "$log_text" | grep -q "Capacity audit artifacts published"; then
        publish_line="$(echo "$log_text" | grep "Capacity audit artifacts published" | tail -1)"
        miner_ok "Recent successful audit receipt publish seen in logs"
        miner_info "$(echo "$publish_line" | sed 's/^[[:space:]]*//')"
    else
        miner_warn "No successful audit publish yet (normal if no audit window since restart)"
    fi

    return 0
}

# Run Python preflight for wheel, GPU calibration, and validator ingest reachability.
miner_check_capacity_audit_runtime() {
    local repo="$1"
    local network="$2"
    local netuid="$3"
    local python="$repo/.venv-vllm/bin/python"
    local script="$repo/scripts/check_capacity_audit_miner.py"
    local output line rc=0 py_rc=0

    if [ ! -x "$python" ]; then
        miner_fail "Python venv missing — run: ./miner install"
        return 1
    fi
    if [ ! -f "$script" ]; then
        miner_fail "Missing audit check script: $script"
        return 1
    fi

    output="$("$python" "$script" --subtensor-network "$network" --netuid "$netuid" 2>&1)" || py_rc=$?

    while IFS= read -r line; do
        case "$line" in
            OK:*)
                miner_ok "${line#OK: }"
                ;;
            WARN:*)
                miner_warn "${line#WARN: }"
                rc=2
                ;;
            FAIL:*)
                miner_fail "${line#FAIL: }"
                rc=1
                ;;
            \ \ -*)
                miner_info "$line"
                ;;
            *)
                [ -n "$line" ] && miner_info "$line"
                ;;
        esac
    done <<< "$output"

    if [ "$py_rc" -ne 0 ]; then
        return 1
    fi
    if [ "$rc" -eq 2 ]; then
        return 2
    fi
    return 0
}
