# Tremor

**Tremor makes arbitrageurs pay LPs for the gap, using Reactive to bring the real price across chains in about a second.**

Tremor is a cross-chain liquidity protection system for Uniswap v4, built on Reactive Omni for the Reactive Omni Buildathon, Track 1: *Every Second Counts*.

> **Status: live on testnet.** All four contracts are deployed and the full loop runs on-chain: a price move on Base Sepolia reaches the Tremor pool on Unichain Sepolia through Reactive Lasna in about 3 seconds, with no bot or server. The experiment (many price moves, LP value kept, latency curve) is next.

---

## The problem

Liquidity providers (LPs) put tokens into a pool so other people can trade. When the market price moves somewhere else first, the pool's price is out of date for a moment. Arbitrage bots trade against that stale price, buying cheap or selling high, until the pool catches up. The bots keep the gap as profit and the LPs pay for it.

This loss has a name: **LVR, loss-versus-rebalancing**. It is one of the largest hidden costs of providing liquidity. A normal fixed fee can't tell arbitrage apart from ordinary trading, so it can't charge arbitrage more.

## The idea

If the pool knew the real market price, it could tell which trades are exploiting the gap and charge them for it. That fee would stay with the LPs.

The hard part is getting the real price into the pool fast, from another chain, with no bot or server in the middle. That is what Reactive Omni does.

## How Tremor works

Tremor has three parts, one on each chain:

1. **Base Sepolia: two independent price sources.**
   - a Uniswap v4 pool on Base: every `Swap` event carries the pool's new price;
   - a `PriceSource` feed: a reporter posts the market price and it emits `PriceReported`.
2. **Reactive Lasna: the validation engine.** `TremorReactive` subscribes to both. On each event it:
   - checks the log really came from one of the two sources, in order, with a price inside sane bounds;
   - converts it to the Unichain pool's orientation and units;
   - combines the fresh sources into one reference (their midpoint) and a confidence score: 100% when they match, falling to 0% when they are 1% apart;
   - publishes only when the reference moved at least 5 bps, confidence changed at least 10 points, or 30 seconds have passed, so callbacks aren't wasted on noise;
   - numbers each update and asks Reactive to deliver it to Unichain.
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
| One source manipulated | The other source disagrees, confidence drops to 0 and the hook charges only the normal fee |
| Out-of-order or duplicate logs | `TremorReactive` ignores any log older than the last one it accepted from that source |
| Wasted callbacks | Small moves are filtered out on Lasna before a callback is paid for |
| Wrong pool type | The hook refuses pools without dynamic fees, and pools it hasn't been configured for |

## Repository layout

```
src/
  base/PriceSource.sol        Reported price feed (Base Sepolia)
  reactive/TremorReactive.sol Validation engine (Reactive Lasna)
  ReferenceStore.sol          Reactive callback receiver (Unichain Sepolia)
  TremorHook.sol              Uniswap v4 hook (Unichain Sepolia)
  interfaces/IReferenceSource.sol
  libraries/TremorFeeMath.sol The fee maths, kept separate so it can be tested on its own
test/
  TremorHook.t.sol            Hook tests against the real v4 PoolManager, including real swaps
  TremorFeeMath.t.sol         Fee maths, including a fuzz test that arbitrage always keeps a share
  TremorReactive.t.sol        Source matching, agreement, filtering, manipulation, and the callback
                              landing in the ReferenceStore end to end
  ReferenceStore.t.sol        Callback authentication, replay and validation tests
  PriceSource.t.sol           Reporter permissions and event shape
```

## Run it

Requires [Foundry](https://book.getfoundry.sh/).

To deploy your own copy, set `PRIVATE_KEY` and run, in order: `script/DeployBase.s.sol` (Base Sepolia), `script/DeployReactive.s.sol` (Lasna), `script/DeployUnichain.s.sol` (Unichain Sepolia), then `script/ConfigureReactive.s.sol` (Lasna). Each script lists the environment values it needs from the one before.

```bash
git clone --recurse-submodules https://github.com/Mhiah/Tremor
cd Tremor
forge build
forge test
```

Current result: **49 tests passing**.

## Networks

| Role | Network | Chain ID |
| --- | --- | --- |
| Price sources (v4 pool + PriceSource) | Base Sepolia | 84532 |
| Validation engine | Reactive Lasna | 5318007 |
| Hook and receiver | Unichain Sepolia | 1301 |

## Live deployment (testnet)

| Contract | Network | Address |
| --- | --- | --- |
| tETH / tUSD test tokens | Base Sepolia | `0x64419165D8e0e6fC7Edb69cB1c9061FF55dfa738` / `0xC4bf9ca099A4537E82b8b8aaDEBE69053C0b6181` |
| tETH/tUSD v4 pool (source 1) | Base Sepolia | PoolManager `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`, pool ID `0xded3b395…ad5b4` |
| PriceSource feed (source 2) | Base Sepolia | `0x813737EC15992C390E9C6471851B3c92FcCB4758` |
| TremorReactive | Reactive Lasna | `0x42338a1E7607CC56d19Adc97cD92dd9F9C5Dd512` |
| ReferenceStore | Unichain Sepolia | `0x508f12C53d3e57473291c544Df070A5e8B0464C5` |
| TremorHook | Unichain Sepolia | `0x6c19C2F3F2F8e976b6799d40c5049EcFEb22a080` |
| tETH / tUSD test tokens | Unichain Sepolia | `0x42338a1E7607CC56d19Adc97cD92dd9F9C5Dd512` / `0x64419165D8e0e6fC7Edb69cB1c9061FF55dfa738` |
| Static pool (mode A, control) | Unichain Sepolia | pool ID `0xf3709172…0836b` |
| Tremor pool (mode D) | Unichain Sepolia | pool ID `0x6e2eeb6d…0d178` |

The test tokens can be minted by anyone; they exist only to make a repeatable experiment.

### First full loop, on-chain

The market moved from 3,000 to 3,060 tUSD per tETH (+2%) on Base. Each update crossed three chains with no bot or server involved:

| Step | Base Sepolia (origin) | Reactive Lasna (validation) | Unichain Sepolia (callback) | Base event → Unichain |
| --- | --- | --- | --- | --- |
| Pool swap moves price to 3,060 | `0xb2a1ada23158938a91b3c99422455ab77edef10853ebf006d49b1e96547396fb` | `0xdcc2123f9c78309987ac89404d33261b7d4bada0c7a6564acd10fc3920ee37e7` (one source, 50% confidence) | `0x2350493ecca5a41df54108beb20fcddb5590449f883e1158cc39bb0fa848b769` | 3 s |
| Feed confirms 3,060 | `0xb0c5ae10222abba30c5413b7d1b79d37bee8e4f303446eb2fc000353c3659379` | `0xf3c610ee91abc73e6c8f5d65dd48c5f671710fdc1cc6fa87ff8ba08cfb517bbe` (sources agree, 100% confidence) | `0xff01afad8cc7a572d76bc69afd01f75e1817cb14a08b477da2fe1cad69e0abf4` | 3 s |

Latency here is measured from on-chain block timestamps, which have one-second resolution. The experiment will report medians over many runs.

### First live arbitrage, same trade into both pools

With the Unichain pools still at 3,000 and the reference at 3,060, the same 1,000 tUSD purchase of tETH went into each pool:

| Pool | Fee charged | tETH received | Transaction |
| --- | --- | --- | --- |
| Static (mode A) | 30 bps | 0.33233 | `0x9d7f0400290e3be4dfb4a64c6aa432de8fde9d7bce2713ee5acde38fd31cc063` |
| Tremor (mode D) | 86 bps | 0.33046 | `0x63309a5ac93ae5247769c62b3a52020c4ee051663202266b93182537cf1bc4c6` |

The arbitrage trade paid 56 bps more in the Tremor pool, and that difference stayed with the LPs. The surcharge was below the full rule's 118 bps because confidence had faded with the reference's age by the time of the trade, exactly as designed. An ordinary trade in the other direction was quoted the normal 30 bps.

## Built with

- [Uniswap v4](https://developers.uniswap.org/docs/protocols/v4/deployments) (hooks, dynamic fees)
- [Reactive Omni](https://dev.reactive.network/) (`reactive-lib-omni`)
- [Foundry](https://book.getfoundry.sh/)

## License

MIT
