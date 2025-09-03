#!/usr/bin/env bash
set -euo pipefail

# ===== مسیر پروژه =====
PROJECT_DIR="$(pwd)"

# ===== نصب Node.js (نسخه 20) با nvm =====
if [ -z "${NVM_DIR:-}" ]; then export NVM_DIR="$HOME/.nvm"; fi
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo ">>> نصب nvm..."
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi
# shellcheck disable=SC1090
. "$NVM_DIR/nvm.sh"

NODE_VERSION="20"
nvm install $NODE_VERSION >/dev/null
nvm use $NODE_VERSION >/dev/null
echo ">>> Node: $(node -v) | npm: $(npm -v)"

# ===== ساخت package.json =====
cat > package.json <<'PKG'
{
  "name": "fcfs-transfer",
  "version": "1.0.0",
  "type": "module",
  "dependencies": {
    "ethers": "^6.13.2",
    "inquirer": "^9.2.15"
  }
}
PKG

echo ">>> نصب پکیج‌ها..."
npm install >/dev/null

# ===== ساخت index.js =====
cat > index.js <<'JS'
import inquirer from 'inquirer';
import { ethers } from 'ethers';

const t = () => new Date().toISOString();
const log = (m) => console.log(`[${t()}] ${m}`);
const ok = (m) => console.log(`[${t()}] ✅ ${m}`);
const err = (m) => console.log(`[${t()}] ❌ ${m}`);

async function getFees(provider, bumpPct=0n) {
  const fd = await provider.getFeeData();
  let { maxFeePerGas, maxPriorityFeePerGas, gasPrice } = fd;
  if (!maxFeePerGas) maxFeePerGas = gasPrice ?? 0n;
  if (!maxPriorityFeePerGas) maxPriorityFeePerGas = maxFeePerGas / 10n;
  return {
    maxFeePerGas: (maxFeePerGas * (100n+bumpPct)) / 100n,
    maxPriorityFeePerGas: (maxPriorityFeePerGas * (100n+bumpPct)) / 100n,
  };
}

// ===== ارسال با bump و retry =====
async function sendWithBump(sendFn, provider, maxRetries=5) {
  let bump = 20n;
  for (let i=0; i<maxRetries; i++) {
    try {
      const fees = await getFees(provider, bump);
      return await sendFn(fees);
    } catch(e) {
      err(`Send failed: ${e?.reason || e?.message || e}`);
      bump += 20n;
    }
  }
  err("All retries failed, skipping this round...");
  return null;
}

// ===== ETH Sweeper =====
async function sweepETH(provider, wallet, dest) {
  const bal = await provider.getBalance(wallet.address);
  if (bal === 0n) { log('Balance=0'); return; }

  await sendWithBump(async (fees) => {
    const gasLimit = 21000n;
    const fee = gasLimit * fees.maxFeePerGas;
    const value = bal - fee;
    if (value <= 0n) throw new Error('Not enough for fee');
    const nonce = await provider.getTransactionCount(wallet.address,'pending');
    const tx = await wallet.sendTransaction({
      to: dest, value, gasLimit,
      maxFeePerGas: fees.maxFeePerGas,
      maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
      nonce
    });
    ok(`ETH tx sent: ${tx.hash}`);
    await tx.wait();
    ok(`ETH tx confirmed in block ${await provider.getBlockNumber()}`);
  }, provider);
}

// ===== Token Sweeper =====
async function sweepToken(provider, wallet, dest, tokenAddr) {
  const abi = [
    'function balanceOf(address) view returns (uint256)',
    'function transfer(address,uint256) returns (bool)',
    'function decimals() view returns (uint8)',
    'function symbol() view returns (string)'
  ];
  const token = new ethers.Contract(tokenAddr, abi, wallet);
  const [bal, decimals, symbol, ethBal] = await Promise.all([
    token.balanceOf(wallet.address),
    token.decimals().catch(()=>18),
    token.symbol().catch(()=> 'TOKEN'),
    provider.getBalance(wallet.address)
  ]);
  if (bal === 0n) { log(`${symbol} balance=0`); return; }

  await sendWithBump(async (fees) => {
    let gasLimit;
    try { gasLimit = await token.estimateGas.transfer(dest, bal); }
    catch { gasLimit = 120000n; }
    gasLimit = gasLimit + gasLimit/5n;
    const fee = gasLimit * fees.maxFeePerGas;
    if (ethBal <= fee) throw new Error('Not enough ETH for gas');
    const nonce = await provider.getTransactionCount(wallet.address,'pending');
    const tx = await token.transfer(dest, bal, {
      gasLimit,
      maxFeePerGas: fees.maxFeePerGas,
      maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
      nonce
    });
    ok(`${symbol} tx sent: ${tx.hash}`);
    await tx.wait();
    ok(`${symbol} tx confirmed in block ${await provider.getBlockNumber()}`);
  }, provider);
}

// ===== CLI =====
async function main() {
  const a = await inquirer.prompt([
    {type:'list',name:'asset',message:'Sweep what?',choices:['ETH','TOKEN']},
    {type:'input',name:'rpcUrl',message:'RPC URL:'},
    {type:'password',mask:'*',name:'pk',message:'Private key (0x...)'},
    {type:'input',name:'dest',message:'Destination address:'},
    {type:'input',name:'token',message:'Token contract address:',when:(x)=>x.asset==='TOKEN'},
    {type:'input',name:'pollMs',message:'Polling interval (ms):',default:'100',filter:Number}
  ]);

  const provider = a.rpcUrl.startsWith('ws') ? new ethers.WebSocketProvider(a.rpcUrl) : new ethers.JsonRpcProvider(a.rpcUrl);
  provider.pollingInterval=a.pollMs;
  const wallet = new ethers.Wallet(a.pk,provider);
  log(`Connected to chainId ${(await provider.getNetwork()).chainId}, address=${wallet.address}`);

  if (a.asset==='ETH') {
    setInterval(()=>sweepETH(provider,wallet,a.dest),a.pollMs);
  } else {
    setInterval(()=>sweepToken(provider,wallet,a.dest,a.token),a.pollMs);
  }
}
main();
JS

# ===== اجرای بات =====
node index.js
