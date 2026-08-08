#!/usr/bin/env python3
"""Slide figure: the three findings mined from the raw logs (2026-08-06).

Panel A — real battery-temperature traces per generation window (thermal story).
Panel B — laptop worker CPU utilization: idle / dozing split / keepalive split.
Panel C — typographic card: temp-0 outputs diverge across backends.
"""
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE = "/Users/sgaba/my_workspace/code/Qmesh-AI/results/energy"
SURF, INK, INK2, GRID, SPINE = "#fcfcfb", "#0b0b0b", "#52514e", "#e8e7e3", "#d8d7d2"
BLUE, ORANGE, AQUA, YELLOW = "#2a78d6", "#eb6834", "#1baf7a", "#eda100"
GRAY = "#8a8984"

pat = re.compile(r"^(\d+)\|.*?temperature: (\d+)\|")
T = {}
for line in open(f"{BASE}/battery_merged.log"):
    m = pat.match(line.strip())
    if m:
        T[int(m.group(1))] = int(m.group(2)) / 10

def trace(t0, t1):
    pts = sorted((t, v) for t, v in T.items() if t0 <= t <= t1)
    return [p[0] - t0 for p in pts], [p[1] for p in pts]

fig = plt.figure(figsize=(13.2, 4.9), dpi=200)
fig.patch.set_facecolor(SURF)
gs = fig.add_gridspec(1, 3, width_ratios=[1.35, 0.95, 1.15], wspace=0.28,
                      left=0.05, right=0.985, top=0.78, bottom=0.14)
ax1, ax2 = fig.add_subplot(gs[0]), fig.add_subplot(gs[1])
ax3 = fig.add_subplot(gs[2]); ax3.axis("off")

for ax in (ax1, ax2):
    ax.set_facecolor(SURF)
    ax.grid(axis="y", color=GRID, linewidth=0.8, zorder=0)
    ax.tick_params(colors=INK2, labelsize=9)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(SPINE)

# --- Panel A: temperature traces --------------------------------------------
WINDOWS = [
    ("On-device CPU", BLUE,   1786075859, 1786075912, "+1.9 °C/min"),
    ("On-device NPU", YELLOW, 1786071524, 1786071555, "+2.9 °C/min"),
    ("Split mesh",    ORANGE, 1786076360, 1786076465, "0.0 °C/min"),
    ("Remote laptop", AQUA,   1786075930, 1786075985, "0.0 °C/min"),
]
LBL = {"On-device CPU": (57, 32.15), "On-device NPU": (34, 32.6),
       "Split mesh": (55, 28.75), "Remote laptop": (58, 31.45)}
for name, color, t0, t1, slope in WINDOWS:
    xs, ys = trace(t0, t1)
    # raw quantized fuel-gauge steps, faint; bold trend segment carries the story
    ax1.plot(xs, ys, color=color, linewidth=1.2, alpha=0.35,
             drawstyle="steps-post", zorder=2)
    ax1.plot([xs[0], xs[-1]], [ys[0], ys[-1]], color=color, linewidth=2.5,
             solid_capstyle="round", zorder=3)
    x, y = LBL[name]
    ax1.plot(x - 2.5, y, "o", color=color, markersize=5, zorder=4)
    ax1.annotate(f"{name} · {slope}", xy=(x, y), fontsize=8.8, color=INK,
                 ha="left", va="center")
ax1.set_xlim(0, 138)
ax1.set_ylim(27.5, 33)
ax1.set_xlabel("seconds into generation window", fontsize=9.5, color=INK2)
ax1.set_ylabel("battery temperature (°C)", fontsize=9.5, color=INK2)
ax1.set_title("Offload = thermally flat; on-device heats the phone",
              fontsize=11, color=INK, loc="left", pad=8)

# --- Panel B: laptop worker utilization -------------------------------------
cats = ["Laptop\nidle", "Split, radio\ndozing", "Split, 5 pps\nkeepalive"]
vals = [4.9, 31.6, 75.5]
bars = ax2.bar(cats, vals, color=[GRAY, ORANGE, ORANGE], width=0.55, zorder=3)
bars[1].set_alpha(0.45)
for rect, v in zip(bars, vals):
    ax2.annotate(f"{v:.0f}%", xy=(rect.get_x() + rect.get_width() / 2, v),
                 xytext=(0, 4), textcoords="offset points", ha="center",
                 fontsize=11, fontweight="bold", color=INK)
ax2.annotate("worker mostly waits\non the phone's radio", xy=(1, 33),
             xytext=(0, 26), textcoords="offset points", ha="center",
             fontsize=8, color=INK2)
ax2.set_ylabel("laptop CPU during split decode (%)", fontsize=9.5, color=INK2)
ax2.set_ylim(0, 92)
ax2.set_title("One keepalive ping ≈2.4×'s\nworker utilization",
              fontsize=11, color=INK, loc="left", pad=8)

# --- Panel C: determinism card ----------------------------------------------
ax3.set_title("Temp-0 answers differ per backend", fontsize=11, color=INK,
              loc="left", pad=8)
card = dict(transform=ax3.transAxes, fontsize=9.5, va="top")
ax3.text(0, 0.93, "Same model · same prompt · temperature 0", color=INK2, **card)
ax3.text(0, 0.80, "“…driven by environmental concerns,", color=INK, **card)
ax3.text(0.04, 0.70, "climate change …”", color=INK, **card)
ax3.text(0.10, 0.55, "CPU backend:", color=INK2, **card)
ax3.text(0.42, 0.55, "“…imperatives…”", color=BLUE, fontweight="bold", **card)
ax3.text(0.10, 0.43, "NPU backend:", color=INK2, **card)
ax3.text(0.42, 0.43, "“…awareness…”", color="#b07800", fontweight="bold", **card)
ax3.text(0, 0.24, "Both coherent; first divergence at character 304.",
         color=INK, **card)
ax3.text(0, 0.14, "fp accumulation order differs per backend →\nvalidate quality "
         "per mode; don't promise bit-identical answers.", color=INK2, **card)

fig.suptitle("What the raw logs revealed — QMesh measurement suite, 2026-08-06",
             fontsize=13.5, color=INK, x=0.05, y=0.97, ha="left")
fig.text(0.05, 0.88, "Battery telemetry, per-window slopes · typeperf on the X Elite "
         "worker sliced by run window · stream transcripts compared byte-by-byte",
         fontsize=9, color=INK2)
out = f"{BASE}/hidden_findings_slide.png"
fig.savefig(out, facecolor=SURF, bbox_inches="tight")
print("saved", out)
