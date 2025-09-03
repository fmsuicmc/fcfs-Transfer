#!/usr/bin/env bash
set -euo pipefail

# EVM FCFS Sweeper (ETH + ERC-20) — auto installer & runner with console logs
PROJECT_DIR="${HOME}/evm-fcfs-sweeper"
NODE_VERSION="lts/*"

echo ">>> Checking curl..."
if ! command -v curl >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y curl
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y curl
  elif command -v brew >/dev/null 2>&1; then
    brew install curl
  else
    echo "Please install curl and re-run."; exit 1
  fi
fi

# Install nvm if missing
if [ -z "${NVM_DIR:-}" ]; then export NVM_DIR="$HOME/.nvm"; fi
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo ">>> Installing nvm..."
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi
# shellcheck disable=SC1090
. "$NVM_DIR/nvm.sh"

echo ">>> Installing Node.js ${NODE_VERSION}"
nvm install "${NODE_VERSION}" >/dev/null
nvm use "${NODE_VERSION}" >/dev/null
echo ">>> Node: $(node -v) | npm: $(npm -v)"

mkdir -p "${PROJECT_DIR}"
cd "${PROJECT_DIR}"

# package.json (ESM)
cat > package.json <<'PKG'
{
  "name": "evm-fcfs-sweeper",
  "version": "1.2.0",
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

echo ">>> Installing dependencies..."
npm i >/dev/null

# Optional defaults (می‌تونی بعداً ویرایش کنی)
if [ ! -f .env ]; then
cat > .env <<'ENVEOF'
# RPC_URL=wss://ethereum.publicnode.com
# PRIVATE_KEY=0xYOUR_PRIVATE_KEY
# DEST_ADDRESS=0xYourDestination
POLL_MS=50
GAS_BUMP_PCT=75
MIN_RESERVE_ETH=0.0001
# TOKEN_ADDRESS=0xYourToken
MIN_RESERVE_TOKEN=0
ENVEOF
fi

# Main app (always-verbose console logs)
cat > index.js <<'JS_EOF'
#!/usr/bin/env node
import 'dotenv/config';
import inquirer from 'inquirer';
import { ethers } from 'ethers';

// ---------- utils / logging ----------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const t = () => new Date().toISOString();
const toGwei = (wei) => Number(wei) / 1e9;
const bump = (x, pct) => (x ? (x * (100n + pct)) / 100n : undefined);

function logInfo(msg){ console.log(`[${t()}] ${msg}`); }
function logOk(msg){ console.log(`[${t()}] ✅ ${msg}`); }
function logWarn(msg){ console.log(`[${t()}] ⚠️  ${msg}`); }
function logErr(msg){ console.log(`[${t()}] ❌ ${msg}`); }

async function getFeesBumped(provider, gasBumpPctBig) {
  const fd = await provider.getFeeData();
  let { maxFeePerGas, maxPriorityFeePerGas, gasPrice } = fd;
  if (!maxFeePerGas) maxFeePerGas = gasPrice ?? 0n;
  if (!maxPriorityFeePerGas) maxPriorityFeePerGas = maxFeePerGas / 10n;
  return {
    maxFeePerGas: bump(maxFeePerGas, gasBumpPctBig),
    maxPriorityFeePerGas: bump(maxPriorityFeePerGas, gasBumpPctBig),
  };
}

// ---------- ETH sweeper (native coin) ----------
async function runEthSweeper(cfg) {
  const { rpcUrl, privateKey, dest, minReserveEth, pollMs, gasBumpPctBig } = cfg;

  const provider = rpcUrl.startsWith('ws')
    ? new ethers.WebSocketProvider(rpcUrl)
    : new ethers.JsonRpcProvider(rpcUrl);
  provider.pollingInterval = Math.max(10, pollMs);

  const wallet = new ethers.Wallet(privateKey, provider);
  let sweeping = false;
  let pendingTx = null; // {hash, nonce}

  async function trySweep(reason='poll') {
    if (sweeping) return;
    sweeping = true;
    try {
      // اگر TX قبلی هنوز pending است، دوباره نفرست
      if (pendingTx) {
        const txOnChain = await provider.getTransaction(pendingTx.hash);
        if (txOnChain && !txOnChain.blockNumber) {
          logInfo(`Pending tx still in mempool (nonce ${pendingTx.nonce}). Skipping...`);
          return;
        }
        pendingTx = null; // mined or dropped
      }

      const bal = await provider.getBalance(wallet.address, 'latest');
      const reserve = ethers.parseEther(minReserveEth || '0');
      if (bal <= reserve) {
        logInfo(`Checking... balance=${ethers.formatEther(bal)} ETH (no sweep)`);
        return;
      }

      const { maxFeePerGas, maxPriorityFeePerGas } = await getFeesBumped(provider, gasBumpPctBig);
      const gasLimit = 21000n;
      const totalFee = maxFeePerGas ? gasLimit * maxFeePerGas : 0n;
      const sendValue = bal - reserve - totalFee;
      if (sendValue <= 0n) {
        logWarn('Balance exists but insufficient for fees after reserve.');
        return;
      }

      const nonce = await provider.getTransactionCount(wallet.address, 'pending');
      logInfo(`Preparing ETH tx [${reason}] value=${ethers.formatEther(sendValue)} nonce=${nonce} maxFee=${toGwei(maxFeePerGas)}g tip=${toGwei(maxPriorityFeePerGas)}g`);

      const tx = await wallet.sendTransaction({
        to: dest,
        value: sendValue,
        gasLimit,
        maxFeePerGas,
        maxPriorityFeePerGas,
        nonce,
      });

      pendingTx = { hash: tx.hash, nonce };
      logOk(`ETH tx sent: ${tx.hash}`);
      // تایید را در پس‌زمینه گوش کن
      tx.wait().then(rcpt => {
        if (rcpt && rcpt.status === 1) {
          console.log(`[${t()}] ✔ Confirmed in block ${rcpt.blockNumber} (gasUsed=${rcpt.gasUsed})`);
        } else {
          console.log(`[${t()}] ✖ Tx failed (status 0)`);
        }
      }).catch(e => {
        logWarn(`Tx replaced or dropped: ${e?.message || e}`);
      });
    } catch (e) {
      logErr(e?.reason || e?.message || String(e));
    } finally { sweeping = false; }
  }

  const net = await provider.getNetwork();
  logInfo(`Connected chainId=${net.chainId} address=${wallet.address}`);
  provider.on('block', () => trySweep('block'));
  if (pollMs > 0) setInterval(() => trySweep('poll'), Math.max(1, pollMs));
  await trySweep('startup');

  logInfo('ETH sweeper running… Press Ctrl+C to exit.');
  while (true) { await sleep(60_000); }
}

// ---------- ERC-20 sweeper ----------
const ERC20_ABI = [
  'event Transfer(address indexed from, address indexed to, uint256 value)',
  'function balanceOf(address) view returns (uint256)',
  'function transfer(address to, uint256 amount) returns (bool)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)'
];

async function runTokenSweeper(cfg) {
  const { rpcUrl, privateKey, dest, tokenAddr, minReserveToken, pollMs, gasBumpPctBig } = cfg;

  const provider = rpcUrl.startsWith('ws')
    ? new ethers.WebSocketProvider(rpcUrl)
    : new ethers.JsonRpcProvider(rpcUrl);
  provider.pollingInterval = Math.max(10, pollMs);

  const wallet = new ethers.Wallet(privateKey, provider);
  const token = new ethers.Contract(tokenAddr, ERC20_ABI, wallet);

  let decimals = 18, symbol = 'TOKEN';
  try { decimals = await token.decimals(); } catch {}
  try { symbol = await token.symbol(); } catch {}

  let sweeping = false;
  let pendingTx = null;

  async function trySweep(reason='poll') {
    if (sweeping) return;
    sweeping = true;
    try {
      if (pendingTx) {
        const txOnChain = await provider.getTransaction(pendingTx.hash);
        if (txOnChain && !txOnChain.blockNumber) {
          logInfo(`Pending ${symbol} tx still in mempool (nonce ${pendingTx.nonce}). Skipping...`);
          return;
        }
        pendingTx = null;
      }

      const reserve = ethers.parseUnits(minReserveToken || '0', decimals);
      const bal = await token.balanceOf(wallet.address);
      if (bal <= reserve) {
        logInfo(`Checking ${symbol}... bal=${ethers.formatUnits(bal, decimals)} (no sweep)`);
        return;
      }

      // need ETH for gas
      const ethBal = await provider.getBalance(wallet.address);
      if (ethBal === 0n) { logWarn('Not enough ETH for gas.'); return; }

      // estimate gas (with safety)
      let gasLimit = 0n;
      try {
        gasLimit = await token.estimateGas.transfer(dest, bal - reserve);
        gasLimit = gasLimit + (gasLimit * 20n)/100n;
      } catch { gasLimit = 120000n; }

      const { maxFeePerGas, maxPriorityFeePerGas } = await getFeesBumped(provider, gasBumpPctBig);
      const nonce = await provider.getTransactionCount(wallet.address, 'pending');

      logInfo(`Preparing ${symbol} tx [${reason}] amount=${ethers.formatUnits(bal - reserve, decimals)} nonce=${nonce} maxFee=${toGwei(maxFeePerGas)}g tip=${toGwei(maxPriorityFeePerGas)}g`);

      const tx = await token.transfer(dest, bal - reserve, {
        gasLimit, maxFeePerGas, maxPriorityFeePerGas, nonce
      });

      pendingTx = { hash: tx.hash, nonce };
      logOk(`${symbol} tx sent: ${tx.hash}`);

      tx.wait().then(rcpt => {
        if (rcpt && rcpt.status === 1) {
          console.log(`[${t()}] ✔ ${symbol} confirmed in block ${rcpt.blockNumber} (gasUsed=${rcpt.gasUsed})`);
        } else {
          console.log(`[${t()}] ✖ ${symbol} tx failed (status 0)`);
        }
      }).catch(e => {
        logWarn(`${symbol} tx replaced or dropped: ${e?.message || e}`);
      });
    } catch (e) {
      logErr(e?.reason || e?.message || String(e));
    } finally { sweeping = false; }
  }

  const net = await provider.getNetwork();
  logInfo(`Connected chainId=${net.chainId} address=${wallet.address} token=${symbol}@${tokenAddr}`);

  // Event (WS) + polling
  try {
    const incoming = token.filters.Transfer(null, wallet.address);
    token.on(incoming, () => trySweep('event'));
    logInfo(`Subscribed to ${symbol} Transfer events.`);
  } catch { /* ignore if WS not available */ }

  if (pollMs > 0) setInterval(() => trySweep('poll'), Math.max(1, pollMs));
  await trySweep('startup');

  logInfo('Token sweeper running… Press Ctrl+C to exit.');
  while (true) { await sleep(60_000); }
}

// ---------- CLI (English, minimal prompts; logs always shown) ----------
async function main() {
  console.log('EVM FCFS Sweeper — Live console logs (ETH or ERC-20)\n');

  const a = await inquirer.prompt([
    {
      type: 'list',
      name: 'assetType',
      message: 'What do you want to sweep?',
      choices: [
        { name: 'ETH (native coin)', value: 'ETH' },
        { name: 'ERC-20 token (requires contract address)', value: 'TOKEN' }
      ],
      default: process.env.TOKEN_ADDRESS ? 'TOKEN' : 'ETH'
    },
    { type: 'input', name: 'rpcUrl', message: 'RPC URL (http(s) or ws(s)):', default: process.env.RPC_URL || '' },
    { type: 'password', mask: '*', name: 'privateKey', message: 'Private key (0x…64 hex):', default: process.env.PRIVATE_KEY || '',
      validate: (x)=>/^0x[0-9a-fA-F]{64}$/.test(x) ? true : 'Must be 0x + 64 hex' },
    { type: 'input', name: 'dest', message: 'Destination address:', default: process.env.DEST_ADDRESS || '',
      validate: (x)=>/^0x[0-9a-fA-F]{40}$/.test(x) ? true : 'Invalid 0x address' },
    { type: 'input', name: 'pollMs', message: 'Polling interval (ms):', default: process.env.POLL_MS || '50',
      filter: Number, validate: (x)=>!Number.isNaN(x) && x>=0 ? true : 'Enter >= 0' },
    { type: 'input', name: 'gasBumpPct', message: 'Gas bump percent over network suggestion:',
      default: process.env.GAS_BUMP_PCT || '75', filter: (x)=>BigInt(x), validate: (x)=>/^\d+$/.test(x) ? true : 'Enter integer' },

    // ETH only
    { type: 'input', name: 'minReserveEth', message: '(ETH) Minimum ETH to keep for fees:',
      default: process.env.MIN_RESERVE_ETH || '0.0001', when: (a)=>a.assetType==='ETH',
      validate: (x)=>{ try{ ethers.parseEther(String(x)); return true; } catch { return 'Invalid ETH amount'; } } },

    // Token only
    { type: 'input', name: 'tokenAddr', message: '(TOKEN) ERC-20 contract:',
      default: process.env.TOKEN_ADDRESS || '', when: (a)=>a.assetType==='TOKEN',
      validate: (x)=>/^0x[0-9a-fA-F]{40}$/.test(x) ? true : 'Invalid 0x address' },
    { type: 'input', name: 'minReserveToken', message: '(TOKEN) Minimum token to keep (human units):',
      default: process.env.MIN_RESERVE_TOKEN || '0', when: (a)=>a.assetType==='TOKEN',
      validate: (x)=>x!=='' ? true : 'Enter a number' }
  ]);

  const baseCfg = {
    rpcUrl: a.rpcUrl,
    privateKey: a.privateKey,
    dest: a.dest,
    pollMs: Number(a.pollMs),
    gasBumpPctBig: a.gasBumpPct
  };

  if (a.assetType === 'ETH') {
    await runEthSweeper({ ...baseCfg, minReserveEth: String(a.minReserveEth) });
  } else {
    await runTokenSweeper({ ...baseCfg, tokenAddr: a.tokenAddr, minReserveToken: String(a.minReserveToken) });
  }
}

main().catch((e) => {
  logErr(e?.message || String(e));
  process.exit(1);
});
JS_EOF

chmod +x index.js

echo ">>> Starting the sweeper..."
node index.js
