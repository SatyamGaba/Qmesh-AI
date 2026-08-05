# QMesh Split Inference — Architecture

**Scope:** hackathon prototype (not maintained long-term).
**Devices:** Samsung S25 Ultra (Snapdragon 8 Elite SM8750, Hexagon HTP v79) + Snapdragon X Elite laptop (X1E80100, Hexagon HTP v73, 45 TOPS, 31.6 GB)
**Model:** Qwen3-4B-Instruct-2507 (36 dense layers, GQA 32/8, hidden 2560) — GenieX W4A16 for laptop `all_remote`; llama.cpp GGUF Q4_0 (MXFP4 a higher-quality candidate) for phone `all_local` + `split`

> **This file is the durable design.** Live status, test results, next steps, and open
> questions live in [`STATUS.md`](./STATUS.md).

---

## 1. Goal

**Privacy.** Prompts and generated text never leave hardware the user owns, in any
mode. "Remote" always means *the user's laptop*, never a cloud. The split mode is
the demonstration centerpiece: one LLM executing across two personal Snapdragon
devices. Split does not add privacy *between* the two devices (both are trusted);
the claim is against everything outside them.

Accepted trade-off: split-4B is slower than laptop-alone (~42 tok/s GenieX). The
point is private distributed inference, not speedup. Speedup would require a model
too big for one device (8B+) or pipelined speculative decoding — both out of scope
for now.

## 2. Decisions (from the engineering interview)

| Decision | Choice | Why |
|---|---|---|
| Split style | True layer split (pipeline) | The literal goal; speculative-decoding split rejected |
| Model | Qwen3-4B-Instruct-2507 | Proven on laptop NPU via GenieX; same family in GGUF Q4_0 (Hexagon-compatible quant) |
| Main host | **Phone** | Tokenizer, sampler, chat template, API surface on phone; laptop is a subordinate worker |
| Engines | **GenieX for all_remote** (laptop NPU); **llama.cpp for all_local + split** (phone) | GenieX has no public mid-layer activation API (can't split) and no Android server (can't serve all_local on the phone); llama.cpp Hexagon+RPC splits with zero model surgery and also serves the phone's whole-model mode |
| Client | **Reuse the existing PWA** (Next.js + assistant-ui), wrapped in a thin **Android WebView APK** at `http://localhost:PORT` | assistant-ui is React-DOM (RN would be a full UI rewrite); a WebView over loopback keeps service-worker/offline/streaming working and dodges HTTPS→LAN-IP mixed-content blocking |
| API surface | **Three engine ports behind one phone loopback proxy** | Browser sees a single same-origin `localhost` origin (secure context, no CORS/mixed-content); proxy fans out to the 3 engines |
| Network | Same LAN, direct IP | Reachable if AP has no client isolation (pre-flight ping); pin IPs with a DHCP reservation |
| Deliverables | **Android APK** (WebView + on-phone engines) **+ Windows EXE** (laptop supervisor + engines) | Two shippable artifacts: an installable `.apk` for the S25 and a packaged `.exe` for the X Elite laptop |
| Timeline | Few days (hackathon) | Drives the fallback ladder (§4): ship the highest working rung; NPU is the first-class target, CPU the low-risk bootstrap |

## 3. System architecture

```
ANDROID (S25 Ultra)                              WINDOWS (X Elite laptop)
┌────────────────────────────────┐              ┌──────────────────────────────────┐
│ APK = WebView -> localhost:PORT │              │ Supervisor  (FastAPI :8765, EXE) │
│  loads the PWA (assistant-ui)   │   control    │  · engine lifecycle + health     │
│  mode picker -> /local /split   │ ────────────►│  · pairing / status              │
│                     /remote     │              │                                  │
│ LOOPBACK PROXY (:PORT)          │              │ ENGINES (one at a time):         │
│  /local  -> :8082 (llama phone) │              │  A) GenieX serve :18181  (NPU)   │
│  /split  -> :8081 (llama main)  │              │     = all_remote mode            │
│  /remote -> laptop-ip:18181     │ HTTP + SSE   │                                  │
│                                 │ ────────────►│  B) ggml-rpc-server :50052       │
│ ENGINES (Termux/adb for demo):  │  ggml-rpc/   │     split WORKER: last ngl layers│
│  llama-server :8082  all_local  │  TCP         │     (--device CPU today,         │
│  llama-server :8081  split MAIN │◄────────────►│      HTP0 at L1)                 │
│    + --rpc laptop:50052         │ ~5-10KB/tok  │                                  │
└────────────────────────────────┘              └──────────────────────────────────┘
```

**Dev-control topology (current bring-up).** Three nodes on one Wi-Fi LAN (IPs and
link measurements live in `LOCAL_NETWORK.md`, gitignored): the **Mac dev box** drives
the **phone** over wireless adb (app + split MAIN run on the phone) and reaches the
**laptop** over ssh (`qc_de@<laptop-ip>`, key auth) to run the RPC worker
(`QMesh_AI\split_rpc_validation\` on the laptop). The **phone and laptop also reach
each other directly** (AP client isolation off, verified phone→laptop) — that direct
link carries both demo planes: chat HTTP/SSE and the ggml-rpc split. The Mac is
control-plane only; no inference traffic transits it.

**Client & proxy.** The browser only ever talks to one same-origin loopback
endpoint (`http://localhost:PORT`), a secure context — so the service worker,
offline cache, and SSE streaming all work, and there is no HTTPS→LAN-IP
mixed-content block and no CORS. The phone-side loopback proxy serves the PWA and
reverse-proxies the three modes; the only cross-LAN hops (`/remote`, and the
`/split` worker leg) happen server-side in the proxy, not in the browser. The
WebView needs `android:usesCleartextTraffic="true"` (or a `network-security-config`
scoping `localhost`) because Android blocks cleartext at `targetSdk ≥ 28`.

**Mode map (all OpenAI-compatible chat surfaces; browser hits the proxy path, proxy forwards to the engine):**

| Mode | Proxy path (browser) | Engine (behind proxy) | Privacy tier |
|---|---|---|---|
| all_local | `localhost:PORT/local` | llama.cpp on phone (CPU now → Hexagon HTP v79 at L1) | radio can be off |
| split | `localhost:PORT/split` | llama-server (phone main) + rpc-server (laptop worker) | LAN only |
| all_remote | `localhost:PORT/remote` | GenieX serve on laptop NPU (`<laptop-ip>:18181`) | LAN only |

**Split-mode layer placement** (validated semantics): llama.cpp offloads the
*last* `n_gpu_layers` layers to the worker; the first `36 − ngl` stay on the phone
with the embedding, tokenizer, and sampler. The default split is proportional to
each device's *free memory*, so **pin the layout explicitly with `--tensor-split`**
(or size worker memory) to land the intended layers on the laptop. Per token,
activations cross the network exactly twice (phone→laptop hidden state ~5 KB fp16,
= hidden 2560 × 2 B; laptop→phone logits path internal to llama.cpp). **Do not**
model the phone as a second RPC worker: workers never talk to each other, the main
orchestrates every hop — measured +4 crossings and −2.5 t/s even on loopback.

**KV cache** partitions with the layers — each device keeps the KV cache for the
layers it holds, resident on-device across all tokens (never sent over the wire; only
the ~5 KB/token boundary activation crosses). This is what keeps decode viable — the
per-worker compute buffers (331/323 MiB, see `STATUS.md`) already include it on CPU.
On-NPU KV placement (HTP-resident vs CPU fallback for the attention path) is an L1
unknown to confirm during single-device HTP validation. Distinct from the worker `-c`
**weight** cache (load-time weight re-transfer), which is a separate thing.

**Transport:**
- Chat plane: HTTP + SSE, OpenAI-compatible (ecosystem gravity: GenieX, supervisor, every client).
  Keep `--sse-ping-interval 15–30` so mobile radio/Wi-Fi power-save doesn't stall an idle stream.
- Split plane: ggml-rpc's own fixed binary TCP protocol (not swappable — the only alternate
  transport is RDMA, same protocol; Cap'n Proto/gRPC/WebRTC evaluated and rejected — at 5 KB/token
  serialization is microseconds; WebRTC solves NAT traversal we don't have).
- Security now (demo): trusted LAN. **ggml-rpc is not just plaintext/unauthenticated — it has
  active unauthenticated-RCE advisories (GHSA-j8rj-fmpv-wcxw 2026, -wcr5-566p-9cwj, -5vm9-p64x-gqw9);
  its own README says "never run on an open network."** Bind the worker to the LAN and add a Windows
  Firewall inbound rule scoped to the phone's IP (defense-in-depth over a plaintext protocol, not a
  security boundary); use a DHCP reservation so the rule survives lease changes. WireGuard mesh is a
  known-good post-demo option but out of scope for the hackathon.

## 4. Fallback ladder (demo insurance — ship the highest working rung)

NPU is the first-class target; CPU is the low-risk bootstrap that gets the *cross-device
pipe* working before any NPU building. Build the pipe first on CPU, then swap the compute
backend underneath the same RPC protocol — the wire protocol and scripts don't change.

- **L1 (goal, NPU):** phone layers on S25 HTP v79 **+** laptop layers on X Elite HTP v73.
  Highest-risk rung (cross-HTP-version split has open upstream bugs, §5) — attempt only after
  each device is validated single-device on its NPU.
- **L2 (NPU worker):** phone layers on CPU, laptop worker on HTP. A real cross-device split,
  laptop half NPU-accelerated. Lower build risk (only the laptop needs the Hexagon build).
- **L2.5 (GPU option):** either half on the Adreno **OpenCL** backend instead of Hexagon —
  no code signing required on Windows, a useful middle rung if the HTP signing/build bites.
- **L3 (CPU, works today):** both halves CPU, zero additional building — the bootstrap rung
  and the guaranteed demo floor.

Start `--tensor-split` near 40/60 phone/laptop; tune by measurement (phone throttles first).

## 5. Key engineering facts (learned, load-bearing)

- **GenieX is Qualcomm's product** (community Genie), not ours. Its public API is
  token-in/token-out (`/v1/chat/completions`, `/v1/models`) with no mid-layer
  activation access → it can never serve the split path. Its OpenAI `serve` mode is
  **Windows/Linux only — there is no Android server**, so GenieX cannot host the
  phone's `all_local` mode; llama.cpp does.
- llama.cpp Hexagon backend (**experimental**): Android + Windows-on-Snapdragon;
  supported quants F32/F16/Q4_0/Q4_1/Q8_0/IQ4_NL/MXFP4 (no K-quants — the legacy-Q4_0
  constraint is real, but **MXFP4 is a higher-quality 4-bit alternative worth testing**).
  Compute budget is **~2 GB per HTP session; a <4B model fits one session per NPU**, so a
  two-way split is optional for capacity — it's the demo centerpiece, not a memory necessity.
  Dispatch is *batched* over FastRPC (not one call/op); expect it slower than a fully
  compiled pipeline, but the "~230 calls/token, slower than Genie" figure is unsubstantiated —
  don't quote it. On Windows the HTP ops libs must be in a signed `.cat` → self-build needs
  `TESTSIGNING ON` + self-signed cert (Hexagon SDK 6.6.0.0 + Adreno OpenCL 2.3.2 + WDK
  10.0.26100.0; native HVX, **no QAIRT/QNN required**). Android build via the Docker
  toolchain image (`ghcr.io/snapdragon-toolchain/arm64-android`); no prebuilt Hexagon tarball.
- Backends load as DLLs/.so; rpc-server selects devices via `--device` (long form; there is
  **no `-d` shorthand**, and `--device HTP0` for RPC is undocumented — verify HTP registers as an
  RPC device before assuming the NPU split works). Add `-c` on the worker to cache weights and
  cut load-time re-transfer.
- **Why not QNN/QAIRT for the split?** There is no merged QNN backend in llama.cpp — only a
  stalled draft fork (chraac #12063, unmerged since 2025). QNN/QAIRT graph-compiles subgraphs
  (the same sealed-graph shape that stops GenieX splitting), the wrong structure for per-layer
  RPC offload. The official **native `ggml-hexagon`** backend registers each HTP as a normal
  ggml device (HTP0–HTP4, "behaves like a GPU" for `-ngl`), so `rpc-server --device HTP0` can
  offload layers to it — and it supports both v79 and v73 today. The installed QAIRT 2.32.6
  feeds the QNN/Genie path only; it is **irrelevant to ggml-hexagon** (which needs the Hexagon SDK).
- **Cross-HTP-version split is high-risk:** our exact topology (phone v79 + laptop v73,
  multi-device split) matches open 2026 llama.cpp defects (#25102 WoS v73 split garbage,
  #24201/#25876 v79/v81). Validate single-device HTP on each device *before* the both-NPU split.
- Phone carries two model copies (llama.cpp GGUF Q4_0/MXFP4 ~2.4 GiB for local+split; a
  W4A16 copy is only needed if the phone ever runs GenieX, which it can't today). Split-mode
  outputs differ from the laptop GenieX mode (different quantization) — generally small, but
  can compound over long generations; acceptable for the demo.
- Tooling quirks: `-ts` separator is `/` in llama-bench, `,` in llama-cli; b10270
  llama-cli chat UI loops on closed stdin (use `-st` in scripts); latest GitHub release
  can be mid-upload — take the previous tag.

## 6. References

- llama.cpp Snapdragon/Hexagon backend: `docs/backend/snapdragon/README.md`, `windows.md`, `developer.md` (ggml-org/llama.cpp) — quant set, session budget, signing/SDKs
- llama.cpp RPC: `tools/rpc/README.md` — `--device`/`-c`/`--tensor-split`; **security advisories** GHSA-j8rj-fmpv-wcxw, -wcr5-566p-9cwj, -5vm9-p64x-gqw9
- Validation project + measured logs: `QMesh_AI\split_rpc_validation\` (README.md, FINDINGS.md)
- GenieX (Qualcomm community Genie): `geniex.aihub.qualcomm.com` — `serve` is Windows/Linux only, Android via SDK
- Qualcomm Genie multi-binary LLM bundles: qualcomm/ai-hub-apps `tutorials/llm_on_genie`; Qwen3-4B precompiled on AI Hub
- assistant-ui is React-DOM (`@assistant-ui/react`) → WebView-wrap the PWA, not React Native (full rewrite)
- Research context: PipeEdge (heterogeneous layer partitioning), FlowSpec / SpecPipe
  (speculative decoding to fill 2-stage pipeline idle time), prima.cpp / exo (home-cluster
  distributed inference; none support Hexagon — this project would be first)
```
