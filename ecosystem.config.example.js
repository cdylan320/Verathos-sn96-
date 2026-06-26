// Multi-GPU miner PM2 config — LD_LIBRARY_PATH from .env.sh (vLLM 0.20.x CUDA 13 libs).
// Regenerate .env.sh with: bash scripts/setup_miner.sh
const fs = require("fs");
const path = require("path");

const REPO = __dirname;
const envSh = fs.readFileSync(path.join(REPO, ".env.sh"), "utf8");
const ldMatch = envSh.match(/^export LD_LIBRARY_PATH="([^"]*)"/m);
const LD_LIBRARY_PATH =
  process.env.LD_LIBRARY_PATH || (ldMatch && ldMatch[1]) || "";

const baseEnv = {
  LD_LIBRARY_PATH,
  VLLM_ENABLE_V1_MULTIPROCESSING: "0",
};

module.exports = {
  apps: [
    {
      name: "miner",
      script: ".venv-vllm/bin/python",
      args: "-u -m neurons.miner --wallet sn59_babelbit3 --hotkey hk_0 --netuid 96 --subtensor-network finney --model-id auto --endpoint https://216.81.248.22:40009 --port 8000 --auto-update",
      cwd: REPO,
      env: { ...baseEnv, CUDA_VISIBLE_DEVICES: "0" },
      autorestart: false,
      max_restarts: 0,
      merge_logs: true,
    },
    {
      name: "miner-1",
      script: ".venv-vllm/bin/python",
      args: "-u -m neurons.miner --wallet sn59_babelbit3 --hotkey hk_0 --netuid 96 --subtensor-network finney --model-id auto --endpoint https://216.81.248.22:40010 --port 8001 --auto-update",
      cwd: REPO,
      env: { ...baseEnv, CUDA_VISIBLE_DEVICES: "1" },
      autorestart: false,
      max_restarts: 0,
      merge_logs: true,
    },
  ],
};
