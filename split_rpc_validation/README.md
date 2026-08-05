# split_rpc_validation

Same-machine validation of **layer-split LLM inference over ggml-RPC**, de-risking
the QMesh split mode (phone NPU + laptop NPU) before any cross-device work.

Topology being emulated (both roles on this laptop, loopback TCP standing in
for Wi-Fi):

```
  main host (phone role)                RPC worker (laptop role)
  llama-cli / llama-server   ───TCP──►  ggml-rpc-server :50052
  layers 1..N-k on local CPU            layers on its devices (-d CPU|HTP0)
```

## Layout

| Path | What |
|------|------|
| `bin/` | Official llama.cpp `b10270` win-arm64 **CPU** build (incl. `ggml-rpc-server.exe`) |
| `%LOCALAPPDATA%\qmesh_split\models\` | GGUF models (kept out of OneDrive sync) |
| `start_worker.ps1` | Start an RPC worker (parameterized: port, bind host, devices) |
| `start_worker_a.ps1` | Worker A on :50052 — "phone role" end (first layers in a `4,32` split) |
| `start_worker_b.ps1` | Worker B on :50053 — "laptop role" end (remaining layers) |
| `bench_split.ps1` | llama-bench: baseline vs split vs all-remote; `-TensorSplit 4,32` for two-worker splits |
| `chat_split.ps1` | Single-turn generation sanity check through the split |
| `FINDINGS.md` | Validation results log |

Models staged: `qwen3-4b-instruct-2507-q4_0.gguf` (2.4 GB, 36 layers — same
model family/revision as the GenieX NPU deployment) and
`qwen2.5-0.5b-q4_0.gguf` (bring-up toy).

## Usage

```powershell
# terminal 1 - worker
.\start_worker.ps1

# terminal 2 - benchmark the three shapes
.\bench_split.ps1

# or a live generation through the split
.\chat_split.ps1 -Ngl 18 -Prompt "Explain KV cache in one sentence."

# two-worker shape: first 4 layers on worker A, rest on worker B
.\start_worker_a.ps1   # terminal 1
.\start_worker_b.ps1   # terminal 2
.\bench_split.ps1 -Rpc "127.0.0.1:50052,127.0.0.1:50053" -NglList 99 -TensorSplit 4,32
.\chat_split.ps1  -Rpc "127.0.0.1:50052,127.0.0.1:50053" -Ngl 99 -TensorSplit 4,32

# "first 4 layers on the MAIN host, rest on one worker" (real deployment shape)
.\bench_split.ps1 -Rpc 127.0.0.1:50053 -NglList 32
```

`requirements.txt`/`run.ps1` exist for QUAD-workspace convention; there are no
Python dependencies (native binaries only).

## Why Q4_0

The Hexagon NPU backend supports f32 / q4_0 / q8_0 / mxfp4 (repacked types).
Staying on Q4_0 now means the same GGUF carries over unchanged when the worker
device becomes `HTP0`.

## Next steps toward the real split

1. Hexagon build of llama.cpp on this laptop (Hexagon SDK 6.6 + OpenCL SDK,
   `TESTSIGNING ON` + self-signed cert for the HTP ops `.cat`) → rerun
   `bench_split.ps1` with the worker on `-Devices HTP0`. That is the L1 proof.
2. Android build (Docker toolchain on the x86 box) → phone becomes the main
   host, this laptop keeps the worker role: `start_worker.ps1 -BindHost 0.0.0.0`.
3. Wrap in the QMesh supervisor as the `split_worker` engine.

See `FINDINGS.md` for measured results.
