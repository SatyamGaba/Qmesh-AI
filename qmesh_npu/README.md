# qmesh_npu — native HVX build of llama.cpp for the Snapdragon X Elite NPU

Track B laptop half: llama.cpp **b10288** (commit `360e134`) built from source with the
native `ggml-hexagon` backend, so layers execute on the Hexagon **HTP v73** NPU via HVX/HMX.
No QNN/QAIRT involved.

Measured live on `X1E80100`: `threads 4, hvx 4, hmx 1, vtcm 8 MB`.

## What's here

| Path | |
|---|---|
| `hvx/` | **Runnable package.** `llama-server`, `llama-cli`, `llama-bench`, `ggml-rpc-server`, `ggml-hexagon.dll`, the four `libggml-htp-v{73,75,79,81}.so` DSP skels, and the signed `libggml-htp.cat`. |
| `build_hvx.ps1` | Configure + build + install. Self-heals a relocated build tree. |
| `install_cert.ps1` | Elevated: trusts `CN=GGML.HTP.v1` machine-wide. |
| `stage_hvx.ps1` | Flattens `pkg-hvx/` into `hvx/`, verifies the catalog signature. |
| `verify_hvx.ps1` | Device enumeration, benches, `rpc-server --device HTP0`. |
| `sweep_hvx.ps1` / `ab_hvx.ps1` | Tuning-knob sweep / interleaved A-B harness. |
| `run_npu_server.ps1` | Serve the model on HTP0. `-BindHost` / `-Port` / `-Model`. |
| `*.log` | Build and measurement output. |

Not versioned (see `.gitignore`): the Hexagon SDK, the llama.cpp clone, build trees, and
the signing **private key**. Only the public `.cer` is committed.

## Running it

Binaries **must be run from inside `hvx/`** — `ggml-hexagon` asks FastRPC for the DSP skel by
bare filename (`file:///libggml-htp-v73.so`), which resolves against the *current working
directory*, not the exe path. Run from elsewhere and the session fails to open, then
llama.cpp aborts on `GGML_ASSERT(device)` instead of falling back.

```powershell
.\run_npu_server.ps1                      # binds 192.168.137.1:8082 (hotspot)
.\run_npu_server.ps1 -BindHost 127.0.0.1  # laptop only
```

`GGML_HEXAGON_OPPOLL=1` is set by the launcher: measured **+30% prefill / +34% decode**.
It swaps the blocking dspqueue wait for non-blocking polling.

## Rebuilding from scratch

Needs, outside this tree: Hexagon SDK 6.6.0.0, Adreno OpenCL SDK 2.3.2
(`C:\Qualcomm\OpenCL_SDK\2.3.2`), Windows SDK **10.0.26100.0** (26100 carries `Inf2Cat`;
22621 does not), VS 2022 with clang, CMake, ninja. Then `.\build_hvx.ps1`.

Two traps that silently produce a broken package:

1. **`HEXAGON_HTP_CERT` unset** → no `libggml-htp.cat` is generated at all. CMake only adds
   the signing target when that variable is non-empty, so you get a complete-looking build
   whose DSP libs can never load.
2. **The `arm64-windows-snapdragon-release` preset leaves `GGML_RPC=OFF`** → no
   `ggml-rpc-server.exe`, i.e. no split worker. Must pass `-DGGML_RPC=ON`.

Signing also requires `bcdedit /set TESTSIGNING ON` (+ reboot, Secure Boot off) and the cert
trusted in LocalMachine `Root` + `TrustedPublisher` — `install_cert.ps1` does the trust half.

## Measurements

Qwen3-4B-Instruct-2507 Q4_0, `pp128/tg32`. **Taken on battery** (74%→27%, Balanced scheme),
so absolute values are depressed and drift downward across a session — treat them as
directional. See `STATUS.md` for the full write-up.

| | prefill t/s | decode t/s |
|---|---:|---:|
| HTP0 (native HVX) | 433 | 12.2 |
| HTP0 + `OPPOLL=1` | 449 | 15.0 |
| CPU, same build | 363 | 33.6 |

The NPU wins prefill and **loses decode by ~2.7×**. Disabling HMX (`NHMX=0`) lifts decode to
15.3 but collapses prefill ~35× to 9.8 — HMX carries prefill almost entirely. `OPPOLL=1`
gets the same decode gain with no prefill cost, so it strictly dominates.
