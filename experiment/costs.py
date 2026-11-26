"""Cost vs revenue: what each Reactive update cost on-chain, and what the surcharge paid Tremor LPs.

Reads every live trial in results/run-a and results/run-b, then from Unichain Sepolia:
- the Tremor pool's Swap event for each bot trade (amount in and the fee charged), and
- the gas used by each ReferenceStore callback.
Reactive-side gas is read from TremorReactive's transactions on Lasna (see LASNA_TXS below).
Writes results/costs.json.
"""
import csv, json, os, statistics as st
from web3 import Web3
HERE=os.path.dirname(os.path.abspath(__file__))
U = Web3(Web3.HTTPProvider("https://sepolia.unichain.org", request_kwargs={"timeout":30}))
PM = "0x00B036B58a818B1BC34d502D3fE730Db729e62AC".lower()
SWAP = Web3.keccak(text="Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)").hex()
if not SWAP.startswith("0x"): SWAP="0x"+SWAP
def s128(h): v=int(h,16); return v-(1<<256) if v>=1<<255 else v
rows=[]
for run in ("run-a","run-b"):
    rows += [dict(r, run=run) for r in csv.DictReader(open(os.path.join(HERE,"results",run,"trials.csv")))]
out=[]; refcost={}
for r in rows:
    rc = U.eth.get_transaction_receipt(r["tremor_tx"])
    lg=[l for l in rc["logs"] if l["address"].lower()==PM and ("0x"+l["topics"][0].hex().removeprefix("0x"))==SWAP]
    d=lg[0]["data"].hex().removeprefix("0x"); w=[d[i:i+64] for i in range(0,len(d),64)]
    a0,a1=s128(w[0]),s128(w[1]); fee=int(w[5],16)
    mkt=float(r["market_after"])
    # amounts from swapper view: negative = paid in
    if a0<0: inp_tusd = -a0/1e18*mkt
    else: inp_tusd = -a1/1e18
    sur = inp_tusd*max(fee-3000,0)/1e6
    allfee = inp_tusd*fee/1e6
    key=(r["run"],r["move"])
    if key not in refcost:
        rr=U.eth.get_transaction_receipt(r["ref_tx"]); refcost[key]=(rr["gasUsed"], rr["gasUsed"]*rr["effectiveGasPrice"]/1e18)
    out.append(dict(run=r["run"],move=r["move"],delay=float(r["delay_s"]),fee=fee,input_tusd=inp_tusd,surcharge_tusd=sur,fee_tusd=allfee,static_loss=float(r["static_lp_loss_tusd"]),tremor_loss=float(r["tremor_lp_loss_tusd"])))

L = Web3(Web3.HTTPProvider("https://lasna-rpc.rnk.dev/", request_kwargs={"timeout":30}))
REACTIVE = "0x42338a1E7607CC56d19Adc97cD92dd9F9C5Dd512"
# Latest TremorReactive transactions on Lasna (one per Base event: pool swap, feed report).
lasna=[]; n=L.eth.block_number; b=n; seen=set()
while len(lasna)<4 and b>n-400000:
    for l in L.eth.get_logs({"address":REACTIVE,"fromBlock":b-19999,"toBlock":b}):
        h=l["transactionHash"].to_0x_hex()
        if h in seen: continue
        seen.add(h); tx=L.eth.get_transaction(h); rc=L.eth.get_transaction_receipt(h)
        lasna.append({"tx":h,"gas":rc["gasUsed"],"gas_price_wei":tx["gasPrice"]})
    b-=20000
moves=len(refcost)
cb_gas=[v[0] for v in refcost.values()]
react_gas=st.median(x["gas"] for x in lasna)
sur=[o for o in out if o["fee"]>3000]
summary={
  "moves":moves, "bot_trades":len(out),
  "per_move":{"reactive_txs":2,"reactive_gas_each":react_gas,"reactive_gas_price_gwei":lasna[0]["gas_price_wei"]/1e9,
              "react_per_move":2*react_gas*lasna[0]["gas_price_wei"]/1e18,
              "unichain_callbacks":2,"callback_gas_each":st.median(cb_gas)},
  "lp_surcharge_tusd_total":sum(o["surcharge_tusd"] for o in out),
  "lp_surcharge_tusd_per_move":sum(o["surcharge_tusd"] for o in out)/moves,
  "median_fee_bps_on_arbitrage":st.median(o["fee"]/100 for o in sur),
  "median_surcharge_bps":st.median((o["fee"]-3000)/100 for o in sur),
  "lp_loss_tusd":{"static":sum(o["static_loss"] for o in out),"tremor":sum(o["tremor_loss"] for o in out)},
  "lasna_sample":lasna,
}
json.dump({"summary":summary,"trades":out,"callbacks":{f"{k[0]}:{k[1]}":v for k,v in refcost.items()}},
          open(os.path.join(HERE,"results","costs.json"),"w"),indent=1)
print(json.dumps(summary,indent=1))
