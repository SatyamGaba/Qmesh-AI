# Experiment run log — 2026-08-06 (evening)

Operator: Claude (full device control granted by user). Every measurement below traces to a raw
file in `energy/` or `bigmodel/`.

## Setup snapshot (Phase 0, ~18:4x)

- Topology: laptop hotspot. Laptop `192.168.137.1` (X Elite, hostname QCWorkshop4), phone
  `192.168.137.2` (S25 Ultra). Mac controls the phone via ssh tunnel → `adb connect
  localhost:15555`; laptop has its own platform-tools now (`C:\Users\qc_de\platform-tools\`,
  installed today) with the phone on USB (`R3CXC08036V`).
- Laptop engines live at start: `hvx\ggml-rpc-server.exe -H 192.168.137.1 -p 50052 -d HTP0 -c`
  (NPU worker, PID 31808), `hvx\llama-server.exe --device HTP0 -ngl 99 … :8082` (NPU remote,
  PID 24836), plus the old CPU rpc-server on `0.0.0.0:50052` (PID 22844; reachable only via
  laptop loopback — hotspot traffic lands on the specific-bind NPU worker).
- Phone at start: **no llama processes**. Previous split MAIN (4B, :8081) had aborted —
  `split.log` shows normal serving (2.98–8.99 t/s decode interactive) then abort with memory
  breakdown, consistent with the worker being restarted underneath it (RPC has no reconnect).
- Phone storage: 163 GB free on /data. Battery: level 82, USB-charging from the laptop (+0.32 A).
- Battery telemetry: sysfs `/sys/class/power_supply/**` is permission-denied for shell on this
  Samsung build. `dumpsys battery` works and refreshes `current now` (µA) / `voltage` (mV) every
  ~2–4 s; `charge counter` (µAh coulomb counter) logged as the energy integral cross-check.
  Units confirmed: µA (current, sign + = charging), mV (voltage), 0.1 °C (temperature).

## Phase 1 — 30B GGUF → phone (in progress)

- 18:46: `adb push` of `qwen3-30b-a3b-instruct-2507-q4_0.gguf` (17,379,987,872 B) started from
  the laptop over USB → `/data/local/tmp/llama/` (~45 MB/s observed). Laptop copy is the hash
  reference (`Get-FileHash` running in parallel).
- Discovery: the phone also carries an accelerated build at `/data/local/tmp/llama.cpp/`
  (`--list-devices`: `GPUOpenCL: QUALCOMM Adreno(TM) 830 (5556 MiB)` + `HTP0: Hexagon`).
  `phone_split.sh serve-local` prefers it (HTP0). Energy suite therefore gains an
  **on-device-NPU vs on-device-CPU** leg.
- Display conditions locked for the energy runs: `screen_brightness_mode 0` (auto off),
  `screen_brightness 128`, `screen_off_timeout` raised to 30 min after the first roam (below).

## Incidents & method changes (evening) — read before interpreting numbers

1. **NPU worker casualty:** the hvx NPU rpc-server held a stale ESTABLISHED session from the
   crashed 4B split MAIN (worker is single-client — would stall any new client), so it was
   killed for a clean restart. Relaunch over ssh **fails**: WMI-parented processes land in
   session 0 and the Hexagon FastRPC driver refuses (`failed to open session 0: 0x80000406`,
   `GGML_ASSERT(device)`), and the Task-Scheduler interactive workaround was permission-blocked.
   → Split legs tonight run against the **CPU worker** (`0.0.0.0:50052`, the documented shape).
   → **Restore needs one command at the laptop console** (see FINDINGS wrap-up note).
2. **Phone roamed off the hotspot** to HaQathon when the screen dozed (no reboot — uptime
   continuous; the Hexagon on-device server was NOT the cause and was in fact healthy).
   User re-joined it manually. Mitigations: 30-min screen timeout, AP-side ping burst to
   pre-wake the radio before adb contact.
3. **Radio doze kills the control plane** with keepalive off (tunnel adb + Mac-side sampler
   died twice). Redesign: battery sampler + workload runner now live ON the phone under nohup
   (`sampler_phone.sh`, `run_leg.sh`, `run_window.sh` in `energy/tools/`), zero network traffic
   during measured windows; adb is only used to start runs and collect files afterwards.
4. **Fuel-gauge lag:** `current now` smooths hard and the coulomb counter steps coarsely, so
   25–30 s windows mis-read (two identical CPU runs: 1.25 W vs 9.10 W). Method: aggregate
   ~2-min windows (N back-to-back generations, one mark pair); coulomb-counter delta is the
   primary energy figure, V·I integral the cross-check.

## Phase 2 — FINAL energy/latency table (see `energy/battery_merged.log` + `marks_merged.txt`)

Analyzer: `energy/tools/analyze_energy.py battery_merged.log marks_merged.txt`. Windows with a
working sampler (the definitive set): idle, local_cpu_e, remote_e2, split_e (+ early Mac-sampled
local_cpu/local_npu legs). V·I integral primary, coulomb-counter (dccJ) cross-check.

| Mode | avg W | ΔJ/token | Effective t/s | Phone RSS |
|---|---:|---:|---:|---:|
| Idle, screen on 128 | 0.61 | — | — | — |
| On-device CPU (4B) | 8.59 | 0.41 | 19–24 | 5.27 GB |
| On-device NPU HTP0 (4B) | 8.5–12.6 | 0.44–0.72 | ~17 | 0.81 GB |
| Split → worker (4B, keepalive) | 3.49 | 0.29 | ~10–11 | ~0.9 GB |
| Remote laptop-NPU (4B) | 2.98 | 0.25 | ~11 | ~0 |

Headlines: **split cuts phone power ~2.5× (8.6→3.5 W) and ΔJ/token ~30% (0.41→0.29)** vs
on-device; keepalive ablation: split decode **2.07/3.67 t/s OFF → 10.3 t/s avg ON** (TTFT up to
2.8 s off); the experimental Hexagon on-device path is slower AND hungrier than CPU (OPPOLL);
remote server (hvx llama-server, HTP0) measures **~15 t/s solo / 132 ms per token** from the
laptop itself — the 37.5 t/s figure in older docs was the CPU llama-server.
Laptop during split decode: ~52–57 % total CPU (typeperf CSVs in `energy/`).

## Phase 3 — 30B-A3B "impossible alone" (in progress)

- **Phone-alone attempt (`llama-cli -ngl 0`, 22:41): never finished loading.** The phone
  became unreachable on ALL networks for ~10 min (Wi-Fi dropped, adbd died, the marks-harness
  itself was killed — no END mark ever written; `oom30b.log` is an endless load spinner).
  User handled the phone afterwards: it had silently dropped to another Wi-Fi. Zero tokens
  produced. This *is* the capability evidence.
- 30B split serve (`NGL=44`, → hvx NPU worker): **cache MISS despite the warmed CPU-worker
  cache** — the phone streams weights at ~8 MB/s over the 2.4 GHz hotspot (~16 GB ≈ ~33 min,
  one-time; it permanently warms the NPU worker's own cache for the demo). Cross-BUILD cache
  sharing between the b10270 CPU worker and the qmesh_npu hvx worker evidently does not hit,
  even though both use `-c` — document as a deployment gotcha (warm the cache per-worker-build).
- Laptop loopback 30B through the b10270 CPU worker (`-ngl 99`, pre-warm run): pp16 6.03 /
  tg8 4.91 t/s (both roles sharing the laptop CPU; real split expected different).

## Phase 3 — OUTCOME (23:5x) ✅

The 30B split works: **7.2–11.5 t/s decode, correct output**, worker = b10270 CPU rpc-server
(the hvx NPU worker died on the MoE graph — see FINDINGS §30B for the routing + cache caveats).
Phone-alone 30B: zero tokens, phone disabled ~10 min. Evidence: `bigmodel/placement_evidence.txt`,
`bigmodel/oom30b.log`, `bigmodel/split_30b.log`.

## Final state (left running for the demo)

- Phone `:8082` On-device — UP (serve-local, NPU build). `:8081` Split — UP, **serving the 30B**
  through the CPU worker. Laptop `:8082` Remote (hvx NPU llama-server) — UP. All three verified
  from the phone.
- To put the 4B back on Split: `SERIAL=<serial> ./scripts/phone_split.sh serve 192.168.137.1`
  (defaults restore 4B/NGL=32).
- **Needs a console action when desired:** relaunch the hvx NPU worker AT THE LAPTOP (ssh/WMI
  cannot — FastRPC refuses session 0):
  `"C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\hvx\ggml-rpc-server.exe" -H 192.168.137.1 -p 50052 -d HTP0 -c`
  Keep the 30B away from it (MoE kills it); with it alive, phone traffic prefers it (specific
  bind) — 4B demo OK; kill it (or let it die) for the 30B demo.
- Battery after the whole suite: 83 %, 29.8 °C. Phone left USB-powered on the laptop.

## Interim results (Phase 2, partial)

- Controlled phone re-bench (unplugged, 90%, 28 °C, screen on): **126.8 pp / 24.5 tg r=3** and
  tg256 = 23.7 — confirms 2026-08-05 (141/25.5); the 08-04 "10.6 tg" was a bad-state artifact.
- On-device NPU (HTP0, `-ngl 99 --load-mode none`): **~17.0 t/s decode** (server-confirmed),
  RSS only **0.81 GB** vs CPU-mode **5.27 GB** — weights live on the NPU. But `OPPOLL=1`
  busy-polling keeps phone load-average ~10 even idle.
- Split keepalive ablation (4B via CPU worker, 192-token gens, phone-side sampler, zero other
  traffic): **keepalive OFF = 2.07 / 3.67 t/s** (482 / 273 ms per token, server-confirmed;
  TTFT 2.15 / 1.38 s). Laptop CPU spikes to ~52–57 % during worker decode.
- Laptop-side working sets: CPU worker 2.49 GB, NPU worker 56 MB (weights on HTP), NPU
  llama-server 2.65 GB.
- Tooling in `energy/tools/`: `sample_battery.sh` (1 Hz dumpsys sampler, phone clock),
  `gen_load.sh` (phone-side streamed curl, TTFT + SSE chunk count, window marks),
  `analyze_energy.py` (V·I·dt integral + coulomb-counter cross-check per window),
  `req_energy*.json` (fixed 512-token essay prompt, temp 0; also pushed to the phone).
