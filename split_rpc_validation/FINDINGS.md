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
5. Ops notes from the experiment: llama-bench **silently falls back to CPU-only**
   ("Failed to connect" + backend column = CPU, no `ngl`) — always check the
   backend column before believing a "split" number. A worker killed mid-session can
   leave one "Remote RPC server crashed or returned malformed response" load
   failure; fresh worker relaunch cleared it (weight cache survived intact). Keep
   the phone radio held during any session: screen on (`settings put system
   screen_off_timeout 600000`) + a 5 pps keepalive ping; `svc power stayon true`
   only holds while charging.

**Demo topology decision (2026-08-05):** the demo runs on the **laptop hotspot**
(2.4 GHz, SSID `QCWORKSHOP4 4333`, laptop `192.168.137.1`, phone `192.168.137.2`) —
self-contained, immune to venue-Wi-Fi congestion, phone keeps internet through the
laptop's HaQathon uplink (separate radio), and the "private mesh" story is literal.
Perf vs venue is a wash (tg 14.0 vs 15.5).

## Next

- [ ] Hexagon build on this laptop (Hexagon SDK 6.6 + OpenCL SDK + TESTSIGNING) → rerun with `-Devices HTP0` (L1 proof, laptop side)
- [ ] Android builds on the x86 box: official `android-arm64` CPU tarball first (L2), Docker Hexagon build after (L1, phone side)
- [x] Two-device rerun over real Wi-Fi (phone main → laptop worker) — see above (2026-08-05)
- [ ] Re-bench phone all-local under controlled state (charger, screen, governor) to resolve the 10.6-vs-25.5 tg discrepancy
- [x] RTT knob — see *RTT experiments* above; 2.4 GHz hotspot leg pending
- [ ] 8B-class model split (doesn't fit the phone alone) — the "only possible together" demo
