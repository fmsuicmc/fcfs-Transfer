#!/usr/bin/env node
import 'dotenv/config';
import inquirer from 'inquirer';
import { ethers } from 'ethers';

// ---------- utils ----------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const t = () => new Date().toISOString();
const toGwei = (wei) => Number(wei) / 1e9;
const bump = (x, pct) => (x ? (x * (100n + pct)) / 100n : undefined);

function ok(m){ console.log(`[${t()}] ✅ ${m}`); }
function info(m){ console.log(`[${t()}] ${m}`); }
function warn(m){ console.log(`[${t()}] ⚠️  ${m}`); }
function err(m){ console.log(`[${t()}] ❌ ${m}`); }

async function getFees(provider, bumpPctBig) {
  const fd = await provider.getFeeData();
  let { maxFeePerGas, maxPriorityFeePerGas, gasPrice } = fd;
  if (!maxFeePerGas) maxFeePerGas = gasPrice ?? 0n;
  if (!maxPriorityFeePerGas) maxPriorityFeePerGas = maxFeePerGas / 10n;

  try {
    const blk = await provider.getBlock('latest');
    const base = BigInt(blk?.baseFeePerGas ?? 0);
    if (maxFeePerGas < base + maxPriorityFeePerGas) {
      maxFeePerGas = base + maxPriorityFeePerGas;
    }
  } catch {}
  return {
    maxFeePerGas: bump(maxFeePerGas, bumpPctBig),
    maxPriorityFeePerGas: bump(maxPriorityFeePerGas, bumpPctBig),
  };
}

// ---------- ETH sweeper ----------
async function runEthSweeper({ rpcUrl, privateKey, dest, minReserveEth, pollMs, gasBumpPctBig }) {
  const provider = rpcUrl.startsWith('ws') ? new ethers.WebSocketProvider(rpcUrl) : new ethers.JsonRpcProvider(rpcUrl);
  provider.pollingInterval = Math.max(10, pollMs);

  const wallet = new ethers.Wallet(privateKey, provider);
  let sweeping = false;
  let pendingTx = null;

  async function trySweep(reason='poll') {
    if (sweeping) return;
    sweeping = true;
    try {
      if (pendingTx) {
        const onchain = await provider.getTransaction(pendingTx.hash);
        if (onchain && !onchain.blockNumber) {
          info(`Pending tx (nonce ${pendingTx.nonce}) still in mempool. Skipping…`);
          return;
        }
        pendingTx = null;
      }

      const [balance, fees] = await Promise.all([
        provider.getBalance(wallet.address, 'latest'),
        getFees(provider, gasBumpPctBig),
      ]);

      const reserveWei = ethers.parseEther(minReserveEth || '0');
      if (balance <= reserveWei) {
        info(`Checking… balance=${ethers.formatEther(balance)} ETH (no sweep)`);
        return;
      }

      const gasLimit = 21000n;
      const fee = gasLimit * fees.maxFeePerGas;
      const boostedFee = fee * 2n; // double fee for safety

      let sendValue = balance - reserveWei - boostedFee;
      if (sendValue <= 0n) {
        info(`Balance too low after boosted fee. Skipping…`);
        return;
      }

      const nonce = await provider.getTransactionCount(wallet.address, 'pending');
      info(`Preparing ETH tx [${reason}] value=${ethers.formatEther(sendValue)} nonce=${nonce} maxFee=${toGwei(fees.maxFeePerGas)}g tip=${toGwei(fees.maxPriorityFeePerGas)}g`);

      const tx = await wallet.sendTransaction({
        to: dest,
        value: sendValue,
        gasLimit,
        maxFeePerGas: fees.maxFeePerGas,
        maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
        nonce,
      });

      pendingTx = { hash: tx.hash, nonce };
      ok(`ETH tx sent: ${tx.hash}`);

      tx.wait().then(rcpt => {
        if (rcpt?.status === 1) console.log(`[${t()}] ✔ Confirmed in block ${rcpt.blockNumber} (gasUsed=${rcpt.gasUsed})`);
        else console.log(`[${t()}] ✖ Tx failed (status 0)`);
      }).catch(e => warn(`Tx replaced/dropped: ${e?.message || e}`));
    } catch (e) {
      err(e?.reason || e?.message || String(e));
    } finally { sweeping = false; }
  }

  const net = await provider.getNetwork();
  info(`Connected chainId=${net.chainId} address=${wallet.address}`);
  provider.on('block', () => trySweep('block'));
  if (pollMs > 0) setInterval(() => trySweep('poll'), pollMs);
  await trySweep('startup');
  info('ETH sweeper running… Ctrl+C to exit.');
  while (true) { await sleep(60_000); }
}

// ---------- Token sweeper ----------
const ERC20_ABI = [
  'event Transfer(address indexed from, address indexed to, uint256 value)',
  'function balanceOf(address) view returns (uint256)',
  'function transfer(address to, uint256 amount) returns (bool)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)'
];

async function runTokenSweeper({ rpcUrl, privateKey, dest, tokenAddr, minReserveToken, pollMs, gasBumpPctBig }) {
  const provider = rpcUrl.startsWith('ws') ? new ethers.WebSocketProvider(rpcUrl) : new ethers.JsonRpcProvider(rpcUrl);
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
        const onchain = await provider.getTransaction(pendingTx.hash);
        if (onchain && !onchain.blockNumber) { info(`Pending ${symbol} tx… Skipping`); return; }
        pendingTx = null;
      }

      const [tokBal, fees, ethBal] = await Promise.all([
        token.balanceOf(wallet.address),
        getFees(provider, gasBumpPctBig),
        provider.getBalance(wallet.address, 'latest'),
      ]);

      const reserveTok = ethers.parseUnits(minReserveToken || '0', decimals);
      let sendTok = tokBal > reserveTok ? (tokBal - reserveTok) : 0n;
      if (sendTok <= 0n) { info(`${symbol} balance too low (no sweep)`); return; }

      // estimate gas
      let gasLimit;
      try {
        gasLimit = await token.estimateGas.transfer(dest, sendTok);
        gasLimit = gasLimit + (gasLimit * 20n)/100n;
      } catch { gasLimit = 120000n; }

      const fee = gasLimit * fees.maxFeePerGas;
      const boostedFee = fee * 2n;

      if (ethBal <= boostedFee) {
        info(`Not enough ETH for ${symbol} gas after boosted fee.`);
        return;
      }

      const nonce = await provider.getTransactionCount(wallet.address, 'pending');
      info(`Preparing ${symbol} tx [${reason}] amount=${ethers.formatUnits(sendTok, decimals)} nonce=${nonce} maxFee=${toGwei(fees.maxFeePerGas)}g tip=${toGwei(fees.maxPriorityFeePerGas)}g`);

      const tx = await token.transfer(dest, sendTok, {
        gasLimit,
        maxFeePerGas: fees.maxFeePerGas,
        maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
        nonce,
      });

      pendingTx = { hash: tx.hash, nonce };
      ok(`${symbol} tx sent: ${tx.hash}`);

      tx.wait().then(rcpt => {
        if (rcpt?.status === 1) console.log(`[${t()}] ✔ ${symbol} confirmed in block ${rcpt.blockNumber}`);
        else console.log(`[${t()}] ✖ ${symbol} tx failed (status 0)`);
      }).catch(e => warn(`${symbol} tx replaced/dropped: ${e?.message || e}`));
    } catch (e) {
      err(e?.reason || e?.message || String(e));
    } finally { sweeping = false; }
  }

  const net = await provider.getNetwork();
  info(`Connected chainId=${net.chainId} address=${wallet.address} token=${symbol}@${tokenAddr}`);
  try {
    const incoming = token.filters.Transfer(null, wallet.address);
    token.on(incoming, () => trySweep('event'));
    info(`Subscribed to ${symbol} Transfer events.`);
  } catch {}
  if (pollMs > 0) setInterval(() => trySweep('poll'), pollMs);
  await trySweep('startup');
  info('Token sweeper running… Ctrl+C to exit.');
  while (true) { await sleep(60_000); }
}

// ---------- CLI ----------
async function main() {
  console.log('EVM FCFS Sweeper — Full sweep (ETH + Tokens)\n');
  const a = await inquirer.prompt([
    { type: 'list', name: 'assetType', message: 'What do you want to sweep?', choices: [
        { name: 'ETH (native coin)', value: 'ETH' },
        { name: 'ERC-20 token', value: 'TOKEN' }
      ], default: process.env.TOKEN_ADDRESS ? 'TOKEN' : 'ETH' },
    { type: 'input', name: 'rpcUrl', message: 'RPC URL:', default: process.env.RPC_URL || '' },
    { type: 'password', mask: '*', name: 'privateKey', message: 'Private key (0x…):', default: process.env.PRIVATE_KEY || '' },
    { type: 'input', name: 'dest', message: 'Destination address:', default: process.env.DEST_ADDRESS || '' },
    { type: 'input', name: 'pollMs', message: 'Polling interval (ms):', default: process.env.POLL_MS || '50', filter: Number },
    { type: 'input', name: 'gasBumpPct', message: 'Gas bump percent over network suggestion:', default: process.env.GAS_BUMP_PCT || '75', filter: (x)=>BigInt(x) },
    { type: 'input', name: 'minReserveEth', message: '(ETH) Minimum ETH to keep:', default: process.env.MIN_RESERVE_ETH || '0.0001', when: (a)=>a.assetType==='ETH' },
    { type: 'input', name: 'tokenAddr', message: '(TOKEN) ERC-20 contract:', default: process.env.TOKEN_ADDRESS || '', when: (a)=>a.assetType==='TOKEN' },
    { type: 'input', name: 'minReserveToken', message: '(TOKEN) Minimum token to keep:', default: process.env.MIN_RESERVE_TOKEN || '0', when: (a)=>a.assetType==='TOKEN' }
  ]);

  const baseCfg = { rpcUrl: a.rpcUrl, privateKey: a.privateKey, dest: a.dest, pollMs: Number(a.pollMs), gasBumpPctBig: a.gasBumpPct };

  if (a.assetType === 'ETH') {
    await runEthSweeper({ ...baseCfg, minReserveEth: String(a.minReserveEth) });
  } else {
    await runTokenSweeper({ ...baseCfg, tokenAddr: a.tokenAddr, minReserveToken: String(a.minReserveToken) });
  }
}
main().catch((e)=>{ err(e?.message || String(e)); process.exit(1); });
