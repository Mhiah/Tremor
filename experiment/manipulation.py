#!/usr/bin/env python3
"""
Live manipulation test.

1. A tiny trade on the Base pool refreshes source 1 at the real market price.
2. Source 2 (the PriceSource feed) is then pushed 5% away from the market, as an attacker
   controlling one source would do.
3. Reactive Lasna sees the two sources disagree, publishes the reference with 0% confidence,
   and the Tremor hook on Unichain keeps charging only the normal fee.
4. A real trade toward the fake price goes into the Tremor pool to prove it on-chain: it pays
   0.30%, not the surcharge it would pay if the fake price were trusted.

Writes experiment/results/manipulation.json.
"""
import json
import os
import sys
import time
from decimal import Decimal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run as R  # noqa: E402

SPIKE = Decimal("0.05")


def main():
    t = R.Tremor(dict(os.environ))
    market = t.pool_price("base")
    before = t.latest_ref()["sequence"]
    out = {"market": float(market)}

    # 1. Refresh the pool source with a tiny real trade (+0.01%).
    tiny = (market * Decimal("1.0001")).quantize(Decimal("0.0001"))
    h, _ = t.swap_to(t.base, t.base_router, t.base_key, market, tiny)
    t.base.wait(h)
    out["base_pool_refresh_tx"] = R.norm(h)

    # Lasna may skip publishing a 1 bp move (it filters noise), so don't wait for a callback:
    # give Lasna a few seconds to record the fresh pool observation.
    time.sleep(6)
    mid_seq = t.latest_ref()["sequence"]

    # 2. Push the feed 5% above the market.
    fake = (tiny * (1 + SPIKE)).quantize(Decimal("0.0001"))
    h = t.base.send(t.feed.functions.report(int(fake * 10**18)))
    t.base.wait(h)
    out["fake_price"] = float(fake)
    out["base_feed_spike_tx"] = R.norm(h)

    # 3. Wait for Lasna's verdict to land on Unichain.
    deadline = time.time() + 60
    ref = t.latest_ref()
    while time.time() < deadline and ref["sequence"] <= mid_seq:
        time.sleep(0.5)
        ref = t.latest_ref()
    out["reference_after_spike"] = {"price": float(ref["price"]), "confidenceBps": ref["conf"], "sequence": ref["sequence"]}
    logs = t.uni.w3.eth.get_logs({"address": t.store_addr, "fromBlock": t.uni.w3.eth.block_number - 90, "topics": [R.REF_TOPIC]})
    out["unichain_reference_tx"] = R.norm(logs[-1]["transactionHash"]) if logs else None

    # 4. Quote, then make a real trade toward the fake price in the Tremor pool.
    fee, reason, gap, conf, adverse, seq = t.hook.functions.quoteFee(t.tremor_key, False).call()
    out["quote"] = {"feeBps": fee / 100, "reason": reason, "gapPips": gap, "confidenceBps": conf, "adverse": adverse}
    p = t.pool_price("tremor")
    h, _ = t.swap_to(t.uni, t.uni_router, t.tremor_key, p, p * Decimal("1.002"))
    r = t.uni.wait(h)
    res = t.swap_result(r, market)
    out["trade_tx"] = R.norm(h)
    out["trade_fee_bps"] = res["feePips"] / 100 if res else None
    # What the same trade would have paid had the fake price been trusted at 100%.
    g = Decimal(gap)
    out["fee_if_fake_price_trusted_bps"] = float(min(Decimal(50_000), 3000 + Decimal("0.7") * max(g - 4000, 0)) / 100)

    # Put the Tremor pool back where it was (housekeeping). Public RPC nodes can lag a block behind,
    # so re-read the price and retry rather than trust one read.
    for _ in range(5):
        try:
            time.sleep(2)
            h, _ = t.swap_to(t.uni, t.uni_router, t.tremor_key, t.pool_price("tremor"), p)
            t.uni.wait(h)
            break
        except Exception:
            continue

    os.makedirs(R.RESULTS, exist_ok=True)
    with open(os.path.join(R.RESULTS, "manipulation.json"), "w") as f:
        json.dump(out, f, indent=2)
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
