# QMesh AI — a private AI across your own devices

QMesh turns the devices you already own into one private AI system. A chat app on
your Android phone runs large language models three ways — **fully on the phone**
(works in airplane mode), **on a laptop** on your local network, or **split across
both devices at once**, with the model's layers physically divided between the
phone and the laptop over Wi-Fi. No cloud, no account, no data leaving your
network — and in split mode, the mesh runs models **too big for either device's
share of the work to reveal, and too big for the phone to hold alone**.

Built for Snapdragon: the phone engine runs on a Snapdragon 8 Elite (Galaxy S25
Ultra) and the laptop side on a Snapdragon X Elite Copilot+ PC — including
[llama.cpp](https://github.com/ggml-org/llama.cpp) built natively for the
X Elite's **Hexagon NPU** (HTP, via the ggml-hexagon HVX backend) — with
llama.cpp's ggml-RPC backend carrying the cross-device split.

## Why

Phones can now run capable 4B-class models, but the moment you want more — a
bigger model, longer context, faster answers — today's answer is "send it to the
cloud." QMesh's answer is "use the laptop in your bag." The devices form a
private, LAN-only mesh:

| Mode | Where the model runs | Network needed | Best for |
|---|---|---|---|
| **On-device** | 100% on the phone | none — airplane mode works | maximum privacy, anywhere |
| **Split** | first layers on the phone, the rest on the laptop, over ggml-RPC | LAN only | models the phone can't hold alone |
| **Remote** | 100% on the laptop | LAN only | fastest responses |

**Auto-privacy** ties the modes together: when enabled, chats run on the fast
Remote engine by default, but the moment a message contains PII (names, emails,
phone numbers, …) the conversation is pinned to a private engine (Split, else
On-device) *before* the request is built — so sensitive text never reaches even
the laptop when a more private engine can serve it.

Everything else is local too: conversations persist in on-phone IndexedDB, the UI
is a self-contained Android app (a WebView shell serving a bundled Next.js
export), and the whole demo runs on the laptop's own Wi-Fi hotspot with zero
internet dependency.

## Team

| Name | Email |
|---|---|
| Satyam Gaba | satyamgb321@gmail.com |
| Pratap Ramachandran | mailpratapr@gmail.com |
| Vishnu Priya Ammina | avishnupriya2206@gmail.com |

## Repository layout

| Path | What |
|---|---|
| [`Qmesh-App/`](Qmesh-App/) | The chat app — Next.js 16 + assistant-ui PWA; all inference goes through one OpenAI-compatible SSE adapter |
| [`Qmesh-Android/`](Qmesh-Android/) | Android shell — single-Activity WebView APK that bundles the app's static export |
| [`release/`](release/) | **Packaged executables per the submission rules**: `QMesh.apk` (Android) and `launch_demo.exe` (Windows one-command demo launcher) |
| [`qmesh_npu/`](qmesh_npu/) | Laptop NPU package — llama.cpp `b10288` built with the native Hexagon HVX backend (`hvx/` runnable binaries incl. `llama-server` and `ggml-rpc-server` on HTP0), build/verify/bench scripts, and the [`launch_demo.ps1`](qmesh_npu/launch_demo.ps1) whole-stack launcher |
| [`scripts/phone_split.sh`](scripts/phone_split.sh) | Drives the phone's engines over adb: on-device server, split MAIN, benchmarks |
| [`split_rpc_validation/`](split_rpc_validation/) | Laptop-side worker/bench/chat scripts + [`FINDINGS.md`](split_rpc_validation/FINDINGS.md) — the full measured-results log |
| [`ARCHITECTURE_PLAN.md`](ARCHITECTURE_PLAN.md) | Durable design: mode map, fallback ladder, risk register |
| [`STATUS.md`](STATUS.md) | Working log — what is tested, with numbers |
| [`docs/FEATURES.md`](docs/FEATURES.md) | Demo-facing feature walkthrough |

## Prerequisites

**Hardware**
- Android phone, arm64 (tested: Galaxy S25 Ultra, Snapdragon 8 Elite, Android 16)
- Windows-on-Snapdragon laptop (tested: Snapdragon X Elite Copilot+ PC) — only
  needed for Split / Remote modes; On-device mode needs the phone alone
- Both devices on the same Wi-Fi network (the laptop's own Mobile Hotspot works
  best — see [Network setup](#network-setup))

**Software**
- `adb` (Android platform-tools) on any dev machine (macOS / Linux / WSL), with
  USB debugging enabled on the phone — used to install the APK and to push/start
  the phone-side engine binaries (the app itself does not need a dev machine at
  runtime)
- llama.cpp **b10270** official prebuilt binaries (no compilation needed):
  - `llama-b10270-bin-android-arm64.tar.gz` for the phone
  - the win-arm64 **CPU** build for the laptop
  - both from <https://github.com/ggml-org/llama.cpp/releases/tag/b10270>
- Model weights (GGUF, Q4_0): **Qwen3-4B-Instruct-2507** (~2.2 GB) — small
  enough that every mode, phone included, can serve it. Download any Q4_0 GGUF of
  this model from Hugging Face and name it `qwen3-4b-instruct-2507-q4_0.gguf`.
  Optionally also a larger split/remote-only model (e.g. Qwen3-30B-A3B Q4_0).

## Setup from scratch

### 1. Install the app on the phone

```bash
adb install release/QMesh.apk
```

(Or sideload the APK any other way. To rebuild it yourself, see
[Building from source](#building-from-source).)

### 2. On-device mode — phone only, fully offline

Push the phone engine + model once:

```bash
# extract the android-arm64 llama.cpp tarball locally, then:
adb shell mkdir -p /data/local/tmp/llama
adb push <extracted-dir>/. /data/local/tmp/llama/
adb shell chmod +x /data/local/tmp/llama/llama-server /data/local/tmp/llama/llama-bench
adb push qwen3-4b-instruct-2507-q4_0.gguf /data/local/tmp/llama/
```

Start it (health-checked, idempotent):

```bash
./scripts/phone_split.sh serve-local
```

Open the **QMesh** app: the *On-device* mode dot turns green. This mode keeps
working with Wi-Fi and mobile data off.

### 3. Remote mode — laptop engine

On the laptop, extract the win-arm64 build (e.g. into
`split_rpc_validation\bin`), put the same GGUF somewhere local, then:

```powershell
.\bin\llama-server.exe -m <path-to>\qwen3-4b-instruct-2507-q4_0.gguf `
  --host 0.0.0.0 --port 8082 --alias qwen3-4b -c 4096 `
  --sse-ping-interval 15 --cors-origins * --no-cors-credentials

# allow the phone through the firewall (elevated PowerShell):
New-NetFirewallRule -DisplayName "qmesh-remote" -Direction Inbound `
  -Protocol TCP -LocalPort 8082 -RemoteAddress <phone-ip> -Action Allow
```

In the app: **Settings → Remote → type the laptop's IP** (the field normalizes
it to `http://<ip>:8082/v1`) → *Test* → Save. The *Remote* dot turns green.

### 4. Split mode — one model across both devices

On the laptop, start the RPC worker (`-Cache` is important — it stores the
offloaded weights on disk so only the *first* load streams them over Wi-Fi):

```powershell
cd split_rpc_validation
.\start_worker.ps1 -BindHost 0.0.0.0 -Cache -Threads 10

# firewall for the worker port (elevated):
New-NetFirewallRule -DisplayName "qmesh-rpc-worker" -Direction Inbound `
  -Protocol TCP -LocalPort 50052 -RemoteAddress <phone-ip> -Action Allow
```

From the dev machine, verify reachability and launch the split MAIN on the
phone (first 4 of 36 layers stay on the phone, the remaining 32 run on the
laptop):

```bash
./scripts/phone_split.sh preflight <laptop-ip>
```

```bash
./scripts/phone_split.sh serve <laptop-ip>
```

The *Split* dot turns green. First launch pays a one-time weight transfer;
afterwards the worker's disk cache makes reloads take ~40 s.

### One-command bring-up (Windows)

Once the one-time pushes above are done, the whole stack starts with a single
command on the laptop:

```powershell
.\release\launch_demo.exe        # or: powershell -File qmesh_npu\launch_demo.ps1
```

It health-checks and starts, in order: the laptop engine (Hexagon NPU when the
`qmesh_npu\hvx` build is present), the RPC split worker, the phone's on-device
and split servers (over adb), the QMesh app on the phone, and a live telemetry
dashboard. It is idempotent — re-running only starts what is missing — and it
verifies prerequisites (hotspot, adb, models) rather than failing silently.
Rebuild the EXE from source with `qmesh_npu\build_launch_demo.ps1`.

### Network setup

Any shared LAN works, but the measured-best topology is the **laptop's Mobile
Hotspot pinned to 2.4 GHz** (Windows Settings → Network → Mobile hotspot): it is
self-contained, avoids venue-Wi-Fi congestion and inter-AP backhaul latency, and
keeps the mesh literally private. Details and measurements in
[`FINDINGS.md`](split_rpc_validation/FINDINGS.md).

## Usage

- **Pick a mode** from the header dropdown. Each mode shows a live reachability
  dot (probed when the menu opens). Switching applies to your next message —
  mid-conversation switches keep the full history.
- **Settings** (gear icon): engine addresses, model selection, and the
  **Auto-privacy** toggle. Addresses accept a bare IP and normalize themselves;
  overrides live in localStorage so a new network never needs a rebuild.
- **Models**: Qwen3-4B runs in every mode. Larger models are offered only on the
  modes that can hold them — the picker greys out a mode that can't serve the
  selected model rather than silently answering from the wrong engine.
- **Auto-privacy**: toggle on in Settings. Chats then run on Remote for speed,
  but any message containing PII pins that conversation to Split/On-device
  before the request leaves the app. If no private engine is usable, the send is
  refused rather than leaked.
- **Offline demo**: select On-device, enable airplane mode, chat. History
  persists in IndexedDB across app restarts and reinstalls.

## Testing the setup

- Phone engine: `./scripts/phone_split.sh logs-local` (server log) or
  `adb shell curl -s http://127.0.0.1:8082/health` → `{"status":"ok"}`
- Phone→laptop path: `./scripts/phone_split.sh preflight <laptop-ip>` checks
  ping + worker port and diagnoses AP client isolation / firewall issues
- Benchmarks (the numbers in `FINDINGS.md`):
  `./scripts/phone_split.sh bench-local` (phone alone) and
  `./scripts/phone_split.sh bench <laptop-ip>` (through the split);
  `split_rpc_validation\bench_split.ps1` for laptop-side shapes
- Any engine, from anything on the LAN: `GET http://<host>:<port>/v1/models`

## Measured performance (highlights)

Full methodology and tables: [`split_rpc_validation/FINDINGS.md`](split_rpc_validation/FINDINGS.md).
Qwen3-4B-Instruct Q4_0, llama-bench pp128/tg32:

| Shape | Prefill t/s | Decode t/s |
|---|---:|---:|
| Phone alone (S25 Ultra, CPU) | 141.3 | 25.5 |
| Split — phone + laptop over Wi-Fi | 84.3 | 15.5 |
| Laptop alone (X Elite, CPU) | 213.9 | 37.5 |
| Laptop, Hexagon NPU (HTP0, `GGML_HEXAGON_OPPOLL=1`)\* | 449 | 15.0 |

\* NPU numbers measured on battery (directional): the NPU dominates prefill
(~449 vs ~363 t/s CPU same-session) while CPU wins decode — details and the
HMX/OPPOLL tuning story in [`qmesh_npu/README.md`](qmesh_npu/README.md).

At 4B the split trades speed for capability and privacy (~1 network round-trip
per token); its purpose is serving models the phone cannot hold at all, with
the phone still owning tokenization, sampling, and the first layers.

## Notes

- **The app never talks to the internet.** All engines are OpenAI-compatible
  llama.cpp servers on `localhost` or the LAN; the adapter
  ([`Qmesh-App/src/lib/openaiModel.ts`](Qmesh-App/src/lib/openaiModel.ts)) is
  the only inference seam.
- **Engine lifecycle**: Android forbids apps from exec'ing pushed binaries, so
  the phone-side engines are started via `adb` (`phone_split.sh`), not by the
  APK. Embedding the engine in the APK via JNI is the planned next step.
- **Security**: ggml-RPC is unauthenticated — bind the worker only to a trusted
  LAN and scope firewall rules to the phone's IP (the setup commands above do).
- **Known quirks** we hit and documented: aapt silently drops `_`-prefixed asset
  dirs (Next's `_next/`!); llama-bench silently falls back to CPU-only when the
  worker is unreachable; one llama-server per worker, ever. War stories in
  [`STATUS.md`](STATUS.md) and [`FINDINGS.md`](split_rpc_validation/FINDINGS.md).

## Building from source

APK (needs JDK 17 + Android SDK; on macOS: `brew install openjdk@17 --cask android-commandlinetools`):

```bash
cd Qmesh-Android && ./build-apk.sh
```

This exports the Next app statically (`QMESH_EXPORT=1`), stages it into the
APK's assets, and runs Gradle. Web app alone: `cd Qmesh-App && npm install &&
npm run dev`.

## References

- [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT) — inference engine +
  ggml-RPC layer-split backend, official `b10270` prebuilts
- [Qwen3](https://huggingface.co/Qwen) — model family (Apache-2.0)
- [assistant-ui](https://www.assistant-ui.com/), [Dexie.js](https://dexie.org/),
  [Serwist](https://serwist.pages.dev/), [Next.js](https://nextjs.org/),
  [Tailwind CSS](https://tailwindcss.com/) — app stack

## License

[MIT](LICENSE) — © 2026 QMesh Team.
