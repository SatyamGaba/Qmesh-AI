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

## Next

- [ ] Hexagon build on this laptop (Hexagon SDK 6.6 + OpenCL SDK + TESTSIGNING) → rerun with `-Devices HTP0` (L1 proof, laptop side)
- [ ] Android builds on the x86 box: official `android-arm64` CPU tarball first (L2), Docker Hexagon build after (L1, phone side)
- [ ] Two-device rerun over real Wi-Fi (phone main → laptop worker), measure pp/tg vs these numbers
