# Miner Quickstart — L40 VPS (Subnet 96)

Step-by-step guide for running a Verathos miner on an **NVIDIA L40 (48 GB)** VPS — single GPU or **multi-GPU** (2× L40 on one server). Designed for beginners.

Use the **`./miner`** helper script for single-GPU setup. For **2+ GPUs**, see [Multi-GPU setup](#multi-gpu-setup-2-gpus-on-one-server) below.

---

## What you need before starting

| Item | Details |
|------|---------|
| **Server** | Linux VPS with 1× or 2× L40 (48 GB VRAM each), 32 GB+ RAM per GPU, 100 GB+ SSD |
| **OS** | Ubuntu 22.04+ |
| **GPU driver** | `nvidia-smi` must work before you begin |
| **Network** | Public IP + **inbound HTTPS port** open (443 or custom, e.g. 8443) |
| **TAO** | Stake to register on subnet 96 + ~0.1 TAO for EVM gas |
| **Bittensor wallet** | Coldkey + hotkey (can create on laptop, copy hotkey to server) |

Validators do **not** connect via SSH. They call your **public HTTPS URL**.

---

## Architecture (one glance)

```
Your L40 VPS
├── nginx (HTTPS :443)  ← validators connect here
├── verallm.api.server  ← vLLM inference + proofs (localhost:8000)
└── neurons.miner       ← registration, heartbeat, wallet
```

---

## Step 0 — Verify GPU on the VPS

SSH into your server and run:

```bash
nvidia-smi
```

You should see **NVIDIA L40** with **~48 GB** memory. If this fails, fix NVIDIA drivers first.

---

## Step 1 — Clone Verathos

```bash
git clone https://github.com/verathos-ai/verathos.git
cd verathos
chmod +x miner scripts/miner-starter.sh scripts/miner-lib.sh
```

---

## Step 2 — Open firewall port

Validators must reach your miner on **HTTPS**.

```bash
# If using UFW (Ubuntu):
sudo ufw allow 443/tcp
sudo ufw allow 22/tcp
sudo ufw enable

# Or open your custom port, e.g.:
sudo ufw allow 8443/tcp
```

Also open the same port in your **cloud provider's security group / firewall panel**.

---

## Step 3 — Run the guided setup wizard

One command does install + configure + HTTPS:

```bash
./miner setup
```

The wizard will:

1. **Install** — Python venv, vLLM, CUDA extensions (~15–30 min first time)
2. **Configure** — wallet name, mainnet/testnet, public endpoint URL
3. **HTTPS** — nginx reverse proxy with self-signed certificate
4. **Check** — GPU, wallet, venv preflight

Config is saved to `miner.conf` (gitignored pattern — do not commit secrets).

---

## Step 4 — Bittensor wallet (if you don't have one)

### Option A — Create on your laptop, copy hotkey to VPS

On your laptop:

```bash
pip install bittensor-cli
btcli wallet create --wallet.name miner
btcli subnet register --wallet.name miner --netuid 96 --subtensor.network finney
```

Copy **only the hotkey** to the VPS (never copy the coldkey to a remote server):

```bash
# On laptop — show hotkey path
ls ~/.bittensor/wallets/miner/hotkeys/

# Copy to VPS (example)
scp -r ~/.bittensor/wallets/miner/hotkeys/default user@YOUR_VPS:~/.bittensor/wallets/miner/hotkeys/
scp ~/.bittensor/wallets/miner/coldkeypub.txt user@YOUR_VPS:~/.bittensor/wallets/miner/
```

### Option B — Create directly on the VPS

```bash
btcli wallet create --wallet.name miner
btcli subnet register --wallet.name miner --netuid 96 --subtensor.network finney
```

---

## Step 5 — Fund EVM gas

The miner registers on Bittensor EVM (smart contracts). You need a small TAO balance for gas:

```bash
./miner evm
```

Example output:

```
EVM address: 0x...
SS58 mirror: 5...
```

Send **~0.1 TAO** to the SS58 mirror:

```bash
btcli wallet transfer --dest <SS58_MIRROR> --amount 0.1 --subtensor.network finney
```

---

## Step 6 — Preflight check

```bash
./miner check
```

Fix anything marked ✗ before starting.

---

## Step 7 — Start mining

```bash
./miner start
```

First startup takes several minutes: the model downloads, loads into GPU, computes Merkle roots, and registers on-chain.

Watch progress:

```bash
./miner logs
```

---

## Step 8 — Verify it's working

```bash
./miner status

# Local health check (after model loaded):
curl -sk https://localhost:443/health

# Or your public endpoint:
curl -sk https://YOUR_PUBLIC_IP:443/health
```

A healthy miner returns JSON with GPU info and readiness status.

---

## Multi-GPU setup (2+ GPUs on one server)

If your VPS has **2 or more GPUs** (e.g. 2× L40), run **one miner process per GPU**. Each process serves one model on one GPU and registers its own public endpoint. **One Bittensor UID** (same wallet + hotkey) can register **multiple endpoints** — validators dedupe by GPU UUID, so each physical GPU counts separately.

> **Do not** run two miners on the same GPU without `CUDA_VISIBLE_DEVICES` — both will try GPU 0 and OOM.

### Architecture (2× GPU)

```
Your VPS (2× L40)
├── miner (PM2)     → CUDA_VISIBLE_DEVICES=0 → vLLM :8000 → public :443  (or :40000)
├── miner-1 (PM2)   → CUDA_VISIBLE_DEVICES=1 → vLLM :8001 → public :8443 (or :40001)
└── miner.conf      → first miner only (wallet, network, primary endpoint)
    ecosystem.config.js → both PM2 processes (edit this for multi-GPU)
```

| File | Role |
|------|------|
| `miner.conf` | First miner: wallet, network, primary endpoint, model |
| `ecosystem.config.js` | One PM2 app per GPU (`miner`, `miner-1`, …) |
| `.env.sh` | `LD_LIBRARY_PATH` for vLLM CUDA libs (created by `setup_miner.sh`) |

### Option A — Wizard (recommended)

1. Complete [Steps 0–7](#step-0--verify-gpu-on-the-vps) for the **first GPU** (`./miner setup` then `./miner start`).
2. Re-run the wizard and add a second endpoint:

```bash
verathos setup
# Choose: [3] Add model endpoint (different model/GPU/port)
```

The wizard auto-assigns `CUDA_VISIBLE_DEVICES`, internal vLLM port (`8001`, …), external HTTPS port, and PM2 name (`miner-1`, …).

### Option B — Manual `ecosystem.config.js`

After `./miner setup` for GPU 0, create or edit `ecosystem.config.js` in the repo root. Example for **2× L40** with ports `40000` and `40001`:

```javascript
// Generate LD_LIBRARY_PATH once (vLLM 0.20.x needs pip CUDA 13 libs):
//   source .env.sh   # or run: bash scripts/setup_miner.sh
const LD_LIBRARY_PATH = process.env.LD_LIBRARY_PATH || "<paste from .env.sh>";

const baseEnv = {
  LD_LIBRARY_PATH,
  VLLM_ENABLE_V1_MULTIPROCESSING: "0",
};

module.exports = {
  apps: [
    {
      name: "miner",
      script: ".venv-vllm/bin/python",
      args: "-u -m neurons.miner --wallet <WALLET> --hotkey <HOTKEY> --netuid 96 --subtensor-network finney --model-id auto --endpoint https://YOUR_IP:40000 --port 8000 --auto-update",
      cwd: "/path/to/verathos",
      env: { ...baseEnv, CUDA_VISIBLE_DEVICES: "0" },
      autorestart: false,
      max_restarts: 0,
      merge_logs: true,
    },
    {
      name: "miner-1",
      script: ".venv-vllm/bin/python",
      args: "-u -m neurons.miner --wallet <WALLET> --hotkey <HOTKEY> --netuid 96 --subtensor-network finney --model-id auto --endpoint https://YOUR_IP:40001 --port 8001 --auto-update",
      cwd: "/path/to/verathos",
      env: { ...baseEnv, CUDA_VISIBLE_DEVICES: "1" },
      autorestart: false,
      max_restarts: 0,
      merge_logs: true,
    },
  ],
};
```

**Firewall / port mapping** — open **both** external ports (UFW + cloud panel). If your host maps `40000 → 8000`, add `40001 → 8001` the same way.

**HTTPS for the second miner** (if using nginx):

```bash
sudo bash scripts/setup_https.sh --port 40001 --backend-port 8001 --append
```

### Start and monitor (multi-GPU)

```bash
# Start both miners (NOT ./miner start — that overwrites ecosystem.config.js)
pm2 start ecosystem.config.js
pm2 save

# Or one at a time:
pm2 start ecosystem.config.js --only miner
pm2 start ecosystem.config.js --only miner-1

pm2 list
pm2 logs miner --lines 50
pm2 logs miner-1 --lines 50
```

**Health checks:**

```bash
curl -s http://localhost:8000/health   # GPU 0 (internal)
curl -s http://localhost:8001/health   # GPU 1 (internal)
```

### Multi-GPU daily commands

| Task | Command |
|------|---------|
| Start all miners | `pm2 start ecosystem.config.js` |
| Stop all | `pm2 stop all` |
| Logs (GPU 0) | `pm2 logs miner --lines 50` |
| Logs (GPU 1) | `pm2 logs miner-1 --lines 50` |
| Status | `pm2 list` |

Avoid `./miner start` and `./miner configure` on multi-GPU hosts — they regenerate a **single-miner** `ecosystem.config.js` from `miner.conf`.

---

## Daily commands cheat sheet

| Task | Command |
|------|---------|
| Start miner | `./miner start` |
| Stop miner | `./miner stop` |
| View logs | `./miner logs` |
| Check status | `./miner status` |
| Change settings | `./miner configure` then `./miner restart` |
| See EVM balance | `./miner evm` |
| See model options | `./miner models` |
| Help | `./miner help` |

---

## L40-specific notes

| Topic | Detail |
|-------|--------|
| **VRAM tier** | 48 GB → `GB_48` — larger models than 24 GB cards |
| **Model** | Use `MODEL_ID="auto"` in `miner.conf` (default) |
| **One GPU** | One miner process, one model, one endpoint — use `./miner start` |
| **Two GPUs** | Two PM2 processes in `ecosystem.config.js` — use `pm2 start ecosystem.config.js` |
| **HTTPS port** | If 443 is taken, use `./miner https` with `--port 8443` and set endpoint to `https://IP:8443` |
| **Multi-GPU ports** | Each GPU needs a unique external port **and** internal `--port` (8000, 8001, …) |

---

## Troubleshooting

### External port check failed

Validators cannot reach your server.

- Open port in **UFW** and **cloud firewall**
- Confirm endpoint matches nginx port: `./miner configure`
- Re-run HTTPS setup: `./miner https`

### Wallet not found

```bash
ls ~/.bittensor/wallets/miner/hotkeys/default
./miner evm
```

### Model not registered on-chain

Only models in the subnet's `ModelRegistry` can be mined. Check:

```bash
./miner models
```

Use a model from that list or keep `auto`.

### Miner crashed / out of VRAM

```bash
./miner logs
```

Check logs for OOM. Try a smaller quant or explicit model in `miner.conf`, then `./miner configure`.

### PM2 not found

The starter installs PM2 automatically. Or manually:

```bash
sudo npm install -g pm2
```

### `libcudart.so.13: cannot open shared object file`

vLLM 0.20.x ships CUDA 13 runtime libs inside the venv (`site-packages/nvidia/cu13/lib/`). PM2 does not set `LD_LIBRARY_PATH` by default.

**Fix:**

1. Ensure `.env.sh` exists (created by `bash scripts/setup_miner.sh`):

```bash
source .env.sh
.venv-vllm/bin/python -c "import vllm._C; print('CUDA libs OK')"
```

2. Add `LD_LIBRARY_PATH` from `.env.sh` to each app's `env` block in `ecosystem.config.js` (see [Multi-GPU setup](#multi-gpu-setup-2-gpus-on-one-server)).

3. Restart: `pm2 delete all && pm2 start ecosystem.config.js && pm2 save`

### Only one miner started (multi-GPU)

- Check `ecosystem.config.js` has **two** apps (`miner` and `miner-1`). `./miner start` overwrites it with a single entry — restore from backup or re-create the dual-GPU config.
- Run `pm2 start ecosystem.config.js` (starts all apps), not `pm2 start ecosystem.config.js --only miner`.

### Second GPU endpoint unreachable

- Open the second external port in UFW and your cloud firewall (e.g. `40001`).
- Map external port → internal vLLM port (`40001 → 8001`) if your provider uses port forwarding.
- Confirm health: `curl -s http://localhost:8001/health`

---

## Manual alternative (without ./miner)

If you prefer the official path:

```bash
bash scripts/setup_miner.sh
verathos setup          # interactive wizard
verathos start          # PM2
```

See [Setup Guide](setup.md) for full details.

---

## Next steps

- [Validator–Miner Workflow](validator_miner_workflow.md) — how scoring works
- [Bittensor Integration](bittensor_integration.md) — epochs, canaries, weights
- [Setup Guide](setup.md) — PM2, Cloudflare tunnel, production tips
