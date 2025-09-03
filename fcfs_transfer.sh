#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------
# EVM FCFS Sweeper – one-shot installer/runner
# Works on Linux/macOS with bash + curl
# ------------------------------------------

PROJECT_DIR="${HOME}/evm-fcfs-sweeper"
NODE_VERSION="lts/*"

echo ">>> Checking prerequisites (bash, curl)"
if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found. Attempting to install..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y curl
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y curl
  elif command -v brew >/dev/null 2>&1; then
    brew install curl
  else
    echo "Please install curl and re-run."
    exit 1
  fi
fi

# --- Install NVM if missing ---
if [ -z "${NVM_DIR:-}" ]; then
  export NVM_DIR="$HOME/.nvm"
fi
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo ">>> Installing nvm (Node Version Manager)…"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi
# shellcheck disable=SC1090
. "$NVM_DIR/nvm.sh"

echo ">>> Installing Node.js ${NODE_VERSION}"
nvm install "${NODE_VERSION}"
nvm use "${NODE_VERSION}"
echo ">>> Node: $(node -v), npm: $(npm -v)"

# --- Create project dir ---
mkdir -p "${PROJECT_DIR}/logs"
cd "${PROJECT_DIR}"

# --- package.json with ESM ---
cat > package.json <<'PKG'
{
  "name": "evm-fcfs-sweeper",
  "version": "1.0.0",
  "type": "module",
  "license": "MIT",
  "bin": { "evm-sweeper": "./index.js" },
  "dependencies": {
    "dotenv": "^16.4.5",
    "ethers": "^6.13.2",
    "inquirer": "^9.2.15"
  }
}
PKG

echo ">>> Installing dependencies…"
npm i >/dev/null

# --- Optional .env defaults ---
if [ ! -f .env ]; then
  cat > .env <<'ENVEOF'
# Optional defaults – CLI prompts will ask anyway
# RPC_URL=wss://ethereum.publicnode.com
# PRIVATE_KEY=0xYOUR_PRIVATE_KEY
# DEST_ADDRESS=0xYourDestination
POLL_MS=100
GAS_BUMP_PCT=50
MIN_RESERVE_ETH=0.0001
# TOKEN_ADDRESS=0xYourTokenIfAny
MIN_RESERVE_TOKEN=0
ENVEOF
fi

# --- index.js (interactive, EVM-agnostic) ---
cat > index.js <<'JS_EOF'
#!/usr/bin/env node
import 'dotenv/config';
import fs from 'fs';
import path from 'path';
import inquirer from 'inquirer';
import { ethers } from 'ethers';

const LOG_DIR = path.join(process.cwd(), 'logs');
const LOG_FILE = path.join(LOG_DIR, 'sweeper.log');
const LOG_JSONL = path.join(LOG_DIR, 'sweeper.jsonl');
fs.mkdirSync(LOG_DIR, { recursive: true });

function logLine(msg) {
  const line = `[${new Date().toISOString()}] ${msg}`;
  console.log(line);
  fs.appendFileSync(LOG_FILE, line + '\n');
}
function logJson(obj) {
  fs.appendFileSync(LOG_JSONL, JSON.stringify({ ts: new Date().toISOString(), ...obj }) + '\n');
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const bump = (x, pct) => (x ? (x * (100n + pct)) / 100n : undefined);
const toGwei = (wei) => Number(wei) / 1e9;

function parsePercent(x, def = 0n) {
  try { return BigInt(String(x)); } catch { return def; }
}

async function getFeesBumped(provider, gasBumpPct, minTipGwei=0, minMaxFeeGwei=0) {
  const fd = await provider.getFeeData();
  let { maxFeePerGas, maxPriorityFeePerGas, gasPrice } = fd;

  // EIP-1559 fallback
  if (!maxFeePerGas) maxFeePerGas = gasPrice ?? 0n;
  if (!maxPriorityFeePerGas) maxPriorityFeePerGas = maxFeePerGas / 10n;

  // Ensure >= baseFee + tip
  try {
    const block = await provider.getBlock('latest');
    const base = BigInt(block.baseFeePerGas ?? 0);
    if (maxPriorityFeePerGas < BigInt(Math.floor(minTipGwei * 1e9))) {
      maxPriorityFeePerGas = BigInt(Math.floor(minTipGwei * 1e9));
    }
    const minMax = base + maxPriorityFeePerGas;
    if (maxFeePerGas < minMax) maxFeePerGas = minMax;
    if (maxFeePerGas < BigInt(Math.floor(minMaxFeeGwei * 1e9))) {
      maxFeePerGas = BigInt(Math.floor(minMaxFeeGwei * 1e9));
    }
  } catch {}

  return {
    maxFeePerGas: bump(maxFeePerGas, gasBumpPct),
    maxPriorityFeePerGas: bump(maxPriorityFeePerGas, gasBumpPct),
  };
}

// -------- ETH sweeper (native) -----------
async function runEthSweeper(cfg) {
  const { rpcUrl, privateKey, dest, minReserveEth, pollMs, gasBumpPct, minTipGwei, minMaxFeeGwei } = cfg;

  const provider = rpcUrl.startsWith('ws')
    ? new ethers.WebSocketProvider(rpcUrl)
    : new ethers.JsonRpcProvider(rpcUrl);
  provider.pollingInterval = Math.max(50, pollMs); // ethers cap safeguard

  const wallet = new ethers.Wallet(privateKey, provider);
  let sweeping = false;
  let pendingTx = null; // {hash, nonce, maxFeePerGas, maxPriorityFeePerGas}

  async function trySweep(reason='manual') {
    if (sweeping) return;
    sweeping = true;
    try {
      // if previous tx still pending, don't spam replacements
      if (pendingTx) {
        const txOnChain = await provider.getTransaction(pendingTx.hash);
        if (txOnChain && !txOnChain.blockNumber) {
          // still pending
          return;
        } else {
          pendingTx = null;
        }
      }

      const balance = await provider.getBalance(wallet.address, 'latest');
      const reserveWei = ethers.parseEther(minReserveEth || '0');
      if (balance <= reserveWei) return;

      let { maxFeePerGas, maxPriorityFeePerGas } = await getFeesBumped(provider, gasBumpPct, minTipGwei, minMaxFeeGwei);

      // standard 21000 gas (can bump slightly)
      let gasLimit = 21000n;
      const totalFee = maxFeePerGas ? gasLimit * maxFeePerGas : 0n;
      let sendValue = balance - reserveWei - totalFee;
      if (sendValue <= 0n) return;

      const nonce = await provider.getTransactionCount(wallet.address, 'pending');

      const tx = await wallet.sendTransaction({
        to: dest,
        value: sendValue,
        gasLimit,
        maxFeePerGas,
        maxPriorityFeePerGas,
        nonce,
      });

      pendingTx = { hash: tx.hash, nonce, maxFeePerGas, maxPriorityFeePerGas };
      logLine(`ETH sent (${reason}): value=${ethers.formatEther(sendValue)} nonce=${nonce} maxFee=${toGwei(maxFeePerGas)} gwei tip=${toGwei(maxPriorityFeePerGas)} gwei tx=${tx.hash}`);
      logJson({ type:'eth_send', reason, value_eth: Number(ethers.formatEther(sendValue)), nonce, maxFee_gwei: toGwei(maxFeePerGas), tip_gwei: toGwei(maxPriorityFeePerGas), tx: tx.hash });
    } catch (e) {
      logLine(`ETH sweep error: ${e?.reason || e?.message || e}`);
      logJson({ type:'eth_error', message: e?.message || String(e) });
    } finally {
      sweeping = false;
    }
  }

  const net = await provider.getNetwork();
  logLine(`Connected chainId=${net.chainId} address=${wallet.address}`);
  provider.on('block', () => trySweep('block'));
  if (pollMs > 0) setInterval(() => trySweep('poll'), Math.max(1, pollMs));
  await trySweep('startup');
  logLine('ETH sweeper running… Press Ctrl+C to exit.');
  while (true) { await sleep(60_000); }
}

// -------- ERC-20 sweeper -----------
const ERC20_ABI = [
  'event Transfer(address indexed from, address indexed to, uint256 value)',
  'function balanceOf(address) view returns (uint256)',
  'function transfer(address to, uint256 amount) returns (bool)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)'
];

async function runTokenSweeper(cfg) {
  const { rpcUrl, privateKey, dest, tokenAddr, minReserveToken, pollMs, gasBumpPct, minTipGwei, minMaxFeeGwei } = cfg;

  const provider = rpcUrl.startsWith('ws')
    ? new ethers.WebSocketProvider(rpcUrl)
    : new ethers.JsonRpcProvider(rpcUrl);
  provider.pollingInterval = Math.max(50, pollMs);

  const wallet = new ethers.Wallet(privateKey, provider);
  const token = new ethers.Contract(tokenAddr, ERC20_ABI, wallet);

  let decimals = 18, symbol = 'TOKEN';
  try { decimals = await token.decimals(); } catch {}
  try { symbol = await token.symbol(); } catch {}

  let sweeping = false;
  let pendingTx = null;

  async function trySweep(reason='manual') {
    if (sweeping) return;
    sweeping = true;
    try {
      if (pendingTx) {
        const txOnChain = await provider.getTransaction(pendingTx.hash);
        if (txOnChain && !txOnChain.blockNumber) return;
        pendingTx = null;
      }

      const reserve = ethers.parseUnits(minReserveToken || '0', decimals);
      const bal = await token.balanceOf(wallet.address);
      const available = bal > reserve ? bal - reserve : 0n;
      if (available <= 0n) return;

      // need ETH for gas
      const ethBal = await provider.getBalance(wallet.address);
      if (ethBal === 0n) { logLine('Not enough ETH for gas.'); return; }

      let gasLimit = 0n;
      try {
        gasLimit = await token.estimateGas.transfer(dest, available);
        gasLimit = gasLimit + (gasLimit * 20n)/100n; // +20% safety
      } catch {
        gasLimit = 120000n; // fallback
      }

      let { maxFeePerGas, maxPriorityFeePerGas } = await getFeesBumped(provider, gasBumpPct, minTipGwei, minMaxFeeGwei);
      const nonce = await provider.getTransactionCount(wallet.address, 'pending');

      const tx = await token.transfer(dest, available, { gasLimit, maxFeePerGas, maxPriorityFeePerGas, nonce });
      pendingTx = { hash: tx.hash, nonce, maxFeePerGas, maxPriorityFeePerGas };

      logLine(`${symbol} sent (${reason}): amount=${ethers.formatUnits(available, decimals)} ${symbol} nonce=${nonce} maxFee=${toGwei(maxFeePerGas)} gwei tip=${toGwei(maxPriorityFeePerGas)} gwei tx=${tx.hash}`);
      logJson({ type:'token_send', symbol, amount: Number(ethers.formatUnits(available, decimals)), nonce, maxFee_gwei: toGwei(maxFeePerGas), tip_gwei: toGwei(maxPriorityFeePerGas), tx: tx.hash, token: tokenAddr });
    } catch (e) {
      logLine(`Token sweep error: ${e?.reason || e?.message || e}`);
      logJson({ type:'token_error', message: e?.message || String(e), token: tokenAddr });
    } finally {
      sweeping = false;
    }
  }

  const net = await provider.getNetwork();
  logLine(`Connected chainId=${net.chainId} address=${wallet.address} token=${symbol}@${tokenAddr}`);

  // Event listener (requires WS RPC). Fires on confirmations.
  try {
    const incoming = token.filters.Transfer(null, wallet.address);
    token.on(incoming, () => trySweep('event'));
    logLine('Subscribed to token Transfer events.');
  } catch {
    logLine('Event subscription unavailable; using polling only.');
  }

  if (pollMs > 0) setInterval(() => trySweep('poll'), Math.max(1, pollMs));
  await trySweep('startup');
  logLine('Token sweeper running… Press Ctrl+C to exit.');
  while (true) { await sleep(60_000); }
}

// -------- Interactive CLI (English) ----------
async function main() {
  console.log('EVM FCFS Sweeper (ETH or ERC-20)\n');

  const a = await inquirer.prompt([
    {
      type: 'list',
      name: 'assetType',
      message: 'What do you want to sweep?',
      choices: [
        { name: 'ETH (native coin)', value: 'ETH' },
        { name: 'ERC-20 token (requires contract address)', value: 'TOKEN' },
      ],
      default: process.env.TOKEN_ADDRESS ? 'TOKEN' : 'ETH',
    },
    {
      type: 'input',
      name: 'rpcUrl',
      message: 'RPC URL (prefer WebSocket for speed):',
      default: process.env.RPC_URL || 'wss://ethereum.publicnode.com',
      validate: (x) => (x && (x.startsWith('http') || x.startsWith('ws'))) ? true : 'Provide a valid http(s) or ws(s) URL',
    },
    {
      type: 'password',
      mask: '*',
      name: 'privateKey',
      message: 'Private key of the receiving wallet:',
      default: process.env.PRIVATE_KEY || undefined,
      validate: (x) => /^0x[0-9a-fA-F]{64}$/.test(x) ? true : 'Must be a 0x-prefixed 32-byte hex key',
    },
    {
      type: 'input',
      name: 'dest',
      message: 'Destination address to forward funds to:',
      default: process.env.DEST_ADDRESS || '',
      validate: (x) => /^0x[0-9a-fA-F]{40}$/.test(x) ? true : 'Must be a valid 0x-address',
    },
    {
      type: 'input',
      name: 'pollMs',
      message: 'Backup polling interval (ms) — 1–200ms is typical on good RPCs:',
      default: process.env.POLL_MS || '100',
      filter: (x) => Number(x),
      validate: (x) => !Number.isNaN(Number(x)) && Number(x) >= 0 ? true : 'Enter a non-negative number',
    },
    {
      type: 'input',
      name: 'gasBumpPct',
      message: 'Gas bump percent over suggested network fees:',
      default: process.env.GAS_BUMP_PCT || '50',
      validate: (x) => /^\d+$/.test(x) ? true : 'Enter an integer percent (e.g., 50)',
    },
    {
      type: 'input',
      name: 'minTipGwei',
      message: 'Minimum priority tip (gwei) to use (optional, default 0):',
      default: process.env.MIN_TIP_GWEI || '0',
      filter: (x) => Number(x),
      validate: (x) => !Number.isNaN(Number(x)) && Number(x) >= 0 ? true : 'Enter a non-negative number'
    },
    {
      type: 'input',
      name: 'minMaxFeeGwei',
      message: 'Minimum maxFeePerGas (gwei) to enforce (optional, default 0):',
      default: process.env.MIN_MAXFEE_GWEI || '0',
      filter: (x) => Number(x),
      validate: (x) => !Number.isNaN(Number(x)) && Number(x) >= 0 ? true : 'Enter a non-negative number'
    },
    // ETH-only
    {
      type: 'input',
      name: 'minReserveEth',
      message: '(ETH) Minimum ETH to keep in the wallet (for fees), in ETH:',
      default: process.env.MIN_RESERVE_ETH || '0.0001',
      when: (a) => a.assetType === 'ETH',
      validate: (x) => { try { ethers.parseEther(String(x)); return true; } catch { return 'Enter a valid ETH amount'; } },
    },
    // Token-only
    {
      type: 'input',
      name: 'tokenAddr',
      message: '(TOKEN) ERC-20 contract address:',
      default: process.env.TOKEN_ADDRESS || '',
      when: (a) => a.assetType === 'TOKEN',
      validate: (x) => /^0x[0-9a-fA-F]{40}$/.test(x) ? true : 'Must be a valid 0x-address',
    },
    {
      type: 'input',
      name: 'minReserveToken',
      message: '(TOKEN) Minimum token amount to keep (human units):',
      default: process.env.MIN_RESERVE_TOKEN || '0',
      when: (a) => a.assetType === 'TOKEN',
      validate: (x) => x !== '' ? true : 'Provide a number (e.g., 0 or 0.001)',
    },
  ]);

  const cfg = {
    rpcUrl: a.rpcUrl,
    privateKey: a.privateKey,
    dest: a.dest,
    pollMs: Number(a.pollMs),
    gasBumpPct: parsePercent(a.gasBumpPct, 0n),
    minTipGwei: Number(a.minTipGwei || 0),
    minMaxFeeGwei: Number(a.minMaxFeeGwei || 0),
  };

  if (a.assetType === 'ETH') {
    await runEthSweeper({ ...cfg, minReserveEth: String(a.minReserveEth) });
  } else {
    await runTokenSweeper({ ...cfg, tokenAddr: a.tokenAddr, minReserveToken: String(a.minReserveToken) });
  }
}

main().catch((e) => {
  logLine('FATAL: ' + (e?.message || String(e)));
  process.exit(1);
});
JS_EOF

chmod +x index.js

echo ">>> Starting the interactive sweeper…"
node index.js
