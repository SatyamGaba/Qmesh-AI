# Findings — same-machine RPC layer-split validation

**Date:** 2026-08-04 · **Machine:** Snapdragon X Elite (X1E80100), 12-core Oryon, 31.6 GB
**Build:** official llama.cpp release `b10270` win-arm64 **CPU** build (no local compile needed; includes `ggml-rpc-server.exe`)
**Model:** Qwen3-4B-Instruct-2507 Q4_0 GGUF (2.21 GiB, 36 layers) — same family/revision as the GenieX NPU deployment

## Setup

`ggml-rpc-server.exe` (v5.0.0) on `127.0.0.1:50052` exposing the CPU device;
`llama-bench`/`llama-cli` as main host offloading `-ngl` layers to it via `--rpc`.
Loopback TCP stands in for Wi-Fi; both roles share the same 12 cores (worker `-t 6`, main `-t 6`).

## Results (llama-bench, pp128 / tg32, r=2)

| Shape | pp128 t/s | tg32 t/s | Meaning |
|---|---:|---:|---|
| Baseline — all 36 layers local, no RPC | 213.9 | 37.5 | single-device reference |
| **Split — 18 layers on RPC worker** | 122.1 | **34.2** | the demo shape: ~9% decode penalty |
| All-remote — every layer on worker | 83.3 | 34.2 | worker-bound; RPC per-token cost visible in pp |

Sanity generation through the 18-layer split (`llama-cli -st --temp 0`): correct,
coherent answer; 19.0 t/s generation in a cold-start interactive run (bench numbers
above exclude load; this one includes cache warmup and CPU contention).

## Conclusions

1. **Risk #2 (RPC mechanism) is retired on the host side.** Official win-arm64
   binaries do layer-split inference over ggml-RPC out of the box — correct output,
   ~9% decode overhead on loopback. No local build, no signing, no patching.
2. **Backend modularity confirmed:** rpc-server loads backends as DLLs and exposes
   whatever devices exist (`-d`). The remaining L1 unknown is narrow: build the
   Hexagon backend, then `start_worker.ps1 -Devices HTP0` — same protocol,
   same scripts, same GGUF (Q4_0 is Hexagon-repackable by design).
3. **Wi-Fi projection:** decode at 34 t/s = ~29 ms/token compute. Real LAN adds
   ~5-15 ms/token of hops → expect roughly 22-29 t/s for the two-device split.
   Prefill is the sensitive phase (pp dropped 214→122 on *loopback*); long prompts
   will feel Wi-Fi first. Worth measuring pp with the worker on a second machine early.
4. **Oryon CPU surprise:** 37.5 t/s all-local CPU decode for 4B Q4_0 is within ~12%
   of the GenieX NPU path (~42 t/s). The L2 fallback (phone CPU + laptop NPU) and
   even L3 (both CPU) are perfectly presentable demos on this model size.
5. Caveats: loopback shares one CPU between both roles (real two-device numbers may
   be *better* for the split shape); llama.cpp's new chat CLI loops on closed stdin —
   use `-st` for scripted runs.

## Rerun — "first 4 layers on one end, rest on the other" (2026-08-04)

Two ways to realize a 4/32 split, both validated (llama-bench, pp128/tg32, r=2):

| Config | pp128 t/s | tg32 t/s | Shape |
|---|---:|---:|---|
| 1. Deployment shape: first 4 layers on MAIN, 32 on worker B (`--rpc :50053 -ngl 32`) | 88.4 | 33.2 | matches real phone(main)+laptop(worker) |
| 2. Two-port shape: worker A(:50052)=layers 0-3, worker B(:50053)=rest (`-ngl 99 -ts 4/32`) | 76.8 | 30.7 | two processes, one per port, main holds nothing |

Notes:
- llama.cpp offloads the LAST `-ngl` layers; the first `n_layer - ngl` stay on the
  main host. So "first 4 local" = `-ngl 32` on a 36-layer model.
- In the two-port shape the MAIN orchestrates both workers (workers never talk to
  each other): per token the activations bounce main->A->main->B->main = 4 crossings
  vs 2 in config 1. On loopback that costs ~2.5 t/s; over Wi-Fi it doubles the
  network penalty — the real deployment should be config 1's shape (phone = main
  holding its own layers, laptop = single worker).
- Flag quirk: tensor-split separator is `/` in llama-bench but `,` in llama-cli;
  the wrapper scripts normalize either form.
- Per-run worker scripts: `start_worker_a.ps1` (:50052) / `start_worker_b.ps1` (:50053).
- Live generation through the two-port 4/32 split: correct answer at 31.5 t/s
  (matches bench's 30.7). Verbose load log confirmed placement: compute buffers on
  BOTH workers (331 MiB on :50052, 323 MiB on :50053), 37/37 layers offloaded.

## Two-device split over real Wi-Fi — phone MAIN → laptop worker (2026-08-05)

**Topology:** Galaxy S25 Ultra (SM8750, `-t 6`) as MAIN with the first 4 layers +
tokenizer/sampler; X Elite laptop as worker (`ggml-rpc-server -H 0.0.0.0 -p 50052
-t 10 -c`, WMI-launched — see `LOCAL_NETWORK.md` for the ssh/WMI launch gotcha).
Same b10270 builds both sides (android-arm64 / win-arm64), same GGUF. Link: Wi-Fi
6E 6 GHz, RSSI −66 dBm, ping RTT 9–85 ms (jittery, power-save). Weight transfer
(~2 GB at `-ngl 32`) took a few minutes; worker `-c` cache verified writing, so
only the first load pays it.

| Shape (llama-bench pp128/tg32, r=2, same session) | pp128 t/s | tg32 t/s |
|---|---:|---:|
| Phone all-local baseline (`-ngl 0`, no RPC) | 141.3 ± 3.3 | **25.5 ± 0.8** |
| **Split — first 4 on phone, 32 on laptop (`-ngl 32`)** | 84.3 ± 30.1 | **15.5 ± 0.5** |

**Conclusions:**

1. **The split plane works across real devices** — correct placement, stable decode,
   one command per side. Track A1's mechanism goal is met.
2. **At 4B, the split is ~39% slower than the phone alone** (15.5 vs 25.5 tg).
   Per-token: local = 39 ms; split = 65 ms → ~25 ms/token of network ≈ 1 avg RTT,
   exactly the 2-crossings-per-token model. The old 22–29 t/s projection assumed a
   ~5–15 ms LAN; this link's RTT is 2–4× that.
3. **No 4B split shape can beat local on this link.** Best case (all-remote,
   laptop ≈ 0.74 ms/layer) ≈ 27 ms compute + ~25 ms RTT ≈ 19 t/s < 25.5 local.
   The split's demo story at 4B is therefore *capability/privacy* (models too big
   for the phone, LAN-only mesh), not speed. A speedup story needs either a
   bigger model (8B+ won't fit the phone at all) or RTT ≤ ~10 ms (5 GHz close
   range / phone Wi-Fi power-save off).
4. **pp jitter (±30) is the link**, matching the RTT spread; prefill remains the
   Wi-Fi-sensitive phase as predicted.
5. **Baseline discrepancy to re-verify:** 2026-08-04 on-device numbers (~10.6 tg,
   50–92 pp) are ~2.4× lower than today's (25.5 / 141.3) — uniform across phases,
   so likely governor/thermal/screen state, not measurement noise. Today's A/B is
   same-session and internally consistent; yesterday's "phone ≈ 10 t/s"
   characterization (and the all_local UX expectations built on it) needs a redo.

## RTT experiments — where the latency actually lives (2026-08-05)

Goal: get phone↔laptop RTT ≤ ~10 ms so the split can beat phone-local (25.5 tg).
Findings, in the order discovered:

1. **The venue backhaul is the main venue-Wi-Fi cost.** Hop-by-hop pings: phone→gateway
   18 ms, laptop→gateway 10 ms, phone→Mac 18 ms — but phone→laptop 66–81 ms. The phone
   and laptop associate to *different APs* (BSSIDs `…78:27` vs `…b0:07`) and the
   inter-AP mesh backhaul adds ~40–50 ms that no client-side setting can remove.
2. **Radio power-save dominates idle links.** Idle RTT avg 81 ms vs 13.5 ms min; still
   66 ms at 5 pps. At 15 t/s the ~60 ms inter-token gap lets the phone radio doze
   *between tokens* — sustained benches understate it, interactive chat feels it
   (the 4.7 t/s UX finding). Android's `cmd wifi force-low-latency-mode` is blocked
   for shell on this Samsung build; screen-on + keepalive traffic is the available
   mitigation (`svc power stayon true` + a 5 pps ping during sessions).
3. **Laptop-hotspot trap — same-radio band contention.** Windows Mobile Hotspot
   (FastConnect 7800) with Band=Auto placed the SoftAP on **5 GHz (ch 36)** while the
   laptop's own HaQathon STA held **6 GHz (ch 149)**. 5 and 6 GHz share one radio
   chain on this chip, so the radio time-slices between the two networks: the
   phone's link *looked* perfect (600/864 Mbps, −49 dBm, ping min 5 ms) but the
   sustained per-token RPC exchange collapsed — **58.0 pp / 9.58 tg, worse than the
   venue path**. The 5 GHz band is not the problem; sharing the high-band radio with
   the 6 GHz uplink is. Fix: pin the hotspot to **2.4 GHz**, which lives on the
   chip's separate second radio → both links run concurrently. (The WinRT
   `ConfigureAccessPointAsync` silently ignores SSID/Band changes on this Windows
   build — the Settings UI is the only way that sticks.)

| Path (all same phone/laptop/model) | RTT avg | Split pp128 | Split tg32 |
|---|---:|---:|---:|
| Venue Wi-Fi, cross-AP backhaul | 66–81 ms | 84.3 | 15.5 |
| Laptop hotspot, 5 GHz SoftAP vs 6 GHz STA (radio-contended) | 8–47 ms jittery | 58.0 | 9.6 |
| Laptop hotspot, **2.4 GHz** SoftAP (independent radio, clean) | **6.5 ms** | 99.8 | **13.95** |
| Phone all-local reference (same session on hotspot: 132.0 pp / 24.8 tg) | — | 132–141 | ~25 |

4. **Definitive 4B verdict: link quality doesn't save the split.** With ping RTT at
   6.5 ms, split decode still costs ~72 ms/token — ~43 ms of unexplained-by-ping
   network overhead. ggml-rpc makes *multiple sequential round trips per token*
   (set_tensor → graph_compute → get_tensor), each paying radio wake + airtime, so
   per-token network cost lands at 40–70 ms on every real wireless link tried. The
   venue path (12× worse ping) actually decoded slightly *faster* than the clean
   2.4 GHz hop — per-exchange serialization, not link RTT, dominates. **No
   achievable Wi-Fi makes the 4B split beat the phone alone (~25 tg).** The split's
   value is capability (models beyond the phone) + privacy, full stop. A speed story
   would need protocol batching upstream in llama.cpp, wired transport, or a much
   bigger model where compute dwarfs the fixed ~50 ms/token network tax.
5. Ops notes from the experiment (hard-won):
   - llama-bench **silently falls back to CPU-only** when the worker is unreachable
     ("Failed to connect" + backend column = CPU, no `ngl`) — always check the
     backend column before believing a "split" number.
   - **The worker serves exactly one client.** ggml-rpc-server accepts serially; a
     second MAIN llama-server pointed at the same worker (e.g. a zombie serve
     script still holding its instance while a new one launches) stalls the loser's
     RPC calls into `send failed (bytes_sent=0)` → "Remote RPC server crashed or
     returned malformed response" → abort. Most "mystery crashes" during bring-up
     were this, not the link. One llama-server per worker, ever; kill with
     `pkill -f 'llama-serve[r]'` (bracket avoids the pkill matching its own
     command line — twice bitten).
   - One genuine **silent worker death** occurred (no stderr, no WER/Defender
     event, log ends mid-stream; cause unknown). The worker now runs inside a
     `for /l` cmd restart loop that stamps `[worker exited N]` into `worker.log` —
     0 exits since.
   - The phone-side MAIN **aborts (no reconnect) whenever the worker connection
     breaks** — llama.cpp RPC has no retry. Demo recovery = relaunch the phone
     server (worker weight cache makes reload ~40 s).
   - Keep the phone radio held during sessions: screen on (`settings put system
     screen_off_timeout 600000`) + a looped 5 pps keepalive ping; `svc power
     stayon true` only holds while charging; Android's low-latency Wi-Fi mode is
     shell-blocked on this Samsung build.

**Demo topology decision (2026-08-05):** the demo runs on the **laptop hotspot**
(2.4 GHz, SSID `QCWORKSHOP4 4333`, laptop `192.168.137.1`, phone `192.168.137.2`) —
self-contained, immune to venue-Wi-Fi congestion, phone keeps internet through the
laptop's HaQathon uplink (separate radio), and the "private mesh" story is literal.
Perf vs venue is a wash (tg 14.0 vs 15.5).

## Runbook — big-model split via a pre-warmed worker cache (2026-08-06)

The "only possible together" demo needs a model far bigger than 4B, and the naive
path is blocked by weight transfer: at `-ngl 36` on a 14B Q4_0 the MAIN streams
**~7.5 GB** to the worker, which is 15–25 min over the 2.4 GHz hotspot. This
removes that cost without touching any code.

**Why the transfer exists (and why it can't be reversed).** ggml-rpc has no command
for "worker, load layer N from your own disk" — the MAIN opens the GGUF and pushes
every offloaded tensor. The direction is a property of the protocol, not of our
scripts.

**Why the cache escapes it.** `ggml-rpc.dll` (b10270) exports `set_tensor_hash`
alongside `set_tensor`, and the server prints a `local cache : %s` line with
hash-bucket handling. With `-c`, the client sends the tensor's **content hash**
instead of its bytes; the worker looks the hash up in
`%LOCALAPPDATA%\llama.cpp\rpc\` and loads from its own disk on a hit, falling back
to a full transfer only on a miss. Because the key is the tensor *data*, **it does
not matter which client populated the entry** — the laptop can warm its own cache
at disk speed and the phone then pays nothing.

**Recipe:**

1. **Download the GGUF directly onto the laptop.** Do not route it through the phone.
2. **Pre-warm at loopback speed, on the laptop.** Start the worker with `-c`, then
   run one short `llama-bench` as MAIN against `127.0.0.1:50052` with **`-ngl 99`** —
   offloading *every* layer, so the cache holds a superset of whatever the phone
   later requests and any phone-side `NGL` is a guaranteed subset. Seconds, not
   minutes.
3. **Push the same GGUF to the phone over USB adb.** Still required: MAIN reads the
   file for metadata and to compute the hashes. USB, not Wi-Fi — minutes.
4. **Run the split normally.** All hash hits → no bulk transfer over the air.

**Verification signal:** phone-side load comes up in **~40 s** (cache hit) or grinds
for **minutes** (miss). You know within a minute of starting. *The cross-client hit
is inferred from the cache being content-addressed and has not yet been run — this
step is the go/no-go.*

**Gotchas:**

- **`NGL` is model-specific.** Qwen3-14B has **40** layers, not 36, so "first 4 on
  the phone" is `-ngl 36`. `phone_split.sh` defaults to `NGL=32` but both `MODEL`
  and `NGL` are env-overridable — `MODEL=… NGL=36 ./scripts/phone_split.sh serve <ip>`.
  No script edits needed.
- **Laptop cache disk:** a 14B adds ~8.5 GB on top of the 4B's ~1.9 GB in the RPC
  cache dir. Check free space first.
- **Model sizing, corrected:** 8B Q4_0 (~4.7 GB) probably *does* fit the phone's
  11.4 GB, so it does not carry the "impossible alone" claim. **14B Q4_0 (~8.5 GB)**
  is the smallest size that plausibly OOMs the phone; verify the phone-alone failure
  on camera rather than asserting it.

## Next

- [ ] Hexagon build on this laptop (Hexagon SDK 6.6 + OpenCL SDK + TESTSIGNING) → rerun with `-Devices HTP0` (L1 proof, laptop side)
- [ ] Android builds on the x86 box: official `android-arm64` CPU tarball first (L2), Docker Hexagon build after (L1, phone side)
- [x] Two-device rerun over real Wi-Fi (phone main → laptop worker) — see above (2026-08-05)
- [x] Re-bench phone all-local under controlled state — **126.8 pp / 24.5 tg r=3** (2026-08-06,
  unplugged, 90 %, 28 °C): confirms 25.5; the 08-04 "10.6" was a bad-state artifact
- [x] RTT knob — see *RTT experiments* above; 2.4 GHz hotspot leg pending
- [x] Big-model split — done at **30B-A3B**, not 14B; see §30B below (2026-08-06)
- [x] Cross-client cache hit — **confirmed with a caveat**: hits are per-worker-*build*; see §30B

## Energy / latency / memory suite — all four modes (2026-08-06, evening)

**Method** (raw data + tools in [`../results/energy/`](../results/energy/)): battery telemetry at 1 Hz via
`dumpsys battery` (sysfs is shell-blocked on this Samsung build) — `current now` (µA) ×
`voltage` (mV) integrated over marked windows, coulomb-counter delta as cross-check; the
sampler and workload driver run ON the phone under nohup (adb-drop-proof); fixed 512-token
essay prompt, temp 0, driven from the phone via curl (the app's exact path); screen on,
brightness fixed 128, unplugged, hotspot topology. Windows ≥ ~1 min (the fuel gauge smooths
shorter windows into noise — two identical 25 s runs read 1.25 vs 9.10 W).

| Mode (4B Q4_0) | avg W | ΔJ/token | eff. t/s | phone RSS |
|---|---:|---:|---:|---:|
| Idle, screen on | 0.61 | — | — | — |
| On-device CPU (`:8082`) | **8.6** | 0.41 | 19–24 | 5.27 GB |
| On-device NPU HTP0 | 8.5–12.6 | 0.44–0.72 | ~17 | **0.81 GB** |
| **Split → laptop worker** | **3.5** | **0.29** | 10–11 | ~1.0 GB |
| Remote (laptop hvx `:8082`) | **3.0** | 0.25 | ~11 | ~0 |

1. **Offload halves-plus the phone's power: 8.6 → 3.5 W (−2.5×), ΔJ/token 0.41 → 0.29 (−30 %).**
   The mesh is a battery feature, not just a capability feature.
2. **Keepalive ablation (split, same session):** decode **2.07 / 3.67 t/s with radio doze** vs
   **10.3 t/s avg with a 5 pps keepalive** (~4×); TTFT up to 2.8 s dozed. Radio power-save, not
   bandwidth, is the interactive-UX enemy (confirms the 4.7 t/s finding, now quantified).
   Remote-mode SSE receive suffers the same doze without keepalive.
3. **The experimental Hexagon path is slower AND hungrier than CPU on both devices**: phone
   HTP0 17 t/s @ ≥8.5 W (vs CPU 24 t/s @ 8.6 W — `GGML_HEXAGON_OPPOLL=1` busy-polls a core,
   load-avg ~10 idle); laptop hvx llama-server **~15 t/s solo (132 ms/tok)** — the 37.5 t/s
   "Remote" figure was the b10270 *CPU* server. Its one big win: **RSS 0.81 GB vs 5.27 GB**
   (weights live on the NPU, `--load-mode none`).
4. Laptop during split decode: ~52–57 % total CPU (typeperf CSVs in `energy/`).
5. Ops: llama-server's SSE hangs after ~1 gen on `:8082` engines (data complete, no `[DONE]`,
   kept alive by `--sse-ping-interval`) — the windows were closed from stream byte-counts;
   `pkill -f`/`pgrep -f` self-match bit us repeatedly — bracket every pattern (`pin[g]`).

## 30B-A3B split — "only possible together", proven (2026-08-06, night)

Model: `qwen3-30b-a3b-instruct-2507-q4_0.gguf` (17.4 GB, 48 layers, MoE 3B-active), byte-identical
SHA-256 on laptop and phone (pushed over USB at 38.6 MB/s). Raw logs in [`../results/bigmodel/`](../results/bigmodel/).

1. **Phone alone: zero tokens, phone disabled.** `llama-cli -ngl 0` never finished loading —
   the 17.4 GB mmap thrashed 11.4 GB of RAM so hard the phone dropped off Wi-Fi entirely for
   ~10 min, killed adbd and the measurement harness, and silently re-joined a different network.
   `oom30b.log` is an endless load spinner. Film exactly this tomorrow.
2. **Split (first 4 layers on phone, 44 on laptop): correct answers at 7.2–11.5 t/s decode**
   (87–139 ms/tok), prefill ~6 t/s. Same ~10 t/s as the 4B split — **network cost is flat per
   token, so model size is nearly free until the worker saturates**. That's the architecture's
   whole thesis in one number: 7.5× the parameters at equal speed.
3. Placement proof: worker WS **15.0 GB**, phone MAIN RSS **1.5 GB**, worker-side RPC cache
   grew to 17.0 GB.
4. **Cache-hit caveat (important for the demo):** the content-addressed cache is effectively
   **per-worker-build**. A cache warmed through the b10270 CPU worker did NOT serve the hvx NPU
   worker (the MAIN started streaming 16 GB at ~8 MB/s); after that worker died, the retry
   landed on the b10270 CPU worker (wildcard bind) and loaded from cache in **98 s** with only
   ~0.5 GB over the air. Warm the cache through the same worker binary you'll demo on.
5. **The hvx NPU worker dies on the 30B MoE graph** (process gone mid-load; also cannot be
   relaunched over ssh — Hexagon FastRPC refuses session-0/WMI processes, `0x80000406`; it
   needs a console launch). Demo routing today: NPU worker alive on the specific bind gets the
   phone; when it's absent, the b10270 CPU worker's `0.0.0.0` listener takes over. **Give 4B to
   the NPU worker, 30B to the CPU worker.**
