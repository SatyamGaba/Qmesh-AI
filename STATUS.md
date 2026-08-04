# QMesh — Status & Next Steps (live)

**This is the working doc — update it as things change.** Durable design lives in
[`ARCHITECTURE_PLAN.md`](./ARCHITECTURE_PLAN.md); this file tracks what's tested, what's
next, and open questions.

**Last updated:** 2026-08-04
**Overall state:** validated on one machine (loopback CPU split) — pre-two-device.
**Current fallback rung (see ARCHITECTURE_PLAN §5):** L3 (both-CPU) proven on loopback;
targeting L1 (both-NPU). See [Next steps](#next-steps).

---

## What is TESTED (as of 2026-08-04)

Same-machine validation, `QMesh_AI\split_rpc_validation\` (official llama.cpp
`b10270` win-arm64 **CPU** prebuilts — which ship `ggml-rpc-server.exe`; zero
compilation, zero signing at this tier). Model: Qwen3-4B Q4_0, llama-bench
pp128/tg32, loopback TCP, both roles sharing the 12-core Oryon CPU:

| Shape | Prefill t/s | Decode t/s |
|---|---:|---:|
| Baseline — all 36 layers local, no RPC | 213.9 | 37.5 |
| Split — 18 layers on worker | 122.1 | 34.2 |
| Split — first 4 on main, 32 on worker (`-ngl 32`) — **deployment shape** | 88.4 | 33.2 |
| Two-port — A(:50052)=4 layers, B(:50053)=32, main holds none | 76.8 | 30.7 |
| All-remote — every layer on worker | 83.3 | 34.2 |

Also verified: correct generations through the splits (18-layer: 19.0 t/s cold;
two-port 4/32: 31.5 t/s, placement confirmed via per-worker compute buffers
331/323 MiB); GenieX all_remote + laptop_local modes (prior work, ~42 tok/s NPU);
supervisor EXE + web GUI.

**Conclusions:** the RPC split mechanism is fully retired as a risk on the host
side (~9% decode penalty on loopback); Oryon CPU decodes 4B Q4_0 at 37.5 t/s
(within ~12% of the GenieX NPU), so CPU fallbacks are presentable; Wi-Fi
projection ~22–29 t/s decode for the two-device split; prefill is the phase that
will feel Wi-Fi first (214→122 on loopback already).

**NOT yet tested:** anything across two real devices; anything on the phone;
Hexagon NPU through rpc-server (`--device HTP0` — undocumented for RPC, unverified)
— the single remaining L1 unknown; llama.cpp on the phone (GenieX-on-phone is not a
path — no Android server, see ARCHITECTURE_PLAN §4).

---

## Next steps (two concurrent tracks)

Strategy: get a complete **CPU** system demo-ready first (Track A) so there is always a
shippable floor, while starting the **NPU** environment work on day 1 (Track B) because its
blockers have the longest lead time. The two tracks converge cheaply — the app talks to engines
over the OpenAI HTTP/SSE boundary, so swapping a CPU engine for an NPU engine on the same port is
a config change, not an app change. **Gates:** A5 is the safety net (never lose it); B3 gates B4;
B1's corp-policy answer determines whether L1 or L2.5 is the NPU ceiling.

### Track A — App + guaranteed demo floor (sequential, low-risk)
1. **Two-device CPU split (L3), no building:** official `b10270` android-arm64 tarball on the
   S25 (Termux/adb) as MAIN → `--rpc <laptop-ip>:50052` to the laptop worker
   (`start_worker.ps1 -BindHost 0.0.0.0` + firewall rule scoped to the phone IP; **pre-flight
   ping to rule out Wi-Fi AP/client isolation**; DHCP-reserve both). Measure pp/tg over real
   Wi-Fi vs the tested table above. *Highest-information first hour.*
2. **Phone `all_local` on CPU:** llama-server from the same tarball on `:8082` — a working local
   mode, zero building (NPU swap arrives via Track B).
3. **Wire `all_remote` (GenieX on laptop):** already proven (~42 tok/s), no signing — a free
   early *real-NPU* mode that doesn't depend on the split.
4. **Client:** replace `mockModel.ts` (the single `ChatModelAdapter`) with a real
   OpenAI-compatible SSE streaming adapter + a mode picker mapping `/local /split /remote`;
   stand up the phone loopback proxy (serves the PWA + fans out to the 3 engines); wrap in a
   thin **WebView APK** (`usesCleartextTraffic` for localhost). PWA host: `output: 'export'`
   static bundle served by the proxy is simplest.
5. **→ End-to-end system demo-ready** (3 modes; split + all_local on CPU, all_remote on NPU).
   This is the floor — never regress below it.

### Track B — NPU validation (starts day 1, parallel to A)
1. **Unblock the environment immediately** (longest lead time): **corp-policy check on
   `TESTSIGNING`** (needs admin + reboot); install Hexagon SDK 6.6.0.0 + Adreno OpenCL SDK 2.3.2
   on the laptop (**no QAIRT needed** for native HVX); pull the Docker toolchain image
   (`ghcr.io/snapdragon-toolchain/arm64-android`) for the Android build. If `TESTSIGNING` is
   forbidden → L2.5 Adreno/OpenCL is the no-signing NPU path.
2. **Verify `--device HTP0` exposes HTP to rpc-server** — undocumented for RPC
   (ARCHITECTURE_PLAN §4), the one remaining mechanism unknown.
3. **Single-device HTP on each side, standalone:** laptop v73, then phone v79 (Android build,
   adb-push). Isolates faults *before* any split.
4. **Both-NPU split (L1):** only after B3 passes. Highest-risk rung (cross-version bugs
   #25102/#25876); fail gracefully to L2 (phone CPU + laptop HTP) or L2.5 (GPU). Rerun
   `bench_split.ps1` with worker `--device HTP0`.

### Converge + polish
- **Cutover:** point the proxy at the NPU engine ports (config change, not app change).
- **Supervisor:** add a `split_worker` engine (launch/monitor rpc-server); PyInstaller EXE
  refresh; APK packaging.
- **Tuning:** asymmetric split sweep (`-Threads 2` weak worker; ratios 4/32, 8/28, 12/24,
  14/22) → pick the ratio; thermal soak on phone.
- **Post-demo (out of hackathon scope):** WireGuard mesh, engines embedded in APK (JNI),
  signed Windows packaging, model-name-based mode routing on one gateway port.

---

## Open questions

1. Is `TESTSIGNING ON` permitted on this (possibly corp-managed) laptop? Load-bearing for the
   L1 laptop-HTP build; L2.5 Adreno/OpenCL is the no-signing escape if it's blocked.
2. Does HTP actually register as an rpc-server device (`--device HTP0`)? Undocumented for RPC
   (ARCHITECTURE_PLAN §4) — the single remaining L1 mechanism unknown; verify before committing
   to the both-NPU split.
3. Is L2 (or L2.5 GPU) an acceptable demo floor if the schedule bites, or is both-NPU non-negotiable?
4. Later: bigger model (8B split = "only possible together") or pipelined speculation for speedup?
5. Later (out of scope): WireGuard 2-peer mesh to encrypt both planes and make the "private mesh"
   story literal — validated as practical but deferred past the hackathon.
