# QMesh — Experimental Results (2026-08-06)

Measured on the real demo hardware and topology: **Galaxy S25 Ultra** (Snapdragon 8 Elite,
11.4 GB RAM) as the inference MAIN, **Snapdragon X Elite Copilot+ laptop** as the mesh worker,
connected over the laptop's self-contained **2.4 GHz Wi-Fi hotspot**. Engine: llama.cpp
`b10270` (+ experimental Hexagon build), models Qwen3-4B-Instruct and Qwen3-30B-A3B, both
Q4_0 GGUF. Every number below traces to a raw file in this folder; the full lab narrative
lives in [`RUNLOG.md`](RUNLOG.md) and [`../split_rpc_validation/FINDINGS.md`](../split_rpc_validation/FINDINGS.md).

## 1. Capability — a 30B model on a phone that cannot hold it

| Configuration | Outcome |
|---|---|
| **Phone alone**, Qwen3-30B-A3B (17.4 GB) | **Zero tokens.** Never finished loading; memory thrash knocked the phone off Wi-Fi for ~10 min and killed its own tooling ([`bigmodel/oom30b.log`](bigmodel/oom30b.log)) |
| **QMesh split** — 4 layers on phone, 44 on laptop | **Correct answers at 7.2–11.5 t/s decode** (87–139 ms/token), prefill ~6 t/s ([`bigmodel/placement_evidence.txt`](bigmodel/placement_evidence.txt)) |

The 30B split decodes at the **same ~10 t/s as the 4B split** — the per-token network cost is
flat, so model size is nearly free until the worker saturates. **7.5× the parameters at equal
interactive speed.** Placement proof: 15.0 GB resident on the worker, 1.5 GB on the phone.

Weight logistics: the content-addressed RPC cache (`-c`) loads the 30B in **98 s with only
~0.5 GB over the air** once warmed (cold transfer would be ~16 GB). Caveat: warm the cache
through the same worker binary you deploy — entries do not hit across worker builds.

## 2. Energy efficiency — the mesh is a battery feature

1 Hz battery telemetry on the phone (`dumpsys battery`, V·I integral + coulomb-counter
cross-check), fixed 512-token generations driven from the phone, screen on at fixed
brightness, on battery. Data: [`energy/battery_merged.log`](energy/battery_merged.log) +
[`energy/marks_merged.txt`](energy/marks_merged.txt), analyzer in [`energy/tools/`](energy/tools/).

| Mode (Qwen3-4B) | Phone power | Energy/token (Δ over idle) | Decode t/s | Phone RSS |
|---|---:|---:|---:|---:|
| Idle, screen on | 0.61 W | — | — | — |
| On-device CPU | 8.6 W | 0.41 J | 19–24 | 5.27 GB |
| On-device NPU (Hexagon) | 8.5–12.6 W | 0.44–0.72 J | ~17 | **0.81 GB** |
| **Split via mesh** | **3.5 W** | **0.29 J** | 10–11 | ~1.0 GB |
| Remote (laptop NPU) | **3.0 W** | 0.25 J | ~11 | ~0 |

**Offloading through the mesh cuts the phone's power draw ~2.5× (8.6 → 3.5 W) and energy per
token ~30 %** while tokens keep flowing at interactive rates — plus a ~4 GB smaller memory
footprint on the handset.

## 3. Latency engineering — radio power-save, quantified

Wi-Fi power-save, not bandwidth, dominates interactive latency on the split
(ggml-rpc makes multiple round-trips per token). Measured, same session:

| Condition | Split decode | TTFT |
|---|---:|---:|
| Radio dozing (no keepalive) | **2.1–3.7 t/s** | up to 2.8 s |
| 5 pps keepalive holding the radio | **10.3 t/s avg** | ~10 ms |

A single background ping gives a **~4× interactive speedup** — this mitigation ships in the
demo runbook. Remote-mode SSE streaming suffers the same doze without it.

## 4. Resource utilization notes

- Controlled phone baseline (battery 90 %, 28 °C, r=3): **126.8 pp / 24.5 tg** — resolves the
  earlier 10.6-vs-25.5 t/s discrepancy as a device-state artifact
  ([`energy/bench_local_cpu_pp128tg32.txt`](energy/bench_local_cpu_pp128tg32.txt)).
- Laptop during split decode: ~52–57 % total CPU ([`energy/laptop_cpu_ka_windows.csv`](energy/laptop_cpu_ka_windows.csv)).
- Experimental Hexagon backend today: decode-slower than CPU on both devices (17 vs 24 t/s
  phone; ~15 vs 37.5 t/s laptop) and no energy win yet (`OPPOLL` busy-polling) — but a 6.5×
  smaller phone RAM footprint with weights resident on the NPU. Tracked as roadmap.

## File map

```
results/
├── RESULTS.md                  ← this summary
├── RUNLOG.md                   ← full chronological lab log (commands, incidents, conditions)
├── energy/                     ← battery CSVs, window marks, curl timings, laptop CPU
│   └── tools/                  ← sampler, load driver, analyzer (reproduce: analyze_energy.py
│                                  battery_merged.log marks_merged.txt)
└── bigmodel/                   ← 30B split: placement evidence, phone-alone OOM log,
                                  server log, laptop loopback warm bench
```
