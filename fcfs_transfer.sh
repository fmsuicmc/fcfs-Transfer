#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Linea FCFS Sweeper – one-shot installer & runner
# Works on Linux/macOS with bash + curl
# -----------------------------

PROJECT_DIR="${HOME}/linea-fcfs-sweeper"
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
  # shellcheck disable=SC1090
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi

# shellcheck disable=SC1090
. "$NVM_DIR/nvm.sh"

echo ">>> Installing Node.js ${NODE_VERSION}"
nvm install "${NODE_VERSION}"
nvm use "${NODE_VERSION}"

echo ">>> Node: $(node -v), npm: $(npm -v)"

# --- Create project directory ---
mkdir -p "${PROJECT_DIR}"
cd "${PROJECT_DIR}"

# --- Create package.json if missing ---
if [ ! -f package.json ]; then
  echo ">>> Initializing npm project"
  npm init -y >/dev/null
fi

echo ">>> Installing dependencies (ethers, inquirer, dotenv)"
npm i ethers inquirer dotenv >/dev/null

# --- Create .env template (optional) ---
if [ ! -f .env ]; then
  cat > .env <<'ENVEOF'
# Optional defaults – the CLI will prompt if missing
RPC_URL=wss://rpc.linea.build
# PRIVATE_KEY=0xYOUR_PRIVATE_KEY
# DEST_ADDRESS=0xYourDestination
POLL_MS=150
GAS_BUMP_PCT=25
MIN_RESERVE_ETH=0.0001
# TOKEN_ADDRESS=0xYourTokenIfYouWantDefault
MIN_RESERVE_TOKEN=0
ENVEOF
fi

# --- Write index.js (interactive CLI, English) ---
cat > index.js <<'JS_EOF'
#!/usr/bin/env node
import 'dotenv/config';
import inquirer from 'inquirer';
import { ethers } from 'ethers';

// ---------- Helpers ----------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => new Date().toISOString();
const bump = (x, pct) => (x ? (x * (100n + pct)) / 100n : undefined);

function parsePercent(x, def = 0n) {
  try { return BigInt(String(x)); } catch { return def; }
}

// ---------- Fees ----------
async function getFeesBumped(provider, gasBumpPct) {
  const fd = await provider.getFeeData();
  let { maxFeePerGas, maxPriorityFeePerGas, gasPrice } = fd;
  if (!maxFeePerGas) maxFeePerGas = gasPrice ?? 0n;
  if (!maxPriorityFeePerGas) maxPriorityFeePerGas = maxFeePerGas / 10n;
  return {
    maxFeePerGas: bump(maxFeePerGas, gasBumpPct),
    maxPriorityFeePerGas: bump(maxPriorityFeePerGas, gasBumpPct),
  };
}

// ---------- ETH Sweeper ----------
async function runEthSweeper(cfg) {
  const { rpcUrl, privateKey, dest, minReserveEth, pollMs, gasBumpPctBig } = cfg;
  const provider = rpcUrl.startsWith('ws')
    ? new ethers.WebSocketProvider(rpcUrl)
    : new ethers.JsonRpcProvider(rpcUrl);
  provider.pollingInterval = 200;

  const wallet = new ethers.Wallet(privateKey, provider);
  let sweeping = false;

  async function trySweep(reason = 'manual') {
    if (sweeping) return;
    sweeping = true;
    try {
      const balance = await provider.getBalance(wallet.address, 'latest');
      const reserveWei = ethers.parseEther(minReserveEth || '0');
      if (balance <= reserveWei) return;

      const { maxFeePerGas, maxPriorityFeePerGas } = await getFeesBumped(provider, gasBumpPctBig);
      let gasLimit = 21000n; // standard
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
      console.log(`[${now()}] ETH sent (${reason}): ${ethers.formatEther(sendValue)} ETH  tx=${tx.hash}`);
    } catch (e) {
      console.error('ETH sweep error:', e?.reason || e?.message || e);
    } finally { sweeping = false; }
  }

  const net = await provider.getNetwork();
  console.log(`Connected to chainId=${net.chainId}  address=${wallet.address}`);
  provider.on('block', () => trySweep('block'));
  if (pollMs > 0) setInterval(() => trySweep('poll'), pollMs);
  await trySweep('startup');
  console.log('ETH sweeper running… Press Ctrl+C to exit.');
  while (true) { await sleep(60_000); }
}

// ---------- ERC-20 Sweeper ----------
const ERC20_ABI = [
  'event Transfer(address indexed from, address indexed to, uint256 value)',
  'function balanceOf(address) view returns (uint256)',
  'function transfer(address to, uint256 amount) returns (bool)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)',
];

async function runTokenSweeper(cfg) {
  const { rpcUrl, privateKey, dest, tokenAddr, minReserveToken, pollMs, gasBumpPctBig } = cfg;
  const provider = rpcUrl.startsWith('ws')
    ? new ethers.WebSocketProvider(rpcUrl)
    : new ethers.JsonRpcProvider(rpcUrl);
  provider.pollingInterval = 200;

  const wallet = new ethers.Wallet(privateKey, provider);
  const token = new ethers.Contract(tokenAddr, ERC20_ABI, wallet);

  let decimals = 18, symbol = 'TOKEN';
  try { decimals = await token.decimals(); } catch {}
  try { symbol = await token.symbol(); } catch {}

  let sweeping = false;

  async function trySweep(reason = 'manual') {
    if (sweeping) return;
    sweeping = true;
    try {
      const reserve = ethers.parseUnits(minReserveToken || '0', decimals);
      const bal = await token.balanceOf(wallet.address);
      const available = bal > reserve ? bal - reserve : 0n;
      if (available <= 0n) return;

      const ethBal = await provider.getBalance(wallet.address);
      if (ethBal === 0n) {
        console.warn(`[${now()}] Not enough ETH for gas; skipped.`);
        return;
      }

      let gasLimit = await token.estimateGas.transfer(dest, available);
      gasLimit = gasLimit + (gasLimit * 20n) / 100n;
      const { maxFeePerGas, maxPriorityFeePerGas } = await getFeesBumped(provider, gasBumpPctBig);
      const nonce = await provider.getTransactionCount(wallet.address, 'pending');

      const tx = await token.transfer(dest, available, {
        gasLimit, maxFeePerGas, maxPriorityFeePerGas, nonce,
      });
      console.log(`[${now()}] ${symbol} sent (${reason}): ${ethers.formatUnits(available, decimals)} ${symbol}  tx=${tx.hash}`);
    } catch (e) {
      console.error('Token sweep error:', e?.reason || e?.message || e);
    } finally { sweeping = false; }
  }

  const net = await provider.getNetwork();
  console.log(`Connected to chainId=${net.chainId}  address=${wallet.address}`);
  console.log(`Sweeping token ${symbol} at ${tokenAddr} (decimals=${decimals})`);

  try {
    const incomingFilter = token.filters.Transfer(null, wallet.address);
    token.on(incomingFilter, () => trySweep('event'));
  } catch {
    console.warn('Event subscription failed; falling back to polling only.');
  }

  if (pollMs > 0) setInterval(() => trySweep('poll'), pollMs);
  await trySweep('startup');
  console.log('Token sweeper running… Press Ctrl+C to exit.');
  while (true) { await sleep(60_000); }
}

// ---------- Interactive CLI ----------
async function main() {
  console.log('Linea FCFS Sweeper (ETH or ERC-20)\n');

  const answers = await inquirer.prompt([
    {
      type: 'list',
      name: 'assetType',
      message: 'What do you want to sweep?',
      choices: [
        { name: 'ETH (native coin of Linea)', value: 'ETH' },
        { name: 'ERC-20 token (requires contract address)', value: 'TOKEN' },
      ],
      default: process.env.TOKEN_ADDRESS ? 'TOKEN' : 'ETH',
    },
    {
      type: 'input',
      name: 'rpcUrl',
      message: 'RPC URL (prefer WebSocket for speed):',
      default: process.env.RPC_URL || 'wss://rpc.linea.build',
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
      message: 'Backup polling interval (ms) – 50–200ms is typical:',
      default: process.env.POLL_MS || '150',
      filter: (x) => Number(x),
      validate: (x) => !Number.isNaN(Number(x)) && Number(x) >= 0 ? true : 'Enter a non-negative number',
    },
    {
      type: 'input',
      name: 'gasBumpPct',
      message: 'Gas bump percent over network suggestion:',
      default: process.env.GAS_BUMP_PCT || '25',
      validate: (x) => /^\d+$/.test(x) ? true : 'Enter an integer percent (e.g., 25)',
    },
    {
      type: 'input',
      name: 'minReserveEth',
      message: '(ETH) Minimum ETH to keep in the wallet (for fees), in ETH:',
      default: process.env.MIN_RESERVE_ETH || '0.0001',
      when: (a) => a.assetType === 'ETH',
      validate: (x) => { try { ethers.parseEther(String(x)); return true; } catch { return 'Enter a valid ETH amount'; } },
    },
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

  const gasBumpPctBig = parsePercent(answers.gasBumpPct, 0n);

  if (answers.assetType === 'ETH') {
    await runEthSweeper({
      rpcUrl: answers.rpcUrl,
      privateKey: answers.privateKey,
      dest: answers.dest,
      minReserveEth: String(answers.minReserveEth),
      pollMs: Number(answers.pollMs),
      gasBumpPctBig,
    });
  } else {
    await runTokenSweeper({
      rpcUrl: answers.rpcUrl,
      privateKey: answers.privateKey,
      dest: answers.dest,
      tokenAddr: answers.tokenAddr,
      minReserveToken: String(answers.minReserveToken),
      pollMs: Number(answers.pollMs),
      gasBumpPctBig,
    });
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
JS_EOF

chmod +x index.js

# --- Run the app ---
echo ">>> Starting the interactive sweeper…"
node index.js
