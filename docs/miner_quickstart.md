# Miner Quickstart — L40 VPS (Subnet 96)

Step-by-step guide for running a Verathos miner on a **1× NVIDIA L40 (48 GB)** VPS. Designed for beginners.

Use the **`./miner`** helper script for an easy setup pipeline.

---

## What you need before starting

| Item | Details |
|------|---------|
| **Server** | Linux VPS with 1× L40 (48 GB VRAM), 32 GB+ RAM, 100 GB+ SSD |
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
| **One GPU** | One miner process, one model, one endpoint |
| **HTTPS port** | If 443 is taken, use `./miner https` with `--port 8443` and set endpoint to `https://IP:8443` |

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
