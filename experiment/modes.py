#!/usr/bin/env python3
"""
Four modes, one market: what each part of Tremor adds.

Four Unichain pools, identical except for the hook's mode:
  A STATIC       always 0.30%                              (tick spacing 60)
  B GAP          surcharge on any trade when there's a gap (tick spacing 12)
  C DIRECTIONAL  surcharge only toward the reference       (tick spacing 18)
  D FULL         direction + confidence + freshness        (tick spacing 30)

Scenario 1, a real market move (both Base sources agree), repeated --moves times:
  once Tremor's update has landed, record the fee each mode would charge an arbitrageur and an
  ordinary trader going the other way, then let a rational bot arbitrage all four pools at once
  and record what each pool's LPs lost.

Scenario 2, a manipulated source (the feed pushed 5% away while the Base pool stays put):
  record the fee each mode would charge a trade toward the fake price.

Writes experiment/results/modes.json.
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

MODES = [("A", "static", 60), ("B", "gap", 12), ("C", "directional", 18), ("D", "full", 30)]


def setup(t):
    tok0, tok1, hook = t.static_key[0], t.static_key[1], t.static_key[4]
    pools = []
    for letter, name, spacing in MODES:
        key = (tok0, tok1, R.DYNAMIC_FEE, spacing, hook)
        pid = f"m{letter}"
        t.pool_ids[pid] = R.norm(R.pool_id(key))
        pools.append({"mode": letter, "name": name, "id": pid, "key": key})
    return pools


def reset(t, pools, price):
    R._reset_all(t, [{"static": (p["id"], p["key"]), "tremor": (p["id"], p["key"])} for p in pools[:1]] +
                 [{"static": (p["id"], p["key"]), "tremor": (p["id"], p["key"])} for p in pools[1:]], price)


def wait_ref(t, after_seq, price, need_conf=None, timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        ref = t.latest_ref()
        if ref["sequence"] > after_seq and abs(ref["price"] - price) / price < Decimal("0.002"):
            if need_conf is None or ref["conf"] >= need_conf:
                return ref
        time.sleep(0.4)
    return t.latest_ref()


def quotes(t, pools, adverse_zero_for_one):
    out = {}
    for p in pools:
        fa = t.hook.functions.quoteFee(p["key"], adverse_zero_for_one).call()
        fo = t.hook.functions.quoteFee(p["key"], not adverse_zero_for_one).call()
        out[p["mode"]] = {"arbitrage_fee_bps": fa[0] / 100, "ordinary_fee_bps": fo[0] / 100,
                          "arbitrage_reason": fa[1], "ordinary_reason": fo[1]}
    return out


def main(args):
    t = R.Tremor(dict(os.environ))
    pools = setup(t)
    rng = random.Random(args.seed)
    market = t.pool_price("base")
    reset(t, pools, market)
    record = {"modes": {m[0]: m[1] for m in MODES}, "moves": [], "manipulation": None}
    out_path = os.path.join(R.RESULTS, "modes.json")
    if args.manipulation_only and os.path.exists(out_path):
        record = json.load(open(out_path))

    for i in range(0 if args.manipulation_only else args.moves):
        move = Decimal(str(rng.uniform(0.015, 0.03))) * (1 if rng.random() < 0.5 else -1)
        target = (market * (1 + move)).quantize(Decimal("0.0001"))
        before = t.latest_ref()["sequence"]
        h_swap, h_feed = t.move_market(target)
        t.base.wait(h_swap)
        t.base.wait(h_feed)
        ref = wait_ref(t, before, target, need_conf=9000)
        adverse_z41 = target < t.pool_price("mA")  # arbitrage sells tETH when the market fell
        q = quotes(t, pools, adverse_z41)

        res = {}

        def bot(p):
            h, m = t.arb_key(p["id"], p["key"], target)
            r = t.swap_result(t.uni.wait(h), target) if h else {}
            res[p["mode"]] = {"lp_loss_tusd": (r or {}).get("arbProfit", 0.0), "fee_paid_bps": (r or {}).get("feePips", 0) / 100,
                              "tx": R.norm(h) if h else None}

        th = [threading.Thread(target=bot, args=(p,)) for p in pools]
        for x in th:
            x.start()
        for x in th:
            x.join()
        row = {"move": i + 1, "move_pct": float(move * 100), "from": float(market), "to": float(target),
               "reference_confidence_bps": ref["conf"], "base_swap_tx": R.norm(h_swap), "quotes": q, "arbitrage": res}
        record["moves"].append(row)
        print(f"move {i + 1}: {float(move * 100):+.2f}% conf {ref['conf']}")
        for p in pools:
            m = p["mode"]
            print(f"  {m} {p['name']:<11} arb fee {q[m]['arbitrage_fee_bps']:>6} | ordinary fee {q[m]['ordinary_fee_bps']:>6} | "
                  f"LP loss {res[m]['lp_loss_tusd']:>9.2f}")
        reset(t, pools, target)
        market = target
        time.sleep(3)

    # Scenario 2: manipulated feed.
    before = t.latest_ref()["sequence"]
    tiny = (market * Decimal("1.0001")).quantize(Decimal("0.0001"))
    h, _ = t.swap_to(t.base, t.base_router, t.base_key, t.pool_price("base"), tiny)
    t.base.wait(h)
    # Bring the feed back in line with the market so both sources are fresh and agree, and wait for
    # that 100%-confidence reference to land. Then the spike below is a clear change Lasna publishes.
    time.sleep(4)
    before = t.latest_ref()["sequence"]
    hr = t.base.send(t.feed.functions.report(int(tiny * 10**18)))
    t.base.wait(hr)
    wait_ref(t, before, tiny, need_conf=9000)
    mid = t.latest_ref()["sequence"]
    fake = (tiny * Decimal("1.05")).quantize(Decimal("0.0001"))
    hf = t.base.send(t.feed.functions.report(int(fake * 10**18)))
    t.base.wait(hf)
    end = time.time() + 60
    ref = t.latest_ref()
    while time.time() < end and ref["sequence"] <= mid:
        time.sleep(0.4)
        ref = t.latest_ref()
    q = quotes(t, pools, False)  # buying tETH moves the pool toward the fake, higher reference
    landed_age = int(time.time()) - ref["observedAt"]
    record["manipulation"] = {"market": float(tiny), "fake_feed_price": float(fake), "reference_price": float(ref["price"]),
                              "reference_confidence_bps": ref["conf"], "base_feed_spike_tx": R.norm(hf),
                              "reference_age_when_quoted_s": landed_age, "quotes": q,
                              "fee_toward_fake_price_bps": {k: v["arbitrage_fee_bps"] for k, v in q.items()},
                              "fee_other_direction_bps": {k: v["ordinary_fee_bps"] for k, v in q.items()}}
    print("manipulation:", json.dumps(record["manipulation"], indent=1))

    os.makedirs(R.RESULTS, exist_ok=True)
    with open(os.path.join(R.RESULTS, "modes.json"), "w") as f:
        json.dump(record, f, indent=2)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--moves", type=int, default=3)
    ap.add_argument("--seed", type=int, default=59)
    ap.add_argument("--manipulation-only", action="store_true")
    main(ap.parse_args())
