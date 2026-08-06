# QMesh — Status & Next Steps (live)

**This is the working doc — update it as things change.** Durable design lives in
[`ARCHITECTURE_PLAN.md`](./ARCHITECTURE_PLAN.md); demo-facing capabilities + talking points
in [`docs/FEATURES.md`](./docs/FEATURES.md); this file tracks what's tested, what's next,
and open questions.

**Last updated:** 2026-08-05 (evening)
**Overall state:** **The two-device RPC split is live and all three demo modes are staged**
(Track A1 done). RTT experiments concluded (FINDINGS §RTT): even at 6.5 ms ping the split
decodes 14 t/s vs ~25 t/s phone-alone — ggml-rpc's multiple round trips per token cost
40–70 ms on every real wireless link, so **at 4B the split is definitively a
capability/privacy story, not a speedup**. **Demo topology: the laptop's 2.4 GHz Mobile
Hotspot** (self-contained, venue-independent; laptop `192.168.137.1`, phone
`192.168.137.2`, phone gets internet through the laptop). Remaining work: NPU (Track B —
materials found on-laptop in the OneDrive workspace) and app polish.
**Current fallback rung (see ARCHITECTURE_PLAN §5):** **L3 (both-CPU) proven across two real
devices**; targeting L1 (both-NPU). See [Next steps](#next-steps).

---

## Devices — live connections (as of 2026-08-05)

**Dev box is now this MacBook Pro** (the WSL2 setup is retired). It sits on the same
Wi-Fi LAN as both devices — no NAT caveats. Per-device IPs/MACs live in
`LOCAL_NETWORK.md` (gitignored).

Phone (the target MAIN device, Track A step 1) is connected over **wireless ADB**:

| Field | Value |
|---|---|
| Model | Samsung **SM-S938U1** (Galaxy S25 Ultra) |
| Android | 16 |
| adb serial | `R3CXC08036V` (product `pa3quew`, device `pa3q`) |
| Connect address | `10.73.51.75:46051` (adb-over-TCP) |
| State | `device` (authorized) |

Laptop (the RPC worker, Snapdragon X Elite, hostname `qcworkshop4`) is reachable over
**ssh**: `qc_de@10.73.51.58` (key auth from the Mac, admin token). Remote PowerShell
works best via `powershell -NoProfile -EncodedCommand <base64 UTF-16LE>` — plain `ssh
host "powershell -Command ..."` lands in cmd.exe and mangles pipes/quotes.

**To reconnect after a drop/reboot** (pairing keys survive; only the connect step is
needed — the **port changes each time** Wireless debugging restarts, so re-read it from
the phone's Wireless-debugging screen):

```bash
adb connect 10.73.51.75:<current-port>
adb devices -l
```

If it says *unpaired*, redo pairing (one-time code + a **separate** pairing port from the
phone's "Pair device with pairing code" dialog): `adb pair 10.73.51.75:<pair-port> <6-digit-pin>`.

For PWA testing once connected: `adb reverse tcp:3000 tcp:3000`, then open
`http://localhost:3000` in Chrome on the phone (localhost = secure context → service workers /
installable PWA work without HTTPS).

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

**Two-device, real Wi-Fi (2026-08-05, phone MAIN `-t 6` → laptop worker `-t 10`):**

| Shape | Prefill t/s | Decode t/s |
|---|---:|---:|
| Phone all-local baseline (same session) | 141.3 | 25.5 |
| **Split — first 4 on phone, 32 on laptop worker** | 84.3 ± 30.1 | 15.5 ± 0.5 |

Also verified: correct generations through the splits (18-layer: 19.0 t/s cold;
two-port 4/32: 31.5 t/s, placement confirmed via per-worker compute buffers
331/323 MiB); GenieX all_remote + laptop_local modes (prior work, ~42 tok/s NPU);
supervisor EXE + web GUI.

**Conclusions:** the RPC split mechanism is fully retired as a risk on the host
side (~9% decode penalty on loopback); Oryon CPU decodes 4B Q4_0 at 37.5 t/s
(within ~12% of the GenieX NPU), so CPU fallbacks are presentable; Wi-Fi
projection ~22–29 t/s decode for the two-device split; prefill is the phase that
will feel Wi-Fi first (214→122 on loopback already).

### Client / app plane (NEW, 2026-08-04) — real chat streaming cross-device

The PWA's inference seam is no longer a mock. Track A step 4's core is done and
**verified end-to-end over real Wi-Fi**:

- **Adapter:** replaced the mock-only path with a config-selected `ChatModelAdapter`
  (`src/lib/openaiModel.ts`, OpenAI-compatible `/v1/chat/completions` SSE — buffered
  chunk parsing, `[DONE]` terminator, `abortSignal`, readable network/HTTP errors).
  `src/lib/config.ts` resolves the engine from localStorage → `NEXT_PUBLIC_*` env →
  mock fallback, so the target repoints at runtime with no rebuild
  (`qmeshSetEngine({...})` on `window`). Mock retained as the offline floor.
- **Engine under test:** laptop **llama-server b10270** (same `split_rpc_validation\bin`),
  `Qwen3-4B-Instruct-2507 Q4_0`, launched `--host 0.0.0.0 --port 8082 --alias qwen3-4b
  -c 4096 --sse-ping-interval 15 --cors-origins * --no-cors-credentials`. Base URL
  `http://10.73.51.58:8082/v1` (laptop LAN IP), model id `qwen3-4b`, **no auth**.
  `--no-cors-credentials` is load-bearing: default `Allow-Credentials:true` + `Origin:*`
  is spec-invalid and Chrome rejects it (looks fine in curl, fails in-browser).
- **Verified:** phone (S25) → laptop `GET /v1/models` **HTTP 200 in 17 ms**; SSE stream
  from the phone shows incremental `delta.content` → `[DONE]`; browser round-trip returned
  a real model answer ("Tokyo", not the canned mock string), no console errors. Laptop
  measured 88 tok/s prefill / 37.6 tok/s decode (matches `FINDINGS.md` baseline). No Wi-Fi
  AP/client isolation on this network (laptop→phone ping 3/3; phone→laptop HTTP confirms
  the reverse direction the ping alone can't).
- **Dev-env bug fixed (dev-only):** the composer was stuck disabled under `next dev` —
  React Strict Mode's double-mount raced `useLocalRuntime`'s `history.load()` and left the
  thread `isLoading:true` (typing rejected, Send disabled, empty state missing). Set
  `reactStrictMode:false`; `npm build && start` was never affected (Strict double-invoke is
  dev-only). Commit `453b0ec`.

### all_local — llama.cpp running ON the phone (NEW, 2026-08-04) ✅

The phone's own on-device engine works — **Track A step 2 done on CPU**. No building, no
Termux, no root:

- **Binary:** official prebuilt `llama-b10270-bin-android-arm64.tar.gz` (CPU, Clang 21,
  aarch64), `adb push`'d to `/data/local/tmp/llama/` with its `.so`s (ships per-ISA CPU
  variants armv8.0–armv9.2; SM8750 picks armv9.2). Runs via
  `LD_LIBRARY_PATH=. ./llama-server`. Same tarball carries `libggml-rpc.so` → can double as
  the split worker later.
- **Model:** `qwen3-4b-instruct-2507-q4_0.gguf` (2.21 GiB) pushed to the phone (byte-exact,
  from `/.models/`, gitignored). A GGUF is self-contained (weights + tokenizer + chat
  template) — nothing else needed on the phone.
- **Launch:** `./llama-server -m <gguf> --host 127.0.0.1 --port 8082 --alias qwen3-4b -c 4096
  -t 6`. Model loads in ~24 s (cold), `listening on 127.0.0.1:8082`, `/health` → 200. Bound
  to phone loopback = **true radio-off local**; the phone's browser hits its own `localhost`.
- **Device:** Galaxy S25 Ultra, **Snapdragon 8 Elite (SM8750)**, 8 cores, ~11.4 GB RAM.
- **Measured on-device (4B Q4_0):** prefill ~50–92 t/s; **decode ~9–11 t/s** (llama-bench
  tg32: 10.5 @4t, **10.6 @6t**, 8.0 @8t — decode peaks at 6 threads; all-8 is *slower*,
  efficiency-core contention). Slower than laptop (~37 t/s) but usable and fully offline.
  **⚠ Superseded (2026-08-05):** an identical bench re-run measured **141.3 pp / 25.5 tg**
  — uniformly ~2.4× faster, likely governor/thermal/screen state on the earlier run. The
  phone's true CPU envelope needs a controlled re-bench (see FINDINGS §two-device, point 5).
- **Verified in the PWA:** picker **On-device** mode lit green (reachability probe) and
  streamed a real answer end-to-end ("Earth, Jupiter, Mars", format honored), no console
  errors. *Test caveat:* driven from the dev-box browser via `adb forward tcp:8082` (the
  dev box can't reach the phone's own loopback); the true phone-browser → phone-`localhost`
  path (no forward) is the same origin and expected to work, but hasn't been clicked
  through on the handset yet.
- **CORS note (differs from laptop):** this build echoes the specific `Origin` with
  `Allow-Credentials:true` — **spec-valid** (specific origin, not `*`), so no
  `--no-cors-credentials` needed here, unlike the laptop's `--cors-origins *` launch.

### Split mode wired into the picker (NEW, 2026-08-05) ✅

Track A1's integration half is done. `phone_split.sh serve` runs the split MAIN
llama-server on the phone's `:8081` (first 4 layers local, 32 → laptop worker; loads in
**37 s warm** thanks to the worker's `-c` weight cache vs minutes cold). `Qmesh-App/.env.local`
now maps the picker: Local→`localhost:8082`, Split→`localhost:8081`, Remote unset (greys out
as "NOT SET UP" — correct, laptop has no chat engine or model staged). **Verified end-to-end**
(dev-box browser + `adb forward` 8081/8082): picker shows On-device + Split green, Split
selected, real streamed answer ("Mercury, Venus, Earth"), request confirmed in the phone-side
`split.log`, no console errors.

**UX finding:** the same short interactive request decoded at ~4.7 t/s through the split
(212 ms/token, from `split.log` timings) vs 15.5 t/s sustained in llama-bench. Consistent
with Wi-Fi power-save: a bench keeps the radio hot; sporadic chat requests pay radio-wake
per token. Another reason the split story at 4B is capability/privacy, not speed — and
another thing a better link (5 GHz close range, power-save off) would improve.

### Remote mode wired — laptop llama-server on :8082 (NEW, 2026-08-05) ✅

All three engine modes are now staged. The laptop runs `llama-server` (same b10270 CPU
build, WMI-launched from `C:\Users\qc_de\QMesh_AI\split_rpc_validation\`, log
`llama-server-8082.log`) with the proven flag recipe (`--cors-origins *
--no-cors-credentials`). Model: byte-identical GGUF found already on the laptop in the old
**OneDrive workspace** (`C:\Users\qc_de\OneDrive\Documents\qmesh_ai\` — which also holds the
entire `qmesh_npu` tree: Hexagon SDK 6.6, hvx/adreno/b10150 builds, and the supervisor EXE —
Track B's materials are all local), copied to `C:\Users\qc_de\QMesh_AI\.models\`, SHA-256
verified against the Mac reference. **Verified from the phone** (nc HTTP through the
firewall): `/health` 200 and a real completion ("Paris") at **121.6 pp / 37.5 tg** — the
laptop's full-speed baseline. `.env.local` sets `NEXT_PUBLIC_ENGINE_REMOTE_URL=
http://10.73.51.58:8082/v1`.

**Firewall posture (resolves Open Question 6):** the engine runs from the *new* path, so the
old over-broad any-remote `llama-server.exe` program rules (pinned to the OneDrive exe path)
stay dormant; only the port rules scoped to the phone's IP admit traffic on 8082/50052. Net
effect: **the phone sees all three modes; the Mac dev browser shows Remote red** (its probes
are firewall-dropped — expected, not a bug). To probe from the Mac too, add `10.73.51.126`
to the 8082 rule's `-RemoteAddress` (needs elevation, run on the laptop).

### Native APK shell — the UI now lives ON the phone (NEW, 2026-08-05) ✅

Track A step 4 is fully done. `Qmesh-Android/` is a ~2.2 MB single-Activity WebView APK
(`ai.qmesh.app`, package **QMesh**) that **bundles the Next static export** and serves it to its
own WebView. One command builds and installs it:

```bash
cd Qmesh-Android && ./build-apk.sh --install
```

Why this mattered: until now the PWA reached the phone only via `adb reverse tcp:3000` from the
dev box, so **the MacBook was silently in the demo path even for "On-device, radio off"**. The
free workarounds were both dead ends — llama-server `b10270` has no `--path`/static-serve flag
(checked on-device), and an installable PWA needs a secure context (HTTPS or `localhost`), which
serving from the laptop's LAN IP is not. The APK was the only route to UI-on-phone.

- **Toolchain (Mac, all no-sudo):** `brew install openjdk@17` + `brew install --cask
  android-commandlinetools` (SDK root `/opt/homebrew/share/android-commandlinetools`), platform
  35/36 + build-tools. Gradle **wrapper pinned to 8.9** with **AGP 8.7.3**, compileSdk 35,
  minSdk 26 — deliberately boring; brew's Gradle 9.6.1 is only used to generate the wrapper.
- **Asset origin:** the export is served at `http://appassets.androidplatform.net` from
  `assets/www` via `shouldInterceptRequest`. **http, not https, on purpose** — the engines are
  plain-http, so an https page would hit mixed-content blocking; same scheme leaves only ordinary
  CORS, which the engines already satisfy. Cost: not a secure context, so the Serwist SW does not
  register — irrelevant, since the bundle is already local.
- **Two traps, both hit and fixed:**
  1. **`aapt` silently drops asset directories starting with `_`** (default ignore pattern
     `<dir>_*`), so Next's entire `_next/` tree — all JS and CSS — was missing from the APK. The
     page still *rendered*, because the export's prerendered HTML needs no JS, so it looked like a
     styling bug. Fixed with an `androidResources { ignoreAssetsPattern ... }` list minus that entry.
  2. Assets are served with an **explicit MIME map**; Chrome enforces `text/css` on stylesheets
     and silently drops anything else.
- **The APK does not start the engines.** Android blocks apps from exec'ing binaries out of
  `/data/local/tmp`, so llama-server / the split are still adb-launched. Embedding them via JNI
  stays post-demo, as planned.
- **Verified** with `adb reverse` removed and no dev server: app loads from its own assets, no
  console errors, no asset misses; picker shows **all four modes green** (Mock, On-device, Split,
  Remote) from inside the WebView; On-device streamed a real answer ("Earth, Mars, Jupiter");
  thread history persists in IndexedDB across reinstalls.

### Light mode only (NEW, 2026-08-05)

Dark mode was removed rather than defaulted-away: the `prefers-color-scheme: dark` block is gone
from `globals.css` (replaced by `color-scheme: light`), all 15 `dark:` utilities are stripped from
the components, and `themeColor` / manifest colors are `#ffffff`. The Android shell matches —
`QMeshTheme` is `DeviceDefault.Light.NoActionBar` with white status/nav bars, dark bar icons, and
a white Android-12 splash; the launcher icon is a blue mesh on white.

**NOT yet tested:** Split and Remote were confirmed *reachable* (green probe dots) from inside the
APK but a full generation through each was not clicked through end-to-end; production PWA-in-Chrome
behavior (Serwist SW) remains untested and is now moot for the demo; Hexagon NPU through rpc-server
(`--device HTP0` — undocumented for RPC, unverified) — the single remaining L1 unknown.

---

## Next steps (two concurrent tracks)

Strategy: get a complete **CPU** system demo-ready first (Track A) so there is always a
shippable floor, while starting the **NPU** environment work on day 1 (Track B) because its
blockers have the longest lead time. The two tracks converge cheaply — the app talks to engines
over the OpenAI HTTP/SSE boundary, so swapping a CPU engine for an NPU engine on the same port is
a config change, not an app change. **Gates:** A5 is the safety net (never lose it); B3 gates B4;
B1's corp-policy answer determines whether L1 or L2.5 is the NPU ceiling.

### Track A — App + guaranteed demo floor (sequential, low-risk)
1. **Two-device CPU split (L3), no building:** ~~phone MAIN → laptop worker over Wi-Fi~~
   **✅ DONE (2026-08-05)** — S25 MAIN (`-ngl 32`) → laptop `ggml-rpc-server:50052`, real
   Wi-Fi: **84.3 pp / 15.5 tg** vs same-day phone-local 141.3 / 25.5 (≈39% decode penalty,
   ≈1 RTT/token — see FINDINGS §two-device). Worker is WMI-launched via ssh (survives
   session exit; `LOCAL_NETWORK.md` has the exact launch + gotchas), weights cached on the
   laptop (`-c`), firewall rule pre-existed. Split serve-mode (`phone_split.sh serve`) not
   yet wired into the picker.
2. **Phone `all_local` on CPU:** ~~llama-server from the same tarball on `:8082`~~ **✅ DONE
   (2026-08-04)** — running on the S25, ~10 t/s decode, wired into the picker's On-device mode
   (see *all_local* above). NPU swap arrives via Track B. Remaining polish: click through from
   the phone's own browser; auto-launch the server (survives reboot / boot script).
3. **Wire `all_remote` (GenieX on laptop):** already proven (~42 tok/s), no signing — a free
   early *real-NPU* mode that doesn't depend on the split.
4. **Client:** ~~replace `mockModel.ts` with a real OpenAI-compatible SSE streaming adapter +
   a mode picker~~ **✅ DONE (2026-08-04)** — adapter live and verified cross-device (see
   *Client / app plane* above); **mode picker shipped** (`ModePicker.tsx`) — header dropdown for
   mock / on-device / split / remote with a live per-mode reachability dot, modes with no URL show
   "not set up", switching applies to the next message with no remount (adapter dispatches
   per-run). Verified: Remote→"42" / Mock→canned / Remote real, one thread, no errors.
   ~~**Remaining:** phone loopback proxy; thin **WebView APK**~~ **✅ DONE (2026-08-05)** — the
   **QMesh APK** ships the static export inside itself and serves it to its own WebView, so no
   proxy was needed and the dev box is out of the demo path entirely (see *Native APK shell*
   above).
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
6. **Open (found 2026-08-04):** laptop port 8082 is currently open to the **whole Wi-Fi**
   (Public profile), not just the phone. Pre-existing any-port/any-remote Windows Firewall
   inbound rules for `llama-server.exe` (auto-created during earlier split-RPC work) OR-override
   the phone-scoped rule that was added. Acceptable on a trusted demo LAN; before untrusted Wi-Fi,
   disable the broad rules (needs elevation): `Get-NetFirewallRule -DisplayName "llama-server.exe"
   | ? Direction -eq Inbound | Disable-NetFirewallRule`. Also: laptop engine is **not** reachable
   from the Mac dev box under a phone-scoped rule, and won't survive a laptop reboot (launched
   detached, PID-tracked).
