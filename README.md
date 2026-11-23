# Tremor

**Tremor makes arbitrageurs pay LPs for the gap, using Reactive to bring the real price across chains in about a second.**

Tremor is a cross-chain liquidity protection system for Uniswap v4, built on Reactive Omni for the Reactive Omni Buildathon, Track 1: *Every Second Counts*.

> **Status: in progress.** The Uniswap v4 hook and the Unichain callback receiver are written and tested. The Base price sources, the Reactive contract on Lasna, deployments and the experiment are next. This README grows as each part lands.

---

## The problem

Liquidity providers (LPs) put tokens into a pool so other people can trade. When the market price moves somewhere else first, the pool's price is out of date for a moment. Arbitrage bots trade against that stale price, buying cheap or selling high, until the pool catches up. The bots keep the gap as profit and the LPs pay for it.

This loss has a name: **LVR, loss-versus-rebalancing**. It is one of the largest hidden costs of providing liquidity. A normal fixed fee can't tell arbitrage apart from ordinary trading, so it can't charge arbitrage more.

## The idea

If the pool knew the real market price, it could tell which trades are exploiting the gap and charge them for it. That fee would stay with the LPs.

The hard part is getting the real price into the pool fast, from another chain, with no bot or server in the middle. That is what Reactive Omni does.

## How Tremor works

Tremor has three parts, one on each chain:

1. **Base Sepolia: price sources.** Two independent contracts report the market price and emit an event each time it moves.
2. **Reactive Lasna: the validation engine.** Tremor's reactive contract listens to both sources. It ignores tiny moves, checks that the two sources agree, scores how much it trusts the price, numbers each update, and asks Reactive to deliver it to Unichain.
3. **Unichain Sepolia: the receiver and the hook.**
   - `ReferenceStore` accepts updates only from Reactive's official callback proxy and only from Tremor's reactive contract, and keeps the latest one.
   - `TremorHook`, a Uniswap v4 hook, reads that reference on every swap, measures the live gap to the pool price, and sets the fee.

Lasna decides whether a price can be trusted. The hook works out the gap at the exact moment of each trade, so it is never out of date.

## The fee rule

Every swap pays the pool's normal fee, except trades that **move the pool toward the reference price**. Those trades are the ones taking value from LPs, so they pay a surcharge:

```
fee = min(maxFee, baseFee + beta × confidence × max(gap − baseFee − margin, 0))
```

| Setting | Meaning | Starting value |
| --- | --- | --- |
| `baseFee` | Normal pool fee | 30 bps |
| `gap` | Live gap between pool price and reference | measured on each swap |
| `confidence` | Trust in the reference, 0 to 100%, fading with age | from Lasna |
| `beta` | Share of the gap to capture | 70% |
| `margin` | Left to the arbitrageur for gas and price discovery | 10 bps |
| `maxFee` | Fee ceiling | 500 bps |

**Example.** With a 200 bps gap and 90% confidence, an arbitrage trade pays 30 + 0.7 × 0.9 × 160 = **130.8 bps**. A normal trade pays 30 bps. The arbitrageur still keeps about 69 bps, so it still corrects the pool.

**Why not charge the whole gap?** Then nobody would arbitrage and the pool would stay at the wrong price. Tremor takes most of the gap for LPs and leaves enough for arbitrage to happen. A fuzz test checks that the fee is always below the gap.

**When Tremor charges only the normal fee:**

- no reference has arrived yet;
- the reference is older than the maximum age;
- confidence is below the minimum (the two sources disagree, or the update is getting old);
- the trade moves the pool away from the reference;
- the gap is smaller than the normal fee plus the margin.

## Four modes, one hook

To measure what each part adds, the same hook can run a pool in four modes:

| Mode | Behaviour |
| --- | --- |
| `STATIC` (A) | Always the normal fee. The control pool. |
| `GAP` (B) | Surcharge on any trade when there's a gap. No direction check, no confidence. |
| `DIRECTIONAL` (C) | Surcharge only on trades toward the reference. No confidence. |
| `FULL` (D) | Full Tremor: direction, confidence and freshness. |

Every swap emits a `FeeQuoted` event with the gap, confidence, fee and the reason, so the experiment can measure exactly what each trade paid and why.

## Safety

| Threat | Protection |
| --- | --- |
| Fake price update | `ReferenceStore` accepts only Reactive's callback proxy and Tremor's reactive contract |
| Replayed old update | Sequence number must always increase |
| Late update | Maximum age; older references pay the normal fee |
| Bad values | Zero prices, confidence over 100% and future timestamps are rejected |
| Fee abuse | Fee ceiling of 10% in the hook, bounded settings, checked maths |
| Wrong pool type | The hook refuses pools without dynamic fees, and pools it hasn't been configured for |

## Repository layout

```
src/
  TremorHook.sol              Uniswap v4 hook (Unichain Sepolia)
  ReferenceStore.sol          Reactive callback receiver (Unichain Sepolia)
  interfaces/IReferenceSource.sol
  libraries/TremorFeeMath.sol The fee maths, kept separate so it can be tested on its own
test/
  TremorHook.t.sol            Hook tests against the real v4 PoolManager, including real swaps
  TremorFeeMath.t.sol         Fee maths, including a fuzz test that arbitrage always keeps a share
  ReferenceStore.t.sol        Callback authentication, replay and validation tests
```

## Run it

Requires [Foundry](https://book.getfoundry.sh/).

```bash
git clone --recurse-submodules https://github.com/Mhiah/Tremor
cd Tremor
forge build
forge test
```

Current result: **28 tests passing**.

## Networks

| Role | Network | Chain ID |
| --- | --- | --- |
| Price sources | Base Sepolia | 84532 |
| Validation engine | Reactive Lasna | 5318007 |
| Hook and receiver | Unichain Sepolia | 1301 |

Deployed addresses and transaction hashes will be listed here once deployed.

## Built with

- [Uniswap v4](https://developers.uniswap.org/docs/protocols/v4/deployments) (hooks, dynamic fees)
- [Reactive Omni](https://dev.reactive.network/) (`reactive-lib-omni`)
- [Foundry](https://book.getfoundry.sh/)

## License

MIT
