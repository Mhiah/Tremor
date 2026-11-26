#!/usr/bin/env python3
"""
Tremor experiment runner.

Each market move (all seven pool pairs are tested on the same move):
  1. The market moves on Base Sepolia: the Base v4 pool is swapped to a new price and the
     PriceSource feed reports the same price.
  2. Reactive Lasna validates the move and calls back the ReferenceStore on Unichain Sepolia.
  3. Seven bots, one per pool pair, each react a set time after the market moved (0 to 8 s) and
     trade both pools of their pair toward the new price: the STATIC control pool and the Tremor pool. The bot is rational: it reads the fee it
     will pay (hook.quoteFee) and stops where further trading stops being profitable.
  4. We record what the bot made in each pool, valued at the market price. That profit is exactly
     what the pool's LPs lost to arbitrage compared with a pool that always had the right price.
  5. Housekeeping (not measured): both Unichain pools are reset to the market price so every
     trial starts from the same state.

Bot reaction delays faster than the Reactive loop catch the Tremor pool before the new reference
lands; slower ones pay the surcharge. Plotting LP loss against delay gives the latency curve.

Usage:
  set -a; source <deployer env>; source <deployed env>; set +a
  python3 experiment/run.py --delays 0.5,1,2,3,4,6,8 --moves 6
Outputs experiment/results/trials.csv and experiment/results/summary.json.
"""
import argparse
import csv
import json
import os
import random
import statistics
import threading
import time
from decimal import Decimal, getcontext

from eth_account import Account
from web3 import Web3
from web3.providers.rpc.utils import REQUEST_RETRY_ALLOWLIST, ExceptionRetryConfiguration
import requests

getcontext().prec = 80
Q96 = 2**96
HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")

BASE_RPC = "https://sepolia.base.org"
UNI_RPC = "https://sepolia.unichain.org"
BASE_POOL_MANAGER = "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408"
BASE_SWAP_ROUTER = "0x8B5bcC363ddE2614281aD875bad385E0A785D3B9"
UNI_POOL_MANAGER = "0x00B036B58a818B1BC34d502D3fE730Db729e62AC"
UNI_SWAP_ROUTER = "0x9140a78c1A137c7fF1c151EC8231272aF78a99A4"
DYNAMIC_FEE = 0x800000
MIN_SQRT = 4295128739
MAX_SQRT = 1461446703485210103287273052203988822378723970342
BIG_IN = 10**27  # exact-in cap; swaps stop at the price limit long before this

KEY_T = "(address,address,uint24,int24,address)"
SWAP_ABI = [{
    "name": "swap", "type": "function", "stateMutability": "payable",
    "inputs": [
        {"name": "key", "type": "tuple", "components": [
            {"name": "currency0", "type": "address"}, {"name": "currency1", "type": "address"},
            {"name": "fee", "type": "uint24"}, {"name": "tickSpacing", "type": "int24"},
            {"name": "hooks", "type": "address"}]},
        {"name": "params", "type": "tuple", "components": [
            {"name": "zeroForOne", "type": "bool"}, {"name": "amountSpecified", "type": "int256"},
            {"name": "sqrtPriceLimitX96", "type": "uint160"}]},
        {"name": "testSettings", "type": "tuple", "components": [
            {"name": "takeClaims", "type": "bool"}, {"name": "settleUsingBurn", "type": "bool"}]},
        {"name": "hookData", "type": "bytes"}],
    "outputs": [{"name": "delta", "type": "int256"}]}]
FEED_ABI = [{"name": "report", "type": "function", "stateMutability": "nonpayable",
             "inputs": [{"name": "priceX18", "type": "uint256"}], "outputs": []}]
EXTSLOAD_ABI = [{"name": "extsload", "type": "function", "stateMutability": "view",
                 "inputs": [{"name": "slot", "type": "bytes32"}], "outputs": [{"name": "", "type": "bytes32"}]}]
STORE_ABI = [{"name": "latest", "type": "function", "stateMutability": "view", "inputs": [],
              "outputs": [{"name": "", "type": "tuple", "components": [
                  {"name": "priceX18", "type": "uint256"}, {"name": "observedAt", "type": "uint64"},
                  {"name": "sequence", "type": "uint64"}, {"name": "confidenceBps", "type": "uint16"}]}]}]
HOOK_ABI = [{"name": "quoteFee", "type": "function", "stateMutability": "view",
             "inputs": [{"name": "key", "type": "tuple", "components": SWAP_ABI[0]["inputs"][0]["components"]},
                        {"name": "zeroForOne", "type": "bool"}],
             "outputs": [{"name": "fee", "type": "uint24"}, {"name": "reason", "type": "uint8"},
                         {"name": "gapPips", "type": "uint256"}, {"name": "confidenceBps", "type": "uint256"},
                         {"name": "adverse", "type": "bool"}, {"name": "sequence", "type": "uint64"}]}]

SWAP_TOPIC = Web3.keccak(text="Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)").hex()
REF_TOPIC = Web3.keccak(text="ReferenceUpdated(uint64,uint256,uint64,uint16,uint64)").hex()


def norm(h):
    h = h if isinstance(h, str) else h.hex()
    return h if h.startswith("0x") else "0x" + h


def sqrt_for(price):
    return int(Decimal(price).sqrt() * Q96)


def price_from_sqrt(sqrtp):
    return (Decimal(sqrtp) / Q96) ** 2


def signed(word):
    v = int(word, 16)
    return v - (1 << 256) if v >> 255 else v


class Chain:
    def __init__(self, rpc, key):
        # Public RPCs and proxies drop connections now and then: retry reads with backoff.
        self.w3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={"timeout": 30},
                                         exception_retry_configuration=ExceptionRetryConfiguration(errors=(requests.exceptions.ConnectionError, requests.exceptions.Timeout), retries=10, backoff_factor=1.0, method_allowlist=REQUEST_RETRY_ALLOWLIST)))
        self.acct = Account.from_key(key)
        self.lock = threading.Lock()
        self.nonce = self.w3.eth.get_transaction_count(self.acct.address, "pending")

    def send(self, fn, gas=None):
        with self.lock:
            tx = fn.build_transaction({"from": self.acct.address, "nonce": self.nonce, "chainId": self.w3.eth.chain_id,
                                       "gas": gas or 800_000})
            if not gas:
                est = dict(tx)
                est.pop("gas", None)
                tx["gas"] = int(self.w3.eth.estimate_gas(est) * 1.3)
            signed_tx = self.acct.sign_transaction(tx)
            h = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)
            self.nonce += 1
            return h

    def wait(self, h):
        r = self.w3.eth.wait_for_transaction_receipt(h, timeout=120, poll_latency=0.2)
        if r["status"] != 1:
            raise RuntimeError(f"tx failed {norm(h)}")
        return r


class Tremor:
    def __init__(self, env):
        key = env["PRIVATE_KEY"]
        self.base = Chain(BASE_RPC, key)
        self.uni = Chain(UNI_RPC, key)
        b, u = self.base.w3, self.uni.w3
        cs = Web3.to_checksum_address
        self.base_key = (cs(env["BASE_TETH"]), cs(env["BASE_TUSD"]), 3000, 60, "0x" + "00" * 20)
        self.static_key = (cs(env["UNI_TETH"]), cs(env["UNI_TUSD"]), DYNAMIC_FEE, 60, cs(env["UNI_HOOK"]))
        self.tremor_key = (cs(env["UNI_TETH"]), cs(env["UNI_TUSD"]), DYNAMIC_FEE, 30, cs(env["UNI_HOOK"]))
        assert env["BASE_ETH_IS_CURRENCY0"] == "true" and env["UNI_ETH_IS_CURRENCY0"] == "true", "runner assumes tETH is currency0"
        self.base_router = b.eth.contract(cs(BASE_SWAP_ROUTER), abi=SWAP_ABI)
        self.uni_router = u.eth.contract(cs(UNI_SWAP_ROUTER), abi=SWAP_ABI)
        self.feed = b.eth.contract(cs(env["BASE_FEED"]), abi=FEED_ABI)
        self.base_pm = b.eth.contract(cs(BASE_POOL_MANAGER), abi=EXTSLOAD_ABI)
        self.uni_pm = u.eth.contract(cs(UNI_POOL_MANAGER), abi=EXTSLOAD_ABI)
        self.store = u.eth.contract(cs(env["UNI_REFERENCE_STORE"]), abi=STORE_ABI)
        self.store_addr = cs(env["UNI_REFERENCE_STORE"])
        self.hook = u.eth.contract(cs(env["UNI_HOOK"]), abi=HOOK_ABI)
        self.pool_ids = {"base": env["BASE_POOL_ID"], "static": env["UNI_STATIC_POOL_ID"], "tremor": env["UNI_TREMOR_POOL_ID"]}

    # --- reads -------------------------------------------------------
    def pool_price(self, which):
        pm = self.base_pm if which == "base" else self.uni_pm
        slot = Web3.keccak(bytes.fromhex(self.pool_ids[which][2:]) + (6).to_bytes(32, "big"))
        word = pm.functions.extsload(slot).call()
        return price_from_sqrt(int.from_bytes(word, "big") & ((1 << 160) - 1))

    def latest_ref(self):
        p, at, seq, conf = self.store.functions.latest().call()
        return {"price": Decimal(p) / Decimal(10**18), "observedAt": at, "sequence": seq, "conf": conf}

    # --- actions -----------------------------------------------------
    def swap_to(self, chain, router, key, current, target, limit_price=None):
        """Swap a pool toward `target`, stopping at `limit_price` (defaults to target)."""
        limit = limit_price if limit_price is not None else target
        zero_for_one = limit < current  # selling tETH pushes the price down
        sq = max(MIN_SQRT + 1, min(MAX_SQRT - 1, sqrt_for(limit)))
        fn = router.functions.swap(key, (zero_for_one, -BIG_IN, sq), (False, False), b"")
        return chain.send(fn), zero_for_one

    def move_market(self, target):
        current = self.pool_price("base")
        h_swap, _ = self.swap_to(self.base, self.base_router, self.base_key, current, target)
        h_feed = self.base.send(self.feed.functions.report(int(target * 10**18)))
        return h_swap, h_feed

    def arb(self, which, market):
        key = self.static_key if which == "static" else self.tremor_key
        p = self.pool_price(which)
        zero_for_one = market < p
        fee, reason, gap, conf, adverse, seq = self.hook.functions.quoteFee(key, zero_for_one).call()
        f = Decimal(fee) / Decimal(10**6)
        # Rational stop: buying tETH is worth it while pool price x (1 + f) < market;
        # selling while pool price x (1 - f) > market.
        stop = market / (1 + f) if not zero_for_one else market / (1 - f)
        if (not zero_for_one and stop <= p) or (zero_for_one and stop >= p):
            return None, {"pool": which, "quotedFee": fee, "reason": reason, "skipped": True}
        h, _ = self.swap_to(self.uni, self.uni_router, key, p, market, stop)
        return h, {"pool": which, "quotedFee": fee, "reason": reason, "gapPips": gap, "conf": conf,
                   "refSeq": seq, "poolPriceBefore": float(p)}

    def arb_key(self, name, key, market):
        """Rational arbitrage of one pool toward `market`: reads the fee first, stops where profit ends.
        Retries when a lagging RPC node gives an old price and the swap is refused before sending."""
        for attempt in range(3):
            try:
                return self._arb_key_once(name, key, market)
            except Exception:
                if attempt == 2:
                    raise
                time.sleep(1.5)

    def _arb_key_once(self, name, key, market):
        p = self.pool_price(name)
        zero_for_one = market < p
        fee, reason, gap, conf, adverse, seq = self.hook.functions.quoteFee(key, zero_for_one).call()
        f = Decimal(fee) / Decimal(10**6)
        stop = market / (1 + f) if not zero_for_one else market / (1 - f)
        if (not zero_for_one and stop <= p) or (zero_for_one and stop >= p):
            return None, {"quotedFee": fee, "reason": reason}
        h, _ = self.swap_to(self.uni, self.uni_router, key, p, market, stop)
        return h, {"quotedFee": fee, "reason": reason}

    def swap_result(self, receipt, market):
        for lg in receipt["logs"]:
            if norm(lg["topics"][0]) == norm(SWAP_TOPIC):
                d = norm(lg["data"])[2:]
                w = [d[i:i + 64] for i in range(0, len(d), 64)]
                a0, a1 = Decimal(signed(w[0])) / 10**18, Decimal(signed(w[1])) / 10**18
                fee = int(w[5], 16)
                profit = a0 * market + a1  # swapper's gain valued at the market price, in tUSD
                return {"amount0": float(a0), "amount1": float(a1), "feePips": fee, "arbProfit": float(profit)}
        return None


def block_ts(w3, receipt_or_log):
    """Block timestamp, from the log itself when the RPC includes it, else the block (retrying lagging nodes)."""
    logs = receipt_or_log.get("logs", [receipt_or_log])
    for lg in logs:
        ts = lg.get("blockTimestamp") if hasattr(lg, "get") else None
        if ts is not None:
            return int(ts, 16) if isinstance(ts, str) else int(ts)
    for _ in range(20):
        try:
            return w3.eth.get_block(receipt_or_log["blockNumber"])["timestamp"]
        except Exception:
            time.sleep(0.5)
    return None


def wait_reference(t, after_seq, target, timeout=40):
    """Poll the ReferenceStore until a reference at (about) the target lands. Returns (wall time, seq, receipt block ts)."""
    start = time.time()
    u = t.uni.w3
    while time.time() - start < timeout:
        ref = t.latest_ref()
        if ref["sequence"] > after_seq and abs(ref["price"] - target) / target < Decimal("0.001"):
            seen = time.time()
            logs = u.eth.get_logs({"address": t.store_addr, "fromBlock": u.eth.block_number - 90,
                                   "topics": [REF_TOPIC]})
            ts = None
            tx = None
            for lg in logs:
                if int(norm(lg["topics"][1]), 16) > after_seq:
                    ts, tx = block_ts(u, lg), norm(lg["transactionHash"])
                    break
            return seen, ref, ts, tx
        time.sleep(0.25)
    return None, None, None, None


class RefWatcher(threading.Thread):
    """Polls the ReferenceStore from the moment the market moves, so landing time is measured as it happens."""

    def __init__(self, t, after_seq, target):
        super().__init__(daemon=True)
        self.t, self.after_seq, self.target = t, after_seq, target
        self.seen_at = None
        self.stop_flag = False

    def run(self):
        start = time.time()
        while not self.stop_flag and time.time() - start < 40:
            try:
                ref = self.t.latest_ref()
                if ref["sequence"] > self.after_seq and abs(ref["price"] - self.target) / self.target < Decimal("0.001"):
                    self.seen_at = time.time()
                    return
            except Exception:
                pass
            time.sleep(0.2)


# Seven static/Tremor pool pairs, identical except tick spacing. One market move is tested against
# all of them at once, each pair arbitraged after a different bot reaction delay.
PAIRS = [(60, 30), (10, 12), (15, 18), (20, 27), (31, 36), (45, 53), (54, 62)]


def pool_id(key):
    from eth_abi import encode
    return Web3.keccak(encode(["address", "address", "uint24", "int24", "address"], list(key))).hex()


def run(args):
    env = dict(os.environ)
    t = Tremor(env)
    os.makedirs(RESULTS, exist_ok=True)
    rng = random.Random(args.seed)
    delays = [float(x) for x in args.delays.split(",")]
    assert len(delays) <= len(PAIRS), "one pool pair per delay"
    tok0, tok1, hook = t.static_key[0], t.static_key[1], t.static_key[4]
    pairs = []
    for (ss, ts), d in zip(PAIRS, delays):
        sk, tk = (tok0, tok1, DYNAMIC_FEE, ss, hook), (tok0, tok1, DYNAMIC_FEE, ts, hook)
        t.pool_ids[f"s{ss}"] = norm(pool_id(sk))
        t.pool_ids[f"t{ts}"] = norm(pool_id(tk))
        pairs.append({"delay": d, "static": (f"s{ss}", sk), "tremor": (f"t{ts}", tk)})

    market = t.pool_price("base")
    rows = []
    print(f"start market {float(market):.2f}, {args.moves} moves x {len(pairs)} delays")
    _reset_all(t, pairs, market)

    for i in range(args.moves):
        move = Decimal(str(rng.uniform(args.min_move, args.max_move))) * (1 if rng.random() < 0.5 else -1)
        if market > 3300:
            move = -abs(move)
        elif market < 2700:
            move = abs(move)
        target = (market * (1 + move)).quantize(Decimal("0.0001"))
        before = t.latest_ref()["sequence"]

        # 1. The market moves on Base.
        watcher = RefWatcher(t, before, target)
        watcher.start()
        t_move = time.time()  # the clock starts when the market moves (the Base trade is sent)
        h_swap, h_feed = t.move_market(target)

        # 2. One bot per pair, each reacting a set time after the market moved; both pools of a pair together.
        #    A delay of 0 is a bot that sees the new price at the same moment (for example, on another venue).
        t_base = t_move
        out = {}

        def bot(pair):
            time.sleep(max(0.0, pair["delay"] - (time.time() - t_base)))
            fired = time.time()
            sent = {}
            for mode in ("static", "tremor"):
                name, key = pair[mode]
                h, m = t.arb_key(name, key, target)
                sent[mode] = (h, m)
            res = {"fired_after_s": round(fired - t_base, 2)}
            for mode, (h, m) in sent.items():
                r = {"quotedFee": m.get("quotedFee"), "reason": m.get("reason")}
                if h:
                    rc = t.uni.wait(h)
                    r.update(t.swap_result(rc, target) or {})
                    r["tx"] = norm(h)
                    r["blockTs"] = block_ts(t.uni.w3, rc)
                res[mode] = r
            out[pair["delay"]] = res

        threads = [threading.Thread(target=bot, args=(p,)) for p in pairs]
        for th in threads:
            th.start()
        r_swap = t.base.wait(h_swap)
        t.base.wait(h_feed)
        base_ts = block_ts(t.base.w3, r_swap)
        for th in threads:
            th.join()

        # 3. When did the validated reference land on Unichain?
        seen, ref, uni_ts, uni_tx = wait_reference(t, before, target)
        watcher.join(timeout=45)
        if watcher.seen_at:
            seen = watcher.seen_at
        loop_wall = round(seen - t_base, 2) if seen else None

        for pair in pairs:
            res = out.get(pair["delay"], {})
            row = {
                "move": i + 1, "delay_s": pair["delay"], "fired_after_s": res.get("fired_after_s"),
                "move_pct": float(move * 100), "market_before": float(market), "market_after": float(target),
                "base_swap_tx": norm(h_swap), "base_feed_tx": norm(h_feed), "base_ts": base_ts,
                "ref_tx": uni_tx, "ref_ts": uni_ts, "ref_conf": ref["conf"] if ref else None,
                "loop_block_s": (uni_ts - base_ts) if uni_ts else None, "loop_wall_s": loop_wall,
            }
            for mode in ("static", "tremor"):
                r = res.get(mode, {})
                row[f"{mode}_fee_bps"] = (r.get("feePips", r.get("quotedFee") or 0)) / 100
                row[f"{mode}_reason"] = r.get("reason")
                row[f"{mode}_lp_loss_tusd"] = r.get("arbProfit", 0.0)
                row[f"{mode}_tx"] = r.get("tx")
            tb = res.get("tremor", {}).get("blockTs")
            row["tremor_trade_before_reference"] = (tb < uni_ts) if (tb and uni_ts) else None
            row["tremor_trade_ts"] = tb
            rows.append(row)
        print(f"move {i + 1}/{args.moves}: {float(move * 100):+.2f}% | loop {rows[-1]['loop_block_s']}s "
              f"(wall {loop_wall}s)")
        for pair in pairs:
            r = [x for x in rows if x["move"] == i + 1 and x["delay_s"] == pair["delay"]][0]
            print(f"   delay {pair['delay']:>4}s: static loss {r['static_lp_loss_tusd']:>9.2f} | tremor loss "
                  f"{r['tremor_lp_loss_tusd']:>9.2f} | tremor fee {r['tremor_fee_bps']:>6} bps")

        # 4. Housekeeping: reset every pool to the market price (not measured).
        _reset_all(t, pairs, target)
        market = target
        _write(rows)
        time.sleep(args.cooldown)

    summary = _summarise(rows)
    with open(os.path.join(RESULTS, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps(summary, indent=2))


def _reset_all(t, pairs, price):
    """Bring every pool exactly to `price`. Housekeeping only; never counted in results."""
    hashes = []
    seen = set()
    for pair in pairs:
        for mode in ("static", "tremor"):
            name, key = pair[mode]
            if name in seen:
                continue
            seen.add(name)
            for _ in range(3):
                p = t.pool_price(name)
                if abs(p - price) / price <= Decimal("0.00005"):
                    break
                try:
                    h, _ = t.swap_to(t.uni, t.uni_router, key, p, price)
                    hashes.append(h)
                    break
                except Exception:
                    # A lagging public RPC node can report an old price; the swap is then refused
                    # before it is sent. Read again and retry.
                    time.sleep(2)
    for h in hashes:
        t.uni.wait(h)


def _reset_unichain(t, price):
    """Bring both Unichain pools exactly to `price`. Housekeeping only; never counted in results."""
    for which in ("static", "tremor"):
        key = t.static_key if which == "static" else t.tremor_key
        p = t.pool_price(which)
        if abs(p - price) / price > Decimal("0.00005"):
            h, _ = t.swap_to(t.uni, t.uni_router, key, p, price)
            t.uni.wait(h)


def _write(rows):
    with open(os.path.join(RESULTS, "trials.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)


def _pct(xs, q):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def _summarise(rows):
    loops = [r["loop_block_s"] for r in rows if r["loop_block_s"] is not None]
    walls = [r["loop_wall_s"] for r in rows if r["loop_wall_s"] is not None]
    by_delay = {}
    for r in rows:
        d = by_delay.setdefault(r["delay_s"], {"static": [], "tremor": []})
        d["static"].append(r["static_lp_loss_tusd"])
        d["tremor"].append(r["tremor_lp_loss_tusd"])
    curve = []
    for delay in sorted(by_delay):
        s, tr = sum(by_delay[delay]["static"]), sum(by_delay[delay]["tremor"])
        curve.append({"delay_s": delay, "trials": len(by_delay[delay]["static"]),
                      "static_lp_loss_tusd": round(s, 4), "tremor_lp_loss_tusd": round(tr, 4),
                      "lp_loss_avoided_pct": round(100 * (1 - tr / s), 1) if s > 0 else None})
    s_all = sum(r["static_lp_loss_tusd"] for r in rows)
    t_all = sum(r["tremor_lp_loss_tusd"] for r in rows)
    return {
        "trials": len(rows),
        "loop_latency_block_s": {"median": statistics.median(loops) if loops else None, "p95": _pct(loops, 0.95),
                                 "min": min(loops) if loops else None, "max": max(loops) if loops else None},
        "loop_latency_wall_s": {"median": statistics.median(walls) if walls else None, "p95": _pct(walls, 0.95)},
        "total_lp_loss_tusd": {"static": round(s_all, 4), "tremor": round(t_all, 4),
                               "avoided_pct": round(100 * (1 - t_all / s_all), 1) if s_all > 0 else None},
        "by_delay": curve,
        "notes": "LP loss = arbitrageur profit valued at the market price, i.e. loss versus a pool that always had "
                 "the right price. Delays are a controlled experiment: the bot is our own script.",
    }


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--delays", default="0.5,1,2,3,4,6,8")
    ap.add_argument("--moves", type=int, default=6)
    ap.add_argument("--min-move", type=float, default=0.01)
    ap.add_argument("--max-move", type=float, default=0.03)
    ap.add_argument("--cooldown", type=float, default=2.0)
    ap.add_argument("--seed", type=int, default=7)
    run(ap.parse_args())
