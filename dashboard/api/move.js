// POST /api/move  { "direction": "up" | "down" }
//
// Moves Tremor's test market on Base Sepolia so a visitor can watch the Reactive loop run:
// a trade in the tETH/tUSD v4 pool plus a matching report from the price feed. Reactive Lasna
// then validates the move and updates the Tremor pool on Unichain, with no server involved after
// this point. This function only plays the part of "the market".
//
// Guards, all read from chain so the function keeps no state of its own:
//   - one move per minute, using the feed's own last-report time;
//   - refuses when the reactive contract's test REACT runs low, so the loop never stalls;
//   - keeps the market within 3.5% of the Unichain pool, so the gap stays meaningful.
//
// Needs one environment variable: MOVER_KEY, the key of a Base-Sepolia-only test wallet that
// holds test tokens and is an authorised reporter on the feed. It controls nothing else.

import { createPublicClient, createWalletClient, http, parseAbi, keccak256, encodeAbiParameters, formatEther } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";

const BASE_RPC = "https://sepolia.base.org";
const UNI_RPC = "https://sepolia.unichain.org";
const LASNA_RPC = "https://lasna-rpc.rnk.dev/";

const BASE_POOL_MANAGER = "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408";
const BASE_SWAP_ROUTER = "0x8B5bcC363ddE2614281aD875bad385E0A785D3B9";
const BASE_FEED = "0x813737EC15992C390E9C6471851B3c92FcCB4758";
const BASE_TETH = "0x64419165D8e0e6fC7Edb69cB1c9061FF55dfa738";
const BASE_TUSD = "0xC4bf9ca099A4537E82b8b8aaDEBE69053C0b6181";
const BASE_POOL_ID = "0xded3b3957073d52edec97ff673508f4546c5c75422380ee7331acd42294ad5b4";
const UNI_POOL_MANAGER = "0x00B036B58a818B1BC34d502D3fE730Db729e62AC";
const UNI_TREMOR_POOL_ID = "0x6e2eeb6deb906af28b24d7b3e5e12c51e9736a0a7fe7bb8d80ca6ac0d5a0d178";
const SYSTEM = "0x8888888888888888888888888888888888888888";
const REACTIVE = "0x42338a1E7607CC56d19Adc97cD92dd9F9C5Dd512";

const COOLDOWN_S = 60;
const MIN_RESERVES = 150000000000000000n; // 0.15 lREACT
const COST_PER_MOVE = 35000000000000000n; // ~0.035 lREACT: two reactions on Lasna
const MAX_GAP = 0.035;

const abi = parseAbi([
  "function extsload(bytes32 slot) view returns (bytes32)",
  "function latestAt() view returns (uint64)",
  "function report(uint256 priceX18)",
  "function reserves(address) view returns (uint256)",
  "function swap((address,address,uint24,int24,address) key, (bool,int256,uint160) params, (bool,bool) settings, bytes hookData) payable returns (int256)",
]);

const Q96 = 2n ** 96n;

function slot0Key(poolId) {
  return keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [poolId, 6n]));
}

async function poolPrice(client, pm, poolId) {
  const word = await client.readContract({ address: pm, abi, functionName: "extsload", args: [slot0Key(poolId)] });
  const sqrtP = BigInt(word) & ((1n << 160n) - 1n);
  return Number(sqrtP * sqrtP * 10n ** 18n / Q96 / Q96) / 1e18;
}

function sqrtX96(price) {
  // sqrt(price) * 2^96, computed with bigint for precision
  const scaled = BigInt(Math.round(price * 1e12)) * (2n ** 192n) / 10n ** 12n;
  let x = scaled, y = (x + 1n) / 2n;
  while (y < x) { x = y; y = (scaled / y + y) / 2n; }
  return x;
}

export async function getStatus() {
  const base = createPublicClient({ chain: baseSepolia, transport: http(BASE_RPC) });
  const lasna = createPublicClient({ transport: http(LASNA_RPC) });
  const [latestAt, reserves] = await Promise.all([
    base.readContract({ address: BASE_FEED, abi, functionName: "latestAt" }),
    lasna.readContract({ address: SYSTEM, abi, functionName: "reserves", args: [REACTIVE] }),
  ]);
  const now = Math.floor(Date.now() / 1000);
  const wait = Math.max(0, COOLDOWN_S - (now - Number(latestAt)));
  const movesLeft = reserves > MIN_RESERVES ? Number((reserves - MIN_RESERVES) / COST_PER_MOVE) : 0;
  return { waitSeconds: wait, movesLeft, reactReserves: formatEther(reserves) };
}

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  try {
    if (req.method === "GET") return res.status(200).json(await getStatus());
    if (req.method !== "POST") return res.status(405).json({ error: "Use POST to move the market." });
    if (!process.env.MOVER_KEY) return res.status(503).json({ error: "The move button isn't set up yet." });

    const status = await getStatus();
    if (status.waitSeconds > 0) {
      return res.status(429).json({ error: `The market just moved. Try again in ${status.waitSeconds} seconds.`, ...status });
    }
    if (status.movesLeft < 1) {
      return res.status(503).json({ error: "Tremor's test REACT is running low, so moves are paused to keep the loop alive.", ...status });
    }

    const body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
    let up = body.direction !== "down";

    const base = createPublicClient({ chain: baseSepolia, transport: http(BASE_RPC) });
    const uni = createPublicClient({ transport: http(UNI_RPC) });
    const [market, pool] = await Promise.all([
      poolPrice(base, BASE_POOL_MANAGER, BASE_POOL_ID),
      poolPrice(uni, UNI_POOL_MANAGER, UNI_TREMOR_POOL_ID),
    ]);

    const size = 0.015 + Math.random() * 0.01; // 1.5% to 2.5%
    let target = market * (up ? 1 + size : 1 - size);
    if (Math.abs(target / pool - 1) > MAX_GAP) {
      up = !up; // keep the gap to the Unichain pool meaningful
      target = market * (up ? 1 + size : 1 - size);
    }
    target = Math.round(target * 1e4) / 1e4;

    const account = privateKeyToAccount(process.env.MOVER_KEY);
    const wallet = createWalletClient({ account, chain: baseSepolia, transport: http(BASE_RPC) });
    const nonce = await base.getTransactionCount({ address: account.address, blockTag: "pending" });

    // tETH is currency0 in the Base pool, so its price is tUSD per tETH. Buying tETH pushes it up.
    const key = [BASE_TETH, BASE_TUSD, 3000, 60, "0x0000000000000000000000000000000000000000"];
    const swapTx = await wallet.writeContract({
      address: BASE_SWAP_ROUTER, abi, functionName: "swap",
      args: [key, [!up, -(10n ** 27n), sqrtX96(target)], [false, false], "0x"],
      nonce, gas: 300000n,
    });
    const feedTx = await wallet.writeContract({
      address: BASE_FEED, abi, functionName: "report",
      args: [BigInt(Math.round(target * 1e4)) * 10n ** 14n], nonce: nonce + 1, gas: 80000n,
    });

    return res.status(200).json({
      from: market, to: target, direction: up ? "up" : "down",
      baseSwapTx: swapTx, baseFeedTx: feedTx, sentAt: Date.now(), movesLeft: status.movesLeft - 1,
    });
  } catch (e) {
    return res.status(500).json({ error: "The move didn't go through. Try again in a minute.", detail: String(e.shortMessage || e.message || e).slice(0, 200) });
  }
}
