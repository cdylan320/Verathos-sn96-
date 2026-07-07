#!/bin/bash
# =============================================================================
# Verathos Miner Starter — newbie-friendly miner setup & control
# =============================================================================
#
# Usage (from repo root):
#   ./miner setup        # First time: install + configure + HTTPS (guided)
#   ./miner configure    # Edit wallet, endpoint, model settings
#   ./miner check        # Preflight before starting
#   ./miner check-audit  # Hot-capacity audit preflight (wheel, worker, ingest)
#   ./miner start        # Start miner (PM2)
#   ./miner stop         # Stop miner
#   ./miner status       # GPU, wallet, PM2, endpoint health
#   ./miner logs         # Tail miner logs
#   ./miner evm          # Show EVM address for gas funding
#   ./miner models       # Models recommended for your GPU
#   ./miner https        # Setup nginx HTTPS reverse proxy
#   ./miner help
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/miner-lib.sh
source "$SCRIPT_DIR/miner-lib.sh"

CMD="${1:-help}"
shift || true

# ── install: run setup_miner.sh ──────────────────────────────────────────────
cmd_install() {
    miner_banner
    miner_step "Step 1/1 — Installing Verathos miner environment (15–30 min first run)"
    echo ""
    if [ -f "$REPO_ROOT/miner.conf" ]; then
        # shellcheck source=/dev/null
        source "$REPO_ROOT/miner.conf"
    fi
    bash "$REPO_ROOT/scripts/setup_miner.sh" "$@"
    miner_source_env "$REPO_ROOT"
    echo ""
    miner_ok "Install complete. Next:  ./miner configure"
}

# ── configure: interactive miner.conf + ecosystem.config.js ──────────────────
cmd_configure() {
    miner_banner
    miner_step "Configure your miner"
    echo ""

    local conf="$REPO_ROOT/miner.conf"
    local wallet hotkey network netuid endpoint https_port model_id use_pm2 public_ip hf_token

    # Load existing defaults
    if [ -f "$conf" ]; then
        # shellcheck source=/dev/null
        source "$conf"
        wallet="${WALLET_NAME:-miner}"
        hotkey="${HOTKEY_NAME:-default}"
        network="${NETWORK:-finney}"
        netuid="${NETUID:-96}"
        endpoint="${ENDPOINT:-}"
        https_port="${HTTPS_PORT:-443}"
        model_id="${MODEL_ID:-auto}"
        use_pm2="${USE_PM2:-true}"
        hf_token="${HF_TOKEN:-}"
    else
        wallet="miner"
        hotkey="default"
        network="finney"
        netuid=96
        https_port=443
        model_id="auto"
        use_pm2="true"
        endpoint=""
        hf_token=""
    fi

    public_ip="$(miner_detect_public_ip)"
    [ -z "$endpoint" ] && [ -n "$public_ip" ] && endpoint="https://${public_ip}:${https_port}"

    echo "  Answer a few questions. Press Enter to accept [defaults]."
    echo ""

    miner_prompt wallet "Wallet name" "$wallet"
    miner_prompt hotkey "Hotkey name" "$hotkey"

    echo ""
    echo "  Network:"
    echo "    1) finney  — mainnet (netuid 96)  [recommended]"
    echo "    2) test     — testnet (netuid 405)"
    read -r -p "  Choose [1]: " net_choice
    net_choice="${net_choice:-1}"
    case "$net_choice" in
        2) network="test"; netuid=405 ;;
        *) network="finney"; netuid=96 ;;
    esac

    echo ""
    if [ -n "$public_ip" ]; then
        miner_info "Detected public IP: $public_ip"
    else
        miner_warn "Could not detect public IP — you will enter it manually"
        public_ip="YOUR_PUBLIC_IP"
    fi

    miner_prompt https_port "HTTPS port (open this port in your VPS firewall)" "$https_port"
    miner_prompt endpoint "Miner endpoint URL (validators connect here)" "$endpoint"
    miner_prompt model_id "Model ID (auto = best for your GPU)" "$model_id"

    echo ""
    miner_prompt hf_token "HF token (optional — huggingface.co/settings/tokens)" "$hf_token"

    echo ""
    if miner_prompt_yesno "Use PM2 to keep miner running in background?" "y"; then
        use_pm2="true"
    else
        use_pm2="false"
    fi

    local hf_token_block=""
    if [ -n "$hf_token" ]; then
        hf_token_block=$'\n\n# Hugging Face token — higher download rate limits\nexport HF_TOKEN="'"$hf_token"'"'
    fi

    cat > "$conf" <<EOF
# Verathos Miner Configuration — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
WALLET_NAME="$wallet"
HOTKEY_NAME="$hotkey"
NETWORK="$network"
NETUID=$netuid
ENDPOINT="$endpoint"
HTTPS_PORT=$https_port
BACKEND_PORT=8000
MODEL_ID="$model_id"
PM2_NAME="miner"
USE_PM2=$use_pm2${hf_token_block}
EOF

    miner_ok "Saved $conf"
    miner_load_config "$REPO_ROOT"
    miner_generate_ecosystem "$REPO_ROOT"

    echo ""
    miner_step "Before starting, you still need:"
    echo "    1. Bittensor wallet on this server     →  ./miner evm"
    echo "    2. Register on subnet + fund EVM gas   →  see docs/miner_quickstart.md"
    echo "    3. HTTPS reverse proxy (if not done)   →  ./miner https"
    echo "    4. Preflight check                     →  ./miner check"
    echo ""
}

# ── https: nginx reverse proxy ───────────────────────────────────────────────
cmd_https() {
    miner_banner
    if [ -f "$REPO_ROOT/miner.conf" ]; then
        miner_load_config "$REPO_ROOT"
    else
        HTTPS_PORT=443
        BACKEND_PORT=8000
    fi
    miner_step "Setting up HTTPS reverse proxy (port $HTTPS_PORT → localhost:$BACKEND_PORT)"
    echo ""
    if [ "$(id -u)" -ne 0 ]; then
        miner_warn "nginx install may need root — re-running with sudo"
        sudo bash "$REPO_ROOT/scripts/setup_https.sh" --port "$HTTPS_PORT" --backend-port "$BACKEND_PORT"
    else
        bash "$REPO_ROOT/scripts/setup_https.sh" --port "$HTTPS_PORT" --backend-port "$BACKEND_PORT"
    fi
}

# ── check: preflight ─────────────────────────────────────────────────────────
cmd_check() {
    miner_banner
    miner_step "Preflight checks"
    echo ""

    local ok=true
    miner_check_gpu || ok=false
    echo ""

    if [ -f "$REPO_ROOT/miner.conf" ]; then
        miner_load_config "$REPO_ROOT"
        miner_check_wallet "$WALLET_NAME" "$HOTKEY_NAME" || ok=false
        if [ -n "$ENDPOINT" ] && [ "$ENDPOINT" != "https://YOUR_PUBLIC_IP:443" ]; then
            miner_ok "Endpoint: $ENDPOINT"
        else
            miner_fail "Endpoint not configured — run: ./miner configure"
            ok=false
        fi
    else
        miner_fail "miner.conf missing — run: ./miner configure"
        ok=false
    fi
    echo ""

    miner_source_env "$REPO_ROOT"
    if [ -f "$REPO_ROOT/.venv-vllm/bin/python" ]; then
        miner_ok "Python venv: .venv-vllm"
    else
        miner_fail "venv missing — run: ./miner install"
        ok=false
    fi

    if [ -f "$REPO_ROOT/ecosystem.config.js" ]; then
        miner_ok "PM2 config: ecosystem.config.js"
    else
        miner_warn "ecosystem.config.js missing — run: ./miner configure"
    fi

    echo ""
    miner_step "EVM gas wallet"
    if [ -f "$REPO_ROOT/.venv-vllm/bin/python" ] && [ -f "$REPO_ROOT/miner.conf" ]; then
        miner_load_config "$REPO_ROOT"
        "$REPO_ROOT/.venv-vllm/bin/python" "$REPO_ROOT/scripts/show_evm_info.py" \
            --wallet "$WALLET_NAME" --hotkey "$HOTKEY_NAME" \
            --subtensor-network "$NETWORK" --check-balance 2>/dev/null || true
    fi

    echo ""
    if [ -n "${ENDPOINT:-}" ] && [[ "$ENDPOINT" == https://* ]]; then
        miner_step "Local HTTPS probe"
        local host port
        host=$(echo "$ENDPOINT" | sed -E 's|https?://([^:/]+).*|\1|')
        port=$(echo "$ENDPOINT" | sed -E 's|.*:([0-9]+)$|\1|')
        [ "$port" = "$ENDPOINT" ] && port=443
        if curl -sk --max-time 5 "https://localhost:${port}/health" 2>/dev/null | grep -q .; then
            miner_ok "Miner server responding on localhost:${port}/health"
        elif curl -sk --max-time 5 "https://${host}:${port}/health" 2>/dev/null | grep -q .; then
            miner_ok "Endpoint /health reachable"
        else
            miner_warn "Miner not running yet (expected before first start)"
            miner_info "After ./miner start, validators will hit: $ENDPOINT"
        fi
    fi

    echo ""
    if $ok; then
        echo -e "${_C_GREEN}${_C_BOLD}  Ready to start!  Run:  ./miner start${_C_RESET}"
        echo -e "${_C_DIM}  After start, verify hot-capacity audits:  ./miner check-audit${_C_RESET}"
    else
        echo -e "${_C_YELLOW}${_C_BOLD}  Fix the issues above, then run:  ./miner check${_C_RESET}"
        exit 1
    fi
    echo ""
}

# ── check-audit: hot-capacity audit preflight ────────────────────────────────
cmd_check_audit() {
    local from_setup=false
    if [ "${1:-}" = "--from-setup" ]; then
        from_setup=true
    fi

    if [ "$from_setup" = false ]; then
        miner_banner
    fi
    miner_step "Hot-capacity audit preflight"
    echo ""
    miner_info "Checks wheel install, GPU calibration, miner worker logs, and"
    miner_info "outbound reachability to validator audit ingest endpoints."
    echo ""

    local ok=true
    local rc=0

    if [ -f "$REPO_ROOT/miner.conf" ]; then
        miner_load_config "$REPO_ROOT"
    else
        NETWORK="${NETWORK:-finney}"
        NETUID="${NETUID:-96}"
        PM2_NAME="${PM2_NAME:-miner}"
        miner_warn "miner.conf missing — using defaults (network=$NETWORK netuid=$NETUID)"
    fi

    miner_source_env "$REPO_ROOT"
    echo ""

    miner_step "1/3 Runtime (wheel, GPU, validator ingest reachability)"
    if ! miner_check_capacity_audit_runtime "$REPO_ROOT" "$NETWORK" "$NETUID"; then
        ok=false
    fi
    echo ""

    miner_step "2/3 Miner process + capacity-audit worker logs"
    set +e
    miner_check_capacity_audit_worker_logs "$PM2_NAME"
    rc=$?
    set -e
    if [ "$rc" -eq 1 ]; then
        ok=false
    fi
    echo ""

    miner_step "3/3 Quick fixes if audits still fail"
    echo "  • Reinstall audit wheel:  bash scripts/setup_miner.sh"
    echo "  • Full restart:            ./miner restart"
    echo "  • Tail audit logs:         ./miner logs 200 | grep -i capacity"
    echo "  • Manual validator URLs:   export VERATHOS_CAPACITY_AUDIT_VALIDATOR_URLS=http://HOST:8091"
    echo ""

    if $ok && [ "$rc" -ne 1 ]; then
        echo -e "${_C_GREEN}${_C_BOLD}  Capacity-audit preflight passed.${_C_RESET}"
        if [ "$rc" -eq 2 ]; then
            echo -e "${_C_YELLOW}  Review warnings above — publish errors may still cause no_show.${_C_RESET}"
        fi
    else
        echo -e "${_C_YELLOW}${_C_BOLD}  Capacity-audit issues found — fix above before the next audit window.${_C_RESET}"
        echo -e "${_C_DIM}  Missing receipts → validator records no_show / missing_final_receipt.${_C_RESET}"
        if [ "$from_setup" = false ]; then
            exit 1
        fi
        return 1
    fi
    echo ""
}

# ── start / stop / status / logs ─────────────────────────────────────────────
cmd_start() {
    miner_banner
    miner_load_config "$REPO_ROOT"
    miner_source_env "$REPO_ROOT"

    if ! miner_check_gpu >/dev/null 2>&1; then
        miner_die "GPU check failed"
    fi
    if ! miner_check_wallet "$WALLET_NAME" "$HOTKEY_NAME" >/dev/null 2>&1; then
        miner_die "Wallet check failed — see ./miner evm"
    fi

    miner_step "Starting Verathos miner"
    miner_info "Endpoint: $ENDPOINT"
    miner_info "Model:    $MODEL_ID"
    echo ""

    miner_prefetch_hf_model "$REPO_ROOT"

    if [ "$USE_PM2" = "true" ]; then
        if ! command -v pm2 &>/dev/null; then
            miner_step "Installing PM2..."
            npm install -g pm2 2>/dev/null || sudo npm install -g pm2
        fi
        [ -f "$REPO_ROOT/ecosystem.config.js" ] || miner_generate_ecosystem "$REPO_ROOT"
        # Always regenerate PM2 config from miner.conf so wallet/endpoint stay in sync.
        miner_generate_ecosystem "$REPO_ROOT"
        cd "$REPO_ROOT"
        if pm2 describe "$PM2_NAME" &>/dev/null; then
            pm2 restart "$PM2_NAME"
        else
            pm2 start ecosystem.config.js --only "$PM2_NAME"
        fi
        pm2 save 2>/dev/null || true
        echo ""
        miner_ok "Miner started via PM2 (process: $PM2_NAME)"
        miner_info "Logs:   ./miner logs"
        miner_info "Status: ./miner status"
        miner_info "Audit:  ./miner check-audit"
        miner_info "Stop:   ./miner stop"
    else
        miner_warn "Starting in foreground (Ctrl+C to stop)"
        cd "$REPO_ROOT"
        exec python -u -m neurons.miner \
            --wallet "$WALLET_NAME" --hotkey "$HOTKEY_NAME" \
            --netuid "$NETUID" --subtensor-network "$NETWORK" \
            --model-id "$MODEL_ID" --endpoint "$ENDPOINT" --auto-update
    fi
    echo ""
}

cmd_stop() {
    miner_load_config "$REPO_ROOT" 2>/dev/null || PM2_NAME="miner"
    if command -v pm2 &>/dev/null && pm2 describe "$PM2_NAME" &>/dev/null; then
        pm2 stop "$PM2_NAME"
        miner_ok "Stopped $PM2_NAME"
    else
        miner_warn "PM2 process '$PM2_NAME' not running"
    fi
}

cmd_status() {
    miner_banner
    miner_step "System"
    miner_check_gpu || true
    echo ""

    if [ -f "$REPO_ROOT/miner.conf" ]; then
        miner_load_config "$REPO_ROOT"
        miner_check_wallet "$WALLET_NAME" "$HOTKEY_NAME" || true
        miner_info "Endpoint: $ENDPOINT | Network: $NETWORK | Model: $MODEL_ID"
    fi
    echo ""

    miner_step "PM2"
    if command -v pm2 &>/dev/null; then
        pm2 list 2>/dev/null | grep -E "miner|Name|────" || pm2 list 2>/dev/null || true
    else
        miner_warn "PM2 not installed"
    fi
    echo ""
}

cmd_logs() {
    miner_load_config "$REPO_ROOT" 2>/dev/null || PM2_NAME="miner"
    local lines="${1:-80}"
    if command -v pm2 &>/dev/null; then
        pm2 logs "$PM2_NAME" --lines "$lines"
    else
        miner_die "PM2 not installed — start miner with USE_PM2=true"
    fi
}

cmd_evm() {
    miner_banner
    miner_source_env "$REPO_ROOT"
    if [ -f "$REPO_ROOT/miner.conf" ]; then
        miner_load_config "$REPO_ROOT"
    else
        WALLET_NAME="miner"
        HOTKEY_NAME="default"
        NETWORK="finney"
    fi
    miner_step "EVM address (for on-chain registration gas)"
    echo ""
    python "$REPO_ROOT/scripts/show_evm_info.py" \
        --wallet "$WALLET_NAME" --hotkey "$HOTKEY_NAME" \
        --subtensor-network "$NETWORK" --check-balance
}

cmd_models() {
    miner_banner
    miner_source_env "$REPO_ROOT"
    miner_step "Models recommended for your GPU"
    echo ""
    python -m verallm.registry --recommend --verified-only 2>/dev/null || \
        python -m verallm.registry --recommend 2>/dev/null || \
        miner_die "Run ./miner install first"
}

# ── setup: guided first-time pipeline ────────────────────────────────────────
cmd_setup() {
    miner_banner
    echo "  Welcome! This wizard will:"
    echo "    1. Install / update dependencies (incl. hot-capacity audit wheel)"
    echo "    2. Configure wallet, network, and endpoint"
    echo "    3. Set up HTTPS reverse proxy"
    echo "    4. Run preflight checks"
    echo ""
    if ! miner_prompt_yesno "Continue?" "y"; then
        exit 0
    fi

    echo ""
    if [ -f "$REPO_ROOT/.venv-vllm/bin/python" ]; then
        miner_info "Existing .venv-vllm found — re-running install to pick up updates"
    fi
    cmd_install

    echo ""
    cmd_configure

    echo ""
    if miner_prompt_yesno "Set up HTTPS reverse proxy now? (required for mainnet)" "y"; then
        cmd_https
    fi

    echo ""
    miner_step "Wallet reminder"
    echo "  If you have NOT yet:"
    echo "    • Created a Bittensor wallet on this server"
    echo "    • Registered on subnet $NETUID"
    echo "    • Funded EVM gas (~0.1 TAO)"
    echo ""
    echo "  See the step-by-step guide:  docs/miner_quickstart.md"
    echo ""
    cmd_evm

    echo ""
    cmd_check || true

    echo ""
    cmd_check_audit --from-setup || true

    echo ""
    if miner_prompt_yesno "Start miner now?" "n"; then
        cmd_start
    else
        echo ""
        miner_ok "Setup complete. When ready:  ./miner start"
    fi
}

cmd_fix_venv() {
    bash "$REPO_ROOT/scripts/fix-miner-venv.sh"
}

cmd_help() {
    miner_banner
    cat <<'HELP'
  Commands (run from repo root as ./miner <command>):

    setup       First-time guided install + configure + HTTPS
    install     Install Python deps, vLLM, CUDA extensions only
    configure   Interactive wallet / endpoint / model settings
    https       Setup nginx HTTPS reverse proxy (self-signed cert)
    check       Preflight: GPU, wallet, venv, endpoint
    check-audit Hot-capacity audit: wheel, worker logs, validator ingest
    start       Start miner (PM2 background)
    stop        Stop miner
    status      Show GPU + PM2 status
    logs        Tail miner logs (default 80 lines)
    evm         Show EVM address + gas balance
    models      Show models that fit your GPU
    fix-venv    Repair scalecodec/cyscale conflict in .venv-vllm
    help        This message

  Quick start (L40 VPS, mainnet):

    git clone https://github.com/verathos-ai/verathos.git && cd verathos
    ./miner setup
    ./miner start

  Full guide:  docs/miner_quickstart.md

HELP
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "$CMD" in
    setup)      cmd_setup "$@" ;;
    install)    cmd_install "$@" ;;
    configure)  cmd_configure "$@" ;;
    https)      cmd_https "$@" ;;
    check)      cmd_check "$@" ;;
    check-audit) cmd_check_audit "$@" ;;
    start)      cmd_start "$@" ;;
    stop)       cmd_stop "$@" ;;
    restart)    cmd_stop; cmd_start "$@" ;;
    status)     cmd_status "$@" ;;
    logs)       cmd_logs "$@" ;;
    evm)        cmd_evm "$@" ;;
    models)     cmd_models "$@" ;;
    fix-venv)   cmd_fix_venv "$@" ;;
    help|-h|--help) cmd_help ;;
    *)
        miner_fail "Unknown command: $CMD"
        cmd_help
        exit 1
        ;;
esac
