#!/usr/bin/env python3
"""
Fast-bot test: can an arbitrageur beat Tremor's update?

The earlier bots quoted the fee, estimated gas and then sent, which took 6 to 12 seconds over
public RPC. This bot does all of that in advance. It knows the new market price at the same moment
the market moves (as a bot watching another venue would), pre-signs its Unichain trades for both
the static and the Tremor pool, and broadcasts them at the same instant the Base trade goes out.

If its Tremor trade lands before Reactive's update, it pays only the normal fee: that is the
window Tremor cannot close, and its size is the loop latency. Writes experiment/results/fastbot.json.

Usage: python3 experiment/fastbot.py --moves 3
"""
import argparse
import json
import os
import random
import sys
import threading
import time
from decimal import Decimal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run as R  # noqa: E402

GAS = 450_000


def presign(chain, fn, nonce, gas_price):
    tx = fn.build_transaction({"from": chain.acct.address, "nonce": nonce, "chainId": chain.w3.eth.chain_id,
                               "gas": GAS, "maxFeePerGas": gas_price * 3, "maxPriorityFeePerGas": gas_price})
    return chain.acct.sign_transaction(tx).raw_transaction


def main(args):
    t = R.Tremor(dict(os.environ))
    rng = random.Random(args.seed)
    results = []
    market = t.pool_price("base")
    R._reset_all(t, [{"static": ("static", t.static_key), "tremor": ("tremor", t.tremor_key)}], market)

    for i in range(args.moves):
        move = Decimal(str(rng.uniform(0.015, 0.03))) * (1 if rng.random() < 0.5 else -1)
        target = (market * (1 + move)).quantize(Decimal("0.0001"))
        before = t.latest_ref()["sequence"]

        # Prepare everything before the market moves.
        uni_gas = t.uni.w3.eth.gas_price + 1
        nonce = t.uni.w3.eth.get_transaction_count(t.uni.acct.address, "pending")
        raws = {}
        for k, (name, key) in enumerate((("static", t.static_key), ("tremor", t.tremor_key))):
            p = t.pool_price(name)
            zero_for_one = target < p
            f = Decimal("0.003")  # the fee the bot expects: the update hasn't landed yet
            stop = target / (1 + f) if not zero_for_one else target / (1 - f)
            sq = R.sqrt_for(stop)
            fn = t.uni_router.functions.swap(key, (zero_for_one, -R.BIG_IN, sq), (False, False), b"")
            raws[name] = presign(t.uni, fn, nonce + k, uni_gas)
        t.uni.nonce = nonce + 2

        # Fire: Base trade and both Unichain trades at the same instant.
        sent = {}

        def fire_uni(name):
            sent[name] = t.uni.w3.eth.send_raw_transaction(raws[name])

        th = [threading.Thread(target=fire_uni, args=(n,)) for n in raws]
        t0 = time.time()
        for x in th:
            x.start()
        h_swap, h_feed = t.move_market(target)
        for x in th:
            x.join()

        rec = {name: t.uni.wait(h) for name, h in sent.items()}
        r_swap = t.base.wait(h_swap)
        t.base.wait(h_feed)
        base_ts = R.block_ts(t.base.w3, r_swap)
        seen, ref, ref_ts, ref_tx = R.wait_reference(t, before, target)

        row = {"move": i + 1, "move_pct": float(move * 100), "from": float(market), "to": float(target),
               "base_swap_tx": R.norm(h_swap), "base_ts": base_ts, "ref_tx": ref_tx, "ref_ts": ref_ts}
        for name, r in rec.items():
            res = t.swap_result(r, target) or {}
            row[f"{name}_tx"] = R.norm(sent[name])
            row[f"{name}_ts"] = R.block_ts(t.uni.w3, r)
            row[f"{name}_fee_bps"] = res.get("feePips", 0) / 100
            row[f"{name}_lp_loss_tusd"] = res.get("arbProfit", 0.0)
        row["tremor_landed_before_update"] = row["tremor_ts"] < ref_ts if ref_ts else None
        row["tremor_seconds_after_base"] = row["tremor_ts"] - base_ts
        results.append(row)
        print(json.dumps(row, indent=1))

        R._reset_all(t, [{"static": ("static", t.static_key), "tremor": ("tremor", t.tremor_key)}], target)
        market = target
        time.sleep(3)

    os.makedirs(R.RESULTS, exist_ok=True)
    with open(os.path.join(R.RESULTS, "fastbot.json"), "w") as f:
        json.dump(results, f, indent=2)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--moves", type=int, default=3)
    ap.add_argument("--seed", type=int, default=41)
    main(ap.parse_args())
