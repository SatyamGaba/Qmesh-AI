#!/usr/bin/env python3
"""Battery discharge comparison, QMesh modes (2026-08-06 measurements).

The fuel-gauge HAL refreshes too coarsely (20-30 s in places, with carry-over
lag at window edges) for an honest raw time-series, so the chart shows the
window-averaged quantities from the marked measurement windows instead —
averages integrate over the lag. Sources: results/energy/battery_merged.log,
marks_merged.txt, analyzed by energy/tools/analyze_energy.py.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# From analyze_energy.py over the definitive sampler-covered windows
MODES = ["On-device\n(phone CPU)", "Split\nvia mesh", "Remote\n(laptop)"]
COLORS = ["#2a78d6", "#eb6834", "#1baf7a"]      # fixed categorical order
AVG_W = [8.59, 3.49, 2.98]
DJ_TOK = [0.41, 0.29, 0.25]
IDLE_W = 0.61

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(9.6, 4.6), dpi=200)
fig.patch.set_facecolor("#fcfcfb")

for ax in (ax1, ax2):
    ax.set_facecolor("#fcfcfb")
    ax.grid(axis="y", color="#e8e7e3", linewidth=0.8, zorder=0)
    ax.tick_params(colors="#52514e", labelsize=9.5)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color("#d8d7d2")

b1 = ax1.bar(MODES, AVG_W, color=COLORS, width=0.55, zorder=3)
for rect, v in zip(b1, AVG_W):
    ax1.annotate(f"{v:.1f} W", xy=(rect.get_x() + rect.get_width() / 2, v),
                 xytext=(0, 4), textcoords="offset points", ha="center",
                 fontsize=11, fontweight="bold", color="#0b0b0b")
ax1.axhline(IDLE_W, color="#8a8984", linewidth=1.2, linestyle=(0, (4, 3)), zorder=4)
ax1.annotate(f"idle, screen on · {IDLE_W:.2f} W", xy=(0.5, IDLE_W),
             xytext=(0, 5), textcoords="offset points", fontsize=8.5,
             color="#52514e", ha="center")
ax1.set_ylabel("avg battery discharge (W)", fontsize=10, color="#52514e")
ax1.set_ylim(0, 10.2)
ax1.set_title("Power draw while generating", fontsize=11.5, color="#0b0b0b",
              loc="left", pad=10)

b2 = ax2.bar(MODES, DJ_TOK, color=COLORS, width=0.55, zorder=3)
for rect, v in zip(b2, DJ_TOK):
    ax2.annotate(f"{v:.2f} J", xy=(rect.get_x() + rect.get_width() / 2, v),
                 xytext=(0, 4), textcoords="offset points", ha="center",
                 fontsize=11, fontweight="bold", color="#0b0b0b")
ax2.set_ylabel("energy per token, above idle (J)", fontsize=10, color="#52514e")
ax2.set_ylim(0, 0.48)
ax2.set_title("Energy per generated token", fontsize=11.5, color="#0b0b0b",
              loc="left", pad=10)

fig.suptitle("Phone battery cost of inference — offloading to the mesh cuts "
             "power ≈2.5× and J/token ≈30%",
             fontsize=13, color="#0b0b0b", x=0.02, y=1.0, ha="left")
fig.text(0.02, 0.935, "Galaxy S25 Ultra · Qwen3-4B Q4_0 · 512-token generations, "
         "screen on, on battery · 2.4 GHz hotspot mesh · 2026-08-06",
         fontsize=9, color="#52514e")

fig.tight_layout(rect=(0, 0, 1, 0.90))
out = "/Users/sgaba/my_workspace/code/Qmesh-AI/results/energy/battery_discharge_comparison.png"
fig.savefig(out, facecolor=fig.get_facecolor(), bbox_inches="tight")
print("saved", out)
