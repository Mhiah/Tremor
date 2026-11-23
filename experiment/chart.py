#!/usr/bin/env python3
"""Draws the experiment chart for the README from experiment/results/run-*/trials.csv."""
import csv
import glob
import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
SURFACE, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e1"
STATIC, TREMOR = "#2a78d6", "#eb6834"  # categorical slots 1 and 2


def load():
    rows = []
    for path in sorted(glob.glob(os.path.join(HERE, "results", "run-*", "trials.csv"))):
        run = os.path.basename(os.path.dirname(path))[-1].upper()
        for r in csv.DictReader(open(path)):
            r["run"] = run
            rows.append(r)
    return rows


def main():
    rows = load()
    moves = []
    for key in sorted({(r["run"], int(r["move"])) for r in rows}):
        g = [r for r in rows if (r["run"], int(r["move"])) == key]
        saw = [r for r in g if r["tremor_reason"] == "0"]  # bots that traded with Tremor's update in place
        static = float(g[0]["static_lp_loss_tusd"])
        tremor = sum(float(r["tremor_lp_loss_tusd"]) for r in saw) / len(saw) if saw else None
        moves.append((key, abs(float(g[0]["move_pct"])), static, tremor))

    fig, ax = plt.subplots(figsize=(10, 4.6), dpi=200)
    fig.patch.set_facecolor(SURFACE)
    ax.set_facecolor(SURFACE)
    x = range(len(moves))
    w = 0.38
    ax.bar([i - w / 2 - 0.01 for i in x], [m[2] for m in moves], w, color=STATIC, label="Static pool (normal 0.30% fee)")
    ax.bar([i + w / 2 + 0.01 for i in x], [m[3] or 0 for m in moves], w, color=TREMOR, label="Tremor pool")
    ax.set_xticks(list(x))
    ax.set_xticklabels([f"{m[1]:.1f}%" for m in moves], color=INK2, fontsize=9)
    ax.set_xlabel("Size of each market move on Base (11 moves)", color=INK2, fontsize=9)
    ax.set_ylabel("LP loss to arbitrage (tUSD)", color=INK2, fontsize=9)
    ax.tick_params(axis="y", colors=INK2, labelsize=9)
    ax.yaxis.grid(True, color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(GRID)
    s_tot = sum(m[2] for m in moves)
    t_tot = sum(m[3] or 0 for m in moves)
    ax.set_title(
        f"Tremor LPs lost {100 * (1 - t_tot / s_tot):.0f}% less to arbitrage than LPs in an identical static pool",
        color=INK, fontsize=12, loc="left", pad=22,
    )
    ax.text(0, 1.02, "Arbitrage by a bot that traded after Tremor's update landed, averaged per move. "
            "Live testnet runs, Nov 2026.", transform=ax.transAxes, color=INK2, fontsize=8.5)
    ax.legend(frameon=False, fontsize=9, labelcolor=INK, loc="upper right")
    fig.tight_layout()
    out = os.path.join(HERE, "charts", "lp-loss-by-move.png")
    fig.savefig(out, facecolor=SURFACE)
    print(out, round(s_tot), round(t_tot))


if __name__ == "__main__":
    main()
