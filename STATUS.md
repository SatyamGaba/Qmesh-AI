# QMesh — Status & Next Steps (live)

**This is the working doc — update it as things change.** Durable design lives in
[`ARCHITECTURE_PLAN.md`](./ARCHITECTURE_PLAN.md); demo-facing capabilities + talking points
in [`docs/FEATURES.md`](./docs/FEATURES.md); this file tracks what's tested, what's next,
and open questions.

**Last updated:** 2026-08-06
**Overall state:** **The two-device RPC split is live and all three demo modes are staged**
(Track A1 done). RTT experiments concluded (FINDINGS §RTT): even at 6.5 ms ping the split
decodes 14 t/s vs ~25 t/s phone-alone — ggml-rpc's multiple round trips per token cost
40–70 ms on every real wireless link, so **at 4B the split is definitively a
capability/privacy story, not a speedup**. **Demo topology: the laptop's 2.4 GHz Mobile
Hotspot** (self-contained, venue-independent; laptop `192.168.137.1`, phone
`192.168.137.2`, phone gets internet through the laptop).

**Track B is now DONE on both devices (2026-08-05/06)** — native-HVX llama.cpp
(b10288) builds and runs on the laptop's **HTP v73** and the phone's **HTP v79**, both
kernel-verified on the NPU. Both L1 mechanism questions are answered **YES**: TESTSIGNING
is permitted here, and HTP registers as an rpc-server device. The Android build needed no
signing at all, and was produced **on this ARM64 laptop via Docker + QEMU** — no x86-64
box required.

The surprise is a *performance* result, not a mechanism one, and it is consistent across
both SoCs: **the NPU wins prefill and loses decode.** Laptop 449/15.0 (NPU) vs 363/33.6
(CPU); phone 895/19.2 (NPU) vs 141/26.1 (CPU) — a 6.4× prefill rout on the phone, but
0.73× decode. Combined with the RTT finding above, **neither the split nor the NPU is a
throughput story at 4B**; the NPU's real case is thermal and power (phone soak: 57 °C max
and ~1 W on NPU vs **102 °C** and 5–8 W on CPU, with CPU prefill throttling 33%).

**Current fallback rung (see ARCHITECTURE_PLAN §5):** **L3 (both-CPU) proven across two
real devices**, and **L2 now also proven** — phone-CPU main + laptop worker on HTP0/NPU,
generating end-to-end at 10.3 t/s decode. L1 (both-NPU) is unblocked but gated on the
phone NPU's sustained-decode crash (`dspqueue_read 0x68`), which needs a restart watchdog.
See [Next steps](#next-steps).

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

### Track B environment audit — laptop side (2026-08-05)

Investigated B1/B2 on the X Elite. **Native HVX still requires a from-source build; no shortcut
exists.** Evidence:

**Hardware/driver side is ready.** `Snapdragon(R) X Elite - X1E80100 - Qualcomm(R) Hexagon(TM)
NPU` present, driver `30.0.219.1000` (oem120.inf), status OK. FastRPC `libcdsprpc.dll` ships in
the DriverStore (`qcnspmcdm8380.inf_arm64_e663a92a933cab52\`) — **not** in System32, so a build
must copy it beside the exe or add that dir to PATH. Adreno X1-85 driver `31.0.148.0` OK and
`C:\Windows\System32\OpenCL.dll` present.

**Upstream ships no Windows Hexagon binary.** Release b10288 has exactly two win-arm64 assets:
`win-cpu-arm64` and `win-opencl-adreno-arm64`. No hexagon/HTP asset — the backend exists only if
you build it (`docs/backend/snapdragon/windows.md`).

**GenieX bundles a Hexagon build, but it is NOT reusable.**
`%LOCALAPPDATA%\GenieX CLI\llama_cpp\` holds `ggml-hexagon.dll`, `libggml-htp-v73/75/79/81.so`
and `libggml-htp.cat` (catalog signed by *Microsoft Windows Hardware Compatibility Publisher*,
valid to 2027-11, so GenieX itself needs no TESTSIGNING). Confirmed native HVX with no QNN:
strings include `hvx-flat`, `hvx-tiled`, `HVX_W_DEQUANT`, `GGML_HEXAGON_USE_HMX`, `libcdsprpc.dll`.
**But `ggml-hexagon.dll` exports only `ggml_backend_hexagon_reg` / `ggml_backend_is_hexagon` — it
does not export `ggml_backend_init`**, which every dynamically-loadable ggml backend must provide
(`ggml-rpc.dll` and `ggml-cpu.dll` both do). It was built as a *statically registered* backend
linked into GenieX's app, so it cannot be dropped into stock llama.cpp at any version. Verified
empirically: b10150 (ggml 0.17.0, exact match to GenieX's ggml) + GenieX's hexagon files →
`GGML_BACKEND_PATH` load fails with `load_backend: failed to find ggml_backend_init`. Mixing with
b10270 (ggml 0.18.1) fails earlier, on ABI mismatch.

**Consequence for open question #1: TESTSIGNING is still load-bearing.** GenieX's catalog is
Microsoft-signed, but a *self-built* `libggml-htp.cat` would be self-signed, so
`bcdedit /set TESTSIGNING ON` (admin + reboot, possibly Secure Boot off) is still required.
Currently **TESTSIGNING = OFF**.

**Build prerequisites missing on this laptop:** Hexagon SDK CE 6.6.0.0 (absent — `C:\Qualcomm`
holds only `AIStack\QAIRT`), Adreno OpenCL SDK 2.3.2 (absent), Hexagon Tools 19.0.07 (ships with
the SDK), Windows SDK 10.0.26100.0 (absent — newest present is 10.0.22621.0), WDK for
`makecert`/`signtool` (absent), `ninja` (absent). **Present:** VS 2022 Community with MSVC
14.43.34808 + Hostarm64, CMake 4.1.0-rc1, Git, 208 GB free, 31.6 GB RAM. Both Qualcomm SDKs are
account-gated downloads.

**B2 (`rpc-server --device HTP0`) remains untestable** until a Hexagon-enabled build exists — it
is gated on B1, not independently verifiable.

**L2.5 status:** official `llama-b10288-bin-win-opencl-adreno-arm64` downloaded to
`%LOCALAPPDATA%\qmesh_npu\adreno\`. Its `ggml-opencl.dll` does export `ggml_backend_init`, but
`--list-devices` returned no devices on first try despite the Adreno driver and OpenCL runtime
being present — needs follow-up before L2.5 counts as a working fallback.

### Track B — native HVX build on the laptop (B1 + B3 DONE, 2026-08-05)

The from-source Hexagon build now exists and runs on the X Elite NPU. This supersedes the
"prerequisites missing" audit directly above.

**Build:** llama.cpp **b10288** from source, preset `arm64-windows-snapdragon-release`
**plus `-DGGML_RPC=ON`**. Build script `QMesh_AI\qmesh_npu\build_hvx.ps1`, 3.5 min,
exit 0. Staged flat at **`QMesh_AI\qmesh_npu\hvx\`**.

> **Location note (moved 2026-08-05):** the whole NPU build tree now lives at
> `QMesh_AI\qmesh_npu\` (5.72 GB — Hexagon SDK, llama.cpp source, four build trees,
> and the runnable `hvx\` package). It was previously in `%LOCALAPPDATA%\qmesh_npu\`;
> older notes and the earlier `adreno\` reference below still use that path.
> **This is inside OneDrive**, unlike the models in `%LOCALAPPDATA%\qmesh_split\models\`,
> which are deliberately kept out of sync. Two consequences: OneDrive will sync ~5.7 GB,
> and if it ever converts files to cloud-only placeholders the build/DSP libs must be
> pinned ("Always keep on this device") or they will fail to load.
>
> **`build-hvx\` will not rebuild in place after the move** — CMake bakes absolute paths
> into `CMakeCache.txt`/`build.ninja`. Re-run `build_hvx.ps1` (it configures a fresh
> tree) rather than `cmake --build` on the moved directory. The `hvx\` runtime package
> is path-independent and was re-verified working from the new location.

> **Two traps that sank the earlier attempt** (`pkg-snapdragon`, same day):
> 1. `HEXAGON_HTP_CERT` was unset, so **no `libggml-htp.cat` was generated**. The CMake
>    only creates the sign-the-catalog target when that var is non-empty
>    (`ggml/src/ggml-hexagon/CMakeLists.txt:87`) — it fails *silently*, producing a
>    complete-looking package whose DSP libs can never load.
> 2. **The preset leaves `GGML_RPC=OFF`**, so no `ggml-rpc-server.exe` is built at all —
>    i.e. the Track B split worker is not in the default Snapdragon package. Must be
>    added explicitly.
>
> Also: `WINDOWS_SDK_BIN` must point at **10.0.26100.0**, not 22621 — `Inf2Cat.exe`
> (x86 subdir) ships only in the newer SDK, and CMake `find_program(... REQUIRED)` on it
> is a hard configure failure.

**Signing chain (resolves open question #1 — TESTSIGNING is permitted here):**
Secure Boot was already **off**; `bcdedit /set TESTSIGNING ON` succeeded and reads back
`testsigning Yes` after reboot. Self-signed `CN=GGML.HTP.v1` imported into **LocalMachine
`Root` + `TrustedPublisher`** (elevated; `install_cert.ps1`). `signtool verify /v /pa
libggml-htp.cat` → *Successfully verified*. **No Microsoft-signed catalog needed** — the
GenieX-reuse dead end (non-exported `ggml_backend_init`) is irrelevant once you build from
source, because `GGML_BACKEND_DL=OFF` statically registers the backend.

**Native HVX confirmed live** (the DSP reports its own hardware):
```
ggml-hex: Hexagon Arch version v73
ggml-hex: HTP0 hwinfo: threads 4, hvx 4, hmx 1, vtcm 8 MB
ggml-hex: HTP0 new session : session-id 0 domain-id 3 handle 0x...
ggml-hex: HTP0 op batching: n-bufs 16 n-tensors 7168 n-ops 1024 vmem 3145728000
```
4 HVX units + 1 HMX + 8 MB VTCM, 3.0 GB session vmem budget. `libcdsprpc.dll` is located
automatically from the DriverStore — no PATH surgery needed (it is still copied into
`hvx\` for portability).

**Measured — Qwen3-4B-Instruct-2507 Q4_0, llama-bench pp128/tg32, r=2, laptop only:**

| Shape | Prefill t/s | Decode t/s |
|---|---:|---:|
| **HTP0 (NPU, native HVX)** | **433.4 ± 31.4** | **12.2 ± 1.3** |
| CPU, same from-source build (`-ngl 0`) | 363.3 ± 14.0 | 33.6 ± 3.4 |
| CPU, b10270 official prebuilt (earlier baseline) | 213.9 | 37.5 |

Qwen2.5-0.5B Q4_0 on HTP0: pp64 **1470.7**, tg16 **53.5**.

**Two conclusions, one of them unwelcome:**
- **Prefill is a real NPU win:** 433 vs 363 t/s over the tuned CPU build (+19%), and +103%
  over the b10270 prebuilt. Prefill was already flagged as the phase Wi-Fi hurts most, so
  this is the useful direction.
- **Decode is a large NPU *loss*: 12.2 vs 33.6 t/s — the NPU is 2.7× slower than the CPU.**
  Chat is decode-bound, so putting the laptop half of the split on HTP would make the demo
  *slower*, not faster. Note also the from-source CPU build beat the old prebuilt on prefill
  by 70% (363 vs 214), so **the L3 CPU floor just got materially better too** — rebuild the
  CPU path from source regardless of what happens with the NPU.

*Caveats before treating the decode number as final:* r=2 with wide variance; the Hexagon
backend is explicitly experimental and completely untuned here — `GGML_HEXAGON_USE_HMX`,
`GGML_HEXAGON_NHVX`, `GGML_HEXAGON_OPBATCH`, `GGML_HEXAGON_NDEV` were all left at defaults;
and **MXFP4 was not tried** (ARCHITECTURE_PLAN §5 flags it as the higher-quality 4-bit
candidate for HTP and it may also be the faster one). Q4_0 at 2.21 GiB fits the 3.0 GB
session budget but not by much.

### Phone (S25 Ultra) native-HVX build — B3 DONE on BOTH devices (2026-08-05)

The Android Hexagon build exists and runs on the phone's **HTP v79**. Built **on the ARM64
Windows laptop** via Docker + QEMU — the `ghcr.io/snapdragon-toolchain/arm64-android:v0.7`
image is `linux/amd64`, but cross-compilation means host arch doesn't affect target validity.
Configure 31 s, full build 724/724 targets, `BUILD_EXIT=0` / `INSTALL_EXIT=0`. **An x86-64
box is NOT required** — that earlier assumption is retired.

Source staged at `%LOCALAPPDATA%\qmesh_android\llama.cpp` (deliberately outside OneDrive);
package pushed to `/data/local/tmp/llama.cpp/` (287.5 MB, bin + lib).

**Confirmed live on-device** — the DSP reports its own hardware:
```
ggml-hex: Hexagon Arch version v79
ggml-hex: HTP0 hwinfo: threads 6, hvx 6, hmx 1, vtcm 8 MB
ggml-hex: HTP0 new session : ... file:///libggml-htp-v79.so ... handle 0xb4000078e6cfaf90
```
Note **6 HVX units vs the laptop v73's 4** — the 8 Elite NPU is the wider part.
Correct generation verified (`llama-completion`, "Earth / Mars / Jupiter", 18.89 t/s).

**Measured — Qwen3-4B Q4_0, pp128/tg32, r=2, all from the SAME b10288 build and flags**
(`-t 6 --cpu-mask 0xfc --cpu-strict 1 --ubatch-size 1024 -fa 1`):

| Phone shape | Prefill t/s | Decode t/s |
|---|---:|---:|
| **HTP0 + `OPPOLL=1`** | **895.6 ± 9.2** | **19.2 ± 0.1** |
| HTP0 (defaults) | 849.8 ± 3.2 | 17.4 ± 0.7 |
| CPU (`-ngl 0`) | 140.7 ± 2.9 | **26.1 ± 0.1** |

**Correction to an earlier claim in this doc.** The "phone CPU ~10 t/s decode" figure
(from the b10270 android prebuilt, untuned flags) is **stale and misleadingly low**. The
from-source build with tuned flags reaches **26.1 t/s** on CPU — 2.5×. Any NPU-vs-CPU
comparison against the old number overstates the NPU by that factor. Same lesson as the
laptop: rebuild the CPU path from source before judging the NPU.

**The laptop's pattern holds on the phone — NPU wins prefill, loses decode:**
- **Prefill is a rout: 895.6 vs 140.7 = 6.4× faster on the NPU** (laptop was only 1.24×).
  This is the single strongest NPU result in the project.
- **Decode still loses: 19.2 vs 26.1 = 0.73×** (laptop was 0.49×). The phone is
  *relatively* better for NPU decode, but it is still a loss, not a win.
- `GGML_HEXAGON_OPPOLL=1` helps here too (+5% prefill, +10% decode, and it tightens
  variance to ±0.1) — smaller than the laptop's +30%/+34%, same direction. Keep it on.

**What this means for the ladder.** "Put it on the NPU" and "make it fast" are still
different goals, on both devices. But the 6.4× prefill win reframes the **hybrid** option
from a consolation prize into the design worth targeting: NPU for prefill, CPU for decode.
That matters most on the phone, which is also where prefill over Wi-Fi hurts the split most.

Android needed **no code signing** — the entire TESTSIGNING/cert/`Inf2Cat`/`.cat` chain is
Windows-only, so the phone build was materially simpler than the laptop one.

### FIRST TRUE TWO-DEVICE SPLIT — L2 live over real Wi-Fi (2026-08-06)

The "still pre-two-device" caveat above is retired. Phone main (b10288, CPU, first 4
layers + sampler, `-ngl 32`) + **laptop worker on HTP0/NPU** (hvx `ggml-rpc-server
-H 192.168.137.1 -p 50052 -d HTP0 -c`) over the hotspot. Weight transfer ~36 s;
worker holds ~1.1 GB. Correct generation end-to-end: **10.31 t/s decode, 4.91 t/s
prefill** — decode survives the network (only ~5 KB/token crosses), prefill is
Wi-Fi-murdered exactly as §3 predicted. This is L2 with an NPU-accelerated worker,
one rung short of L1.

All four app modes are now live simultaneously (mock / on-device phone-NPU /
split / remote laptop-NPU), each with `--alias qwen3-4b@<backend>` driving the
picker badge. Phone-side launches use the b10288 android build at
`/data/local/tmp/llama.cpp/`; `.env.local` wires localhost URLs (resolve on the
phone, where the browser runs).

**Phone NPU stability caveat (2026-08-06 soak):** sustained `tg512`×10 on HTP v79
crashed the engine (`dspqueue_read failed: 0x00000068` → abort) after completing
`pp512`×10 at 1650±455 t/s. Chat-length generations have been reliable. Thermals
are the NPU's strength: 44 °C mean / 57 °C max vs the CPU's sustained 79 °C mean /
**102 °C max** at 5–8 W (SDHMS n=12, mean 8.1 W). CPU sustained pp dropped 33%
(139→93 t/s) — it throttles hard. The CPU sustained-decode number is still
unmeasured (that soak's adb transport was cut by an unrelated adb restart).
Conclusion so far: NPU wins sustainability on physics but needs a crash-restart
watchdog; CPU's burst decode lead likely shrinks under thermal load.

Also: `dumpsys battery` current is only trustworthy while **discharging** — on AC
it clamps to two fixed values (this invalidated one earlier power table). And the
old b10270 CPU rpc-worker keeps getting respawned on `0.0.0.0:50052` (four PIDs
observed; suspect `remote_llm_supervisor`) — corp-Wi-Fi exposure per the ggml-rpc
advisories; unresolved.

### Laptop engine serving on the NPU — verified end-to-end (2026-08-05)

`llama-server` from `qmesh_npu\hvx\` runs the laptop `all_remote`-style engine on HTP0.
Launcher: `qmesh_npu\run_npu_server.ps1` (Qwen3-4B Q4_0, `--device HTP0 -ngl 99`,
`GGML_HEXAGON_OPPOLL=1`, bound to **127.0.0.1** deliberately — see open question #6, the
pre-existing any-port firewall rules would otherwise expose it to the whole Wi-Fi).
Model loads in ~2.6 s, `/health` ok in 4 s, `/completion` returns correct text.

**Device attribution had to be done by measurement, not logs.** *(Superseded 2026-08-06 —
`telemetry.sh` probes / `run_npu_server.ps1 -GgmlProfile` now attribute CPU/NPU/GPU
directly via `GGML_HEXAGON_PROFILE=1` + `-v` per-op evidence, validated on both devices.
Fingerprinting remains the fallback where profiling overhead is unacceptable.)*
`llama-server` installs its
own ggml log callback and swallows the `ggml-hex:` backend lines, so the session/hwinfo
output visible under `llama-bench` never appears — even with `GGML_HEXAGON_VERBOSE=2`.
`--list-devices` also prints nothing (same cosmetic listing bug as the `--device` error
path). Windows exposes no NPU perf counters on this box either. Fingerprinting under
identical conditions settles it:

| Path | decode t/s |
|---|---:|
| `llama-bench --device HTP0` | 15.43 ± 0.36 |
| **`llama-server --device HTP0` (the app)** | **11.9 / 11.7** |
| `llama-bench -ngl 0` (CPU) | 31.77 ± 1.32 |

The server sits with the NPU, ~2.7× off the CPU path — so **yes, the app runs on the NPU**.
The ~24% below raw `llama-bench` is server overhead (HTTP/JSON, sampling, 4 slots, unified
KV), not a different device.

**Correction — the NPU is NOT single-tenant.** An earlier session-open failure
(`error 0x80000406`) was misread as HTP being exclusive; it was actually the working-directory
bug (the DSP skel resolves via CWD). Verified directly: with the server holding HTP0, a second
`llama-bench --device HTP0` opened its own session fine. This matters for the split — a laptop
`rpc-server --device HTP0` worker does **not** lock out other HTP users on the same box.

### Open question #2 — ANSWERED YES: HTP *does* register as an rpc-server device

`ggml-rpc-server.exe --host 127.0.0.1 --port 50052 --device HTP0` starts, stays alive, and
initializes a real HTP0 session. Verified it is not silently ignoring the flag: `--device
BOGUS9` exits with `error: unknown device: BOGUS9`, so accepting `HTP0` is a genuine
device match.

End-to-end loopback split through the HTP worker (Qwen2.5-0.5B Q4_0, `-ngl 99`,
`--rpc 127.0.0.1:50052`) reports backend **`OpenCL,HTP,RPC`** and runs: pp64 **1165.6**,
tg16 **35.45**. So the L1 *mechanism* works — B2 and B4's laptop half are no longer unknowns.

Two doc corrections this turns up:
- **`-d` IS a valid shorthand for `--device`** at b10288 (`-d, --device <dev1,dev2,...>`).
  ARCHITECTURE_PLAN §5 and the notes above say there is no `-d` shorthand — that is stale.
- The `--device` error path prints `available devices:` followed by `No devices found`
  even though HTP0 is accepted. Cosmetic listing bug; do not use it to conclude the NPU
  is absent.

### One-command demo bring-up (NEW, 2026-08-06)

`qmesh_npu\launch_demo.ps1` (also compiled to `launch_demo.exe` via ps2exe — double-click
launch, no execution-policy flags) starts the whole stack idempotently: laptop NPU engine +
RPC worker (hvx/HTP0), both phone servers (`@npu` :8082, `@split` :8081), the QMesh app,
and the telemetry dashboard. Health-checks each piece and only starts what's down;
discovers the wireless-adb port via `adb mdns services`; warns about the rogue
`0.0.0.0:50052` worker (open question #7). Verified: cold-path launch commands are the
2026-08-06 restore recipes; skip paths + re-run all green. `-SplitValidation` instead runs
`split_rpc_validation` (loopback worker on :50053 + `bench_split.ps1` sweep, no
hotspot/phone needed) — verified from the exe, reproducing FINDINGS within ~2%
(211.0/37.0, 121.2/33.5, 82.9/33.1). Two latent `bench_split.ps1` bugs fixed en route
(both only bite non-interactive hosts): PS 5.1 NativeCommandError on llama-bench's first
stderr line under EAP=Stop, and the `±` parse anchor mojibaked by the OEM codepage.

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
1. ~~**Unblock the environment**~~ **✅ DONE (2026-08-05)** — TESTSIGNING permitted and ON,
   Hexagon SDK 6.6.0.0 + Adreno OpenCL SDK 2.3.2 + Windows SDK 26100 installed, self-signed
   cert trusted machine-wide, **native HVX build produced and staged at
   `QMesh_AI\qmesh_npu\hvx\`**. No QAIRT needed, as predicted. Android/Docker toolchain
   for the phone build is the remaining piece of B1.
2. ~~**Verify `--device HTP0` exposes HTP to rpc-server**~~ **✅ DONE — ANSWERED YES**
   (2026-08-05). Mechanism confirmed, flag validated, loopback split through an HTP worker
   runs. This was the last L1 mechanism unknown.
3. **Single-device HTP standalone:** ~~laptop v73~~ **✅ DONE (2026-08-05)** — laptop v73
   measured, see the build section above. **Phone v79 still to do** (Android build via
   `ghcr.io/snapdragon-toolchain/arm64-android` on the x86-64 box, then adb-push).
4. **Both-NPU split (L1) — re-evaluate before building.** The blockers are gone, but the
   laptop measurement says HTP decode is **2.7× slower than CPU decode**, so L1/L2 would
   likely *lose* to L3 on the metric the demo is judged by. Before spending the phone-side
   Android build: (a) retry with MXFP4 and the `GGML_HEXAGON_*` tuning knobs to see if
   decode closes the gap; (b) if it does not, consider the **hybrid** shape — NPU for
   prefill (where it wins +19%) and CPU for decode — or simply keep L3 and spend the time
   on Track A polish. Cross-version bugs #25102/#25876 remain untested.

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

1. ~~Is `TESTSIGNING ON` permitted on this (possibly corp-managed) laptop?~~ **CLOSED
   2026-08-05 — YES.** Secure Boot was already off, `bcdedit` succeeded, reads back
   `testsigning Yes` after reboot, self-signed cert trusted, catalog verifies. L2.5 is no
   longer needed as a signing escape.
2. ~~Does HTP actually register as an rpc-server device (`--device HTP0`)?~~ **CLOSED
   2026-08-05 — YES**, and the flag is genuinely validated (bogus name → `unknown device`).
   Loopback split through an HTP worker runs end-to-end.
3. **(Now the decisive one.)** Is L2 (or L2.5 GPU) an acceptable demo floor if the schedule
   bites, or is both-NPU non-negotiable? **This is no longer just a schedule question — it is
   now a performance question.** Measured laptop HTP decode (12.2 t/s) is 2.7× *worse* than
   laptop CPU decode (33.6 t/s), so "the NPU rung" and "the fast rung" are not the same rung.
   If the demo is judged on tokens/sec, L3-from-source is currently the best-performing
   option; if it is judged on "runs on the NPU", L1 is reachable but slower. **Needs a call.**
3a. Does MXFP4 (or `GGML_HEXAGON_USE_HMX` / `NHVX` / `OPBATCH` tuning) close the HTP decode
   gap? Cheapest high-value experiment left on Track B — it decides question 3.
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
7. **Open (found 2026-08-06):** a b10270 `ggml-rpc-server` keeps being respawned on
   **`0.0.0.0:50052`** — four distinct PIDs observed across the day, surviving `pkill`.
   ggml-rpc has unauthenticated-RCE advisories and this binding is reachable from the
   corporate Wi-Fi, not just the hotspot. Suspect `remote_llm_supervisor`. Unresolved:
   needs an elevated kill *plus* disabling whatever relaunches it.
