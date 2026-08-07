#!/usr/bin/env python3
"""Latency & performance visuals from the 2026-08-06 measured runs.

Figure 1 (chart): decode speed by mode + the radio-keepalive ablation.
Figure 2 (graph): tokens delivered vs seconds for one chat response, measured
runs solid, projections dotted (same motif as the battery charts).
Sources: results/energy/curl_phone.txt + server logs, results/bigmodel/split_30b.log.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE = "/Users/sgaba/my_workspace/code/Qmesh-AI/results/energy"
SURF, INK, INK2, GRID, SPINE = "#fcfcfb", "#0b0b0b", "#52514e", "#e8e7e3", "#d8d7d2"
BLUE, ORANGE, AQUA, YELLOW, VIOLET = "#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#4a3aa7"

def style(ax):
    ax.set_facecolor(SURF)
    ax.grid(axis="y", color=GRID, linewidth=0.8, zorder=0)
    ax.tick_params(colors=INK2, labelsize=9)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(SPINE)

# ---------------------------------------------------------------- figure 1
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10.2, 4.7), dpi=200,
                               gridspec_kw={"width_ratios": [1.5, 1]})
fig.patch.set_facecolor(SURF)
style(ax1); style(ax2)

modes = ["On-device\nCPU · 4B", "On-device\nNPU · 4B", "Split mesh\n4B",
         "Remote\nlaptop · 4B", "Split mesh\n30B-A3B"]
rates = [24.5, 17.0, 11.4, 11.1, 11.4]
colors = [BLUE, YELLOW, ORANGE, AQUA, VIOLET]
b = ax1.bar(modes, rates, color=colors, width=0.58, zorder=3)
for rect, v in zip(b, rates):
    ax1.annotate(f"{v:.1f}", xy=(rect.get_x() + rect.get_width() / 2, v),
                 xytext=(0, 4), textcoords="offset points", ha="center",
                 fontsize=11, fontweight="bold", color=INK)
ax1.annotate("same speed,\n7.5× the parameters", xy=(4, 11.4), xytext=(0, 30),
             textcoords="offset points", ha="center", fontsize=8.5, color=INK2,
             arrowprops=dict(arrowstyle="-", color=SPINE))
ax1.set_ylabel("decode speed (tokens/s)", fontsize=10, color=INK2)
ax1.set_ylim(0, 28)
ax1.set_title("Decode speed by mode (server-confirmed)", fontsize=11.5,
              color=INK, loc="left", pad=10)

ka = ["Radio dozing\n(no keepalive)", "5 pps keepalive\n(ships in demo)"]
ka_v = [2.9, 10.3]
b2 = ax2.bar(ka, ka_v, color=[ORANGE, ORANGE], width=0.5, zorder=3)
b2[0].set_alpha(0.45)
for rect, v, ttft in zip(b2, ka_v, ["TTFT 1.4–2.8 s", "TTFT < 0.1 s"]):
    ax2.annotate(f"{v:.1f}", xy=(rect.get_x() + rect.get_width() / 2, v),
                 xytext=(0, 4), textcoords="offset points", ha="center",
                 fontsize=11, fontweight="bold", color=INK)
    ax2.annotate(ttft, xy=(rect.get_x() + rect.get_width() / 2, 0),
                 xytext=(0, -34), textcoords="offset points", ha="center",
                 fontsize=8.5, color=INK2)
ax2.annotate("≈4×", xy=(0.5, 6.6), ha="center", fontsize=13, fontweight="bold",
             color=INK2)
ax2.set_ylabel("split decode (tokens/s)", fontsize=10, color=INK2)
ax2.set_ylim(0, 12.4)
ax2.set_title("Wi-Fi power-save ablation (split, 4B)", fontsize=11.5,
              color=INK, loc="left", pad=10)

fig.suptitle("QMesh latency & performance — Galaxy S25 Ultra ↔ Snapdragon X Elite, "
             "2.4 GHz hotspot", fontsize=13, color=INK, x=0.02, y=1.0, ha="left")
fig.text(0.02, 0.935, "llama.cpp b10270 · Q4_0 · measured 2026-08-06 · phone-driven "
         "requests, the exact path the app takes", fontsize=9, color=INK2)
fig.tight_layout(rect=(0, 0.04, 1, 0.90))
fig.savefig(f"{BASE}/performance_latency_chart.png", facecolor=SURF,
            bbox_inches="tight")
print("saved chart")

# ---------------------------------------------------------------- figure 2
fig2, ax = plt.subplots(figsize=(9.4, 5.0), dpi=200)
fig2.patch.set_facecolor(SURF)
style(ax)
ax.grid(color=GRID, linewidth=0.8, zorder=0)

# (label, color, measured_end_s, measured_tokens, projected_end_s)
RUNS = [
    ("On-device CPU · 4B",        BLUE,   25.0, 512, None),
    ("On-device NPU · 4B",        YELLOW, 29.1, 512, None),
    ("Split mesh · 30B-A3B",      VIOLET, 12.3, 112, 47.2),
    ("Split mesh · 4B",           ORANGE, 46.6, 512, None),
    ("Remote laptop · 4B",        AQUA,   46.1, 512, None),
    ("Split, radio dozing · 4B",  ORANGE, 95.0, 192, None),
]
for name, color, t1, tok, tproj in RUNS:
    dashed = name.startswith("Split, radio")
    z = 3.5 if "30B" in name else 3   # 30B on top — its slope coincides with 4B split
    ax.plot([0, t1], [0, tok], color=color, linewidth=2,
            linestyle=(0, (1, 2.2)) if dashed else "-",
            solid_capstyle="round", dash_capstyle="round", zorder=z)
    if tproj:  # dotted projection to a full 512-token response
        ax.plot([t1, tproj], [tok, 512], color=color, linewidth=2,
                linestyle=(0, (1, 2.2)), dash_capstyle="round", zorder=3)

# endpoint markers with a surface ring so the coincident 46-47 s trio stays legible
for _, color, t1, tok, _ in RUNS:
    ax.plot(t1, tok, "o", color=color, markersize=6, zorder=4,
            markeredgecolor=SURF, markeredgewidth=1.5)
ax.plot(47.2, 512, "o", color=VIOLET, markersize=6, zorder=4,
        markeredgecolor=SURF, markeredgewidth=1.5)

LABELS = [  # stacked list beside the coincident endpoints; dot chip carries identity
    ("On-device CPU · 25 s",           BLUE,   (23.0, 540)),
    ("On-device NPU · 29 s",           YELLOW, (31.0, 462)),
    ("Remote 4B · 46 s",               AQUA,   (50.0, 540)),
    ("Split 4B · 47 s",                ORANGE, (50.0, 505)),
    ("Split 30B-A3B · ≈47 s (proj.)",  VIOLET, (50.0, 470)),
    ("Split, radio dozing · ≈4 min",   ORANGE, (60.0, 168)),
]
for text, color, (x, y) in LABELS:
    ax.plot(x - 1.2, y, "o", color=color, markersize=5, zorder=4)
    ax.annotate(text, xy=(x, y), fontsize=9, color=INK, ha="left", va="center")

ax.axhline(512, color=SPINE, linewidth=0.8, zorder=1)
ax.set_xlim(0, 108)
ax.set_ylim(0, 585)
ax.set_xlabel("seconds since request", fontsize=10, color=INK2)
ax.set_ylabel("tokens delivered", fontsize=10, color=INK2)
ax.set_title("Delivering one 512-token chat response — measured runs (solid) "
             "and projections (dotted)", fontsize=11.5, color=INK, loc="left", pad=12)
fig2.suptitle("Time to a full response by mode", fontsize=13, color=INK,
              x=0.02, y=1.0, ha="left")
fig2.text(0.02, 0.945, "Steeper is faster · the 30B split line has the same slope "
          "as the 4B split — model size is ~free on the mesh until the worker saturates",
          fontsize=9, color=INK2)
fig2.tight_layout(rect=(0, 0, 1, 0.90))
fig2.savefig(f"{BASE}/performance_response_time_graph.png", facecolor=SURF,
             bbox_inches="tight")
print("saved graph")
