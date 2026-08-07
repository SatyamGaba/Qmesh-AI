#!/usr/bin/env python3
"""Projected battery runway per QMesh mode, from the 2026-08-06 measured draw.

Two panels, one axis each: battery % remaining vs (a) number of 512-token chat
responses, (b) hours of continuous generation. Straight lines by construction —
this is an explicit linear extrapolation of the measured per-mode power/energy
(results/energy/, analyze_energy.py), starting from 100 %.

Assumptions: S25 Ultra 5,000 mAh ≈ 19.25 Wh (69,300 J) pack; screen on;
back-to-back 512-token generations at the measured absolute J/token
(idle share included). Measured: on-device 8.59 W / 0.44 J/tok,
split 3.49 W / 0.35 J/tok, remote 2.98 W / 0.32 J/tok, idle 0.61 W.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

PACK_J = 19.25 * 3600
MODES = [
    ("On-device (phone CPU)", "#2a78d6", 8.59, 0.44),
    ("Split via mesh",        "#eb6834", 3.49, 0.35),
    ("Remote (laptop)",       "#1baf7a", 2.98, 0.32),
]
IDLE_W = 0.61
TOK_PER_QUERY = 512

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(9.8, 4.8), dpi=200)
fig.patch.set_facecolor("#fcfcfb")
for ax in (ax1, ax2):
    ax.set_facecolor("#fcfcfb")
    ax.grid(color="#e8e7e3", linewidth=0.8, zorder=0)
    ax.tick_params(colors="#52514e", labelsize=9)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color("#d8d7d2")
    ax.set_ylim(0, 102)
    ax.set_ylabel("battery remaining (%)", fontsize=10, color="#52514e")

# Panel a — chat responses (512 tokens each)
def runway(ax, x_empty, color, name=None):
    """Solid down to 20 % remaining, dotted 20 %→0 to flag the extrapolated tail."""
    x_20 = 0.8 * x_empty
    ax.plot([0, x_20], [100, 20], color=color, linewidth=2,
            solid_capstyle="round", label=name, zorder=3)
    ax.plot([x_20, x_empty], [20, 0], color=color, linewidth=2,
            linestyle=(0, (1, 2.2)), dash_capstyle="round", zorder=3)

OFFS = [(2, 10, "left"), (-6, 26, "right"), (6, 10, "left")]
for (name, color, w, jtok), (dx, dy, ha) in zip(MODES, OFFS):
    q_empty = PACK_J / (jtok * TOK_PER_QUERY)
    runway(ax1, q_empty, color, name)
    ax1.annotate(f"≈{q_empty:,.0f}", xy=(q_empty, 0), xytext=(dx, dy),
                 textcoords="offset points", fontsize=9.5, color="#0b0b0b",
                 fontweight="bold", ha=ha)
ax1.set_xlim(0, 460)
ax1.set_xlabel("chat responses (512 tokens each)", fontsize=10, color="#52514e")
ax1.set_title("Responses per charge", fontsize=11.5, color="#0b0b0b",
              loc="left", pad=10)
ax1.legend(loc="upper right", frameon=False, fontsize=9)

# Panel b — hours of continuous generation
for (name, color, w, jtok), (dx, dy, ha) in zip(MODES, OFFS):
    h_empty = PACK_J / w / 3600
    runway(ax2, h_empty, color)
    ax2.annotate(f"{h_empty:.1f} h", xy=(h_empty, 0), xytext=(dx, dy),
                 textcoords="offset points", fontsize=9.5, color="#0b0b0b",
                 fontweight="bold", ha=ha)
h_idle = PACK_J / IDLE_W / 3600
xs = [0, 7.2]
ax2.plot(xs, [100 - 100 * x / h_idle for x in xs], color="#8a8984",
         linewidth=1.2, linestyle=(0, (4, 3)), zorder=2)
ax2.annotate(f"idle, screen on (≈{h_idle:.0f} h)", xy=(5.1, 100 - 100 * 5.1 / h_idle),
             xytext=(0, -14), textcoords="offset points", fontsize=8.5,
             color="#52514e", ha="center")
ax2.set_xlim(0, 7.2)
ax2.set_xlabel("hours of continuous generation", fontsize=10, color="#52514e")
ax2.set_title("Runtime, generating non-stop", fontsize=11.5, color="#0b0b0b",
              loc="left", pad=10)

fig.suptitle("Projected battery runway — the mesh ≈2.5× the phone's AI endurance",
             fontsize=13, color="#0b0b0b", x=0.02, y=1.0, ha="left")
fig.text(0.02, 0.935,
         "Linear projection from measured draw (2026-08-06 windows) · S25 Ultra "
         "19.25 Wh pack, from 100 %, screen on · Qwen3-4B Q4_0",
         fontsize=9, color="#52514e")

fig.tight_layout(rect=(0, 0, 1, 0.90))
out = "/Users/sgaba/my_workspace/code/Qmesh-AI/results/energy/battery_life_projection.png"
fig.savefig(out, facecolor=fig.get_facecolor(), bbox_inches="tight")
print("saved", out)
