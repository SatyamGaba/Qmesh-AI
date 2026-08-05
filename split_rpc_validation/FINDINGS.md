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

## Next

- [ ] Hexagon build on this laptop (Hexagon SDK 6.6 + OpenCL SDK + TESTSIGNING) → rerun with `-Devices HTP0` (L1 proof, laptop side)
- [ ] Android builds on the x86 box: official `android-arm64` CPU tarball first (L2), Docker Hexagon build after (L1, phone side)
- [x] Two-device rerun over real Wi-Fi (phone main → laptop worker) — see above (2026-08-05)
- [ ] Re-bench phone all-local under controlled state (charger, screen, governor) to resolve the 10.6-vs-25.5 tg discrepancy
- [ ] RTT knob: retry split bench at 5 GHz / close range / Wi-Fi power-save off — the only path to a 4B speedup story
- [ ] 8B-class model split (doesn't fit the phone alone) — the "only possible together" demo
