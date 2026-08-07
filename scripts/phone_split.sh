#!/usr/bin/env bash
# =============================================================================
#  phone_split.sh — drive the S25 (MAIN host) for the two-device RPC split (A1)
# =============================================================================
# Runs on the DEV BOX (Mac/WSL/Linux) and drives the phone over adb. The phone
# is the MAIN host: it holds the first (36 - NGL) layers, the tokenizer, the
# sampler and the chat template, and offloads the LAST $NGL layers to the
# laptop's ggml-rpc-server.
#
#   laptop first:  .\start_worker.ps1 -BindHost 0.0.0.0 -Cache -Threads 10
#   then here:     ./scripts/phone_split.sh preflight 10.73.51.58
#                  ./scripts/phone_split.sh serve     10.73.51.58
#                  ./scripts/phone_split.sh bench     10.73.51.58
#
# Layer placement: llama.cpp offloads the LAST -ngl layers. Qwen3-4B has 36,
# so NGL=32 leaves the first 4 on the phone — the deployment shape validated
# as config 1 in split_rpc_validation/FINDINGS.md.
#
# Env overrides: LLAMA_DIR MODEL PORT NGL THREADS CTX WORKER_PORT SERIAL
set -euo pipefail

LLAMA_DIR=${LLAMA_DIR:-/data/local/tmp/llama}
MODEL=${MODEL:-qwen3-4b-instruct-2507-q4_0.gguf}
PORT=${PORT:-8081}            # split-mode llama-server (all_local uses 8082)
NGL=${NGL:-32}                # layers pushed to the laptop worker
THREADS=${THREADS:-6}         # decode peaks at 6 on SM8750 (8 is slower)
CTX=${CTX:-4096}
WORKER_PORT=${WORKER_PORT:-50052}
LOCAL_PORT=${LOCAL_PORT:-8082}  # on-device engine — the app's "On-device" mode
NPU_DIR=${NPU_DIR:-/data/local/tmp/llama.cpp}  # Hexagon build (bin/ + lib/)
LOG=split.log
LOCAL_LOG=/data/local/tmp/server_8082.log

ADB=(adb)
[[ -n "${SERIAL:-}" ]] && ADB=(adb -s "$SERIAL")

die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m[phone]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }

require_device() {
  local n
  n=$("${ADB[@]}" devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')
  [[ "$n" == "1" ]] || die "expected exactly 1 authorized adb device, found $n. Run: adb devices -l (set SERIAL= to disambiguate)"
  "${ADB[@]}" shell "[ -x $LLAMA_DIR/llama-server ]" \
    || die "$LLAMA_DIR/llama-server missing on the phone — push the b10270 android-arm64 tarball first"
  "${ADB[@]}" shell "[ -f $LLAMA_DIR/$MODEL ]" \
    || die "$LLAMA_DIR/$MODEL missing on the phone"
}

# L3 reachability phone -> laptop. This is the AP client-isolation check the
# plan calls for: a laptop->phone ping does NOT prove this direction.
preflight() {
  local ip=$1
  require_device
  info "ping $ip from the phone (rules out Wi-Fi AP/client isolation)..."
  "${ADB[@]}" shell "ping -c 3 -W 2 $ip" || die "phone cannot reach $ip — AP client isolation, wrong subnet, or laptop asleep"
  info "checking tcp $ip:$WORKER_PORT ..."
  if "${ADB[@]}" shell "command -v nc >/dev/null 2>&1"; then
    if "${ADB[@]}" shell "nc -z -w 3 $ip $WORKER_PORT" 2>/dev/null; then
      info "worker port OPEN"
    else
      warn "port $WORKER_PORT not reachable — is start_worker.ps1 running with -BindHost 0.0.0.0, and does the Windows Firewall rule allow the phone's IP?"
    fi
  else
    warn "no nc on the phone — port check skipped (serve will surface it)"
  fi
}

# Poll /health ON THE PHONE rather than through `adb forward`. That is the exact
# path the app's WebView takes, so a pass here means the app can reach it — a
# forwarded check would still pass with the forward armed and the app broken.
health_wait() {
  local port=$1 tries=$2
  for _ in $(seq 1 "$tries"); do
    if "${ADB[@]}" shell "curl -fsS --max-time 2 http://127.0.0.1:$port/health >/dev/null 2>&1 && echo ok" 2>/dev/null | grep -q ok; then
      return 0
    fi
    sleep 2
  done
  return 1
}

serve() {
  local ip=$1
  preflight "$ip"
  # Port-scoped: the old blanket `stop` here killed the on-device engine too, so
  # starting Split silently broke On-device.
  stop_port "$PORT" >/dev/null 2>&1 || true
  info "starting llama-server: MAIN on phone, last $NGL/36 layers -> $ip:$WORKER_PORT"
  warn "first load streams ~1.9 GiB of weights to the worker over Wi-Fi; with -Cache on the worker only this first run pays it"
  "${ADB[@]}" shell "cd $LLAMA_DIR && LD_LIBRARY_PATH=. nohup ./llama-server \
      -m $MODEL --host 127.0.0.1 --port $PORT --alias qwen3-4b \
      -c $CTX -t $THREADS --rpc $ip:$WORKER_PORT -ngl $NGL \
      --sse-ping-interval 15 </dev/null >$LOG 2>&1 & echo started"
  info "waiting for /health (weight transfer can take minutes on the first run)..."
  "${ADB[@]}" forward "tcp:$PORT" "tcp:$PORT" >/dev/null
  for _ in $(seq 1 180); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
      info "UP — http://127.0.0.1:$PORT (adb-forwarded; on the phone itself it is localhost:$PORT)"
      info "set NEXT_PUBLIC_ENGINE_SPLIT_URL=http://localhost:$PORT/v1 to light up Split in the picker"
      return 0
    fi
    sleep 2
  done
  warn "no /health after 6 min — dumping the log"
  logs
  return 1
}

# The engine behind the app's "On-device" mode, and the all_local reference for
# the benchmark. This one must stand up with nothing else alive — no laptop, no
# worker, no Wi-Fi — so it takes no IP argument and never touches the network.
#
# Prefers the Hexagon NPU build in $NPU_DIR (weights stay on the HTP, so
# --load-mode none and -ngl 99); falls back to the CPU build in $LLAMA_DIR.
launch_local() {
  if "${ADB[@]}" shell "[ -x $NPU_DIR/bin/llama-server ]" 2>/dev/null; then
    info "launching the NPU build (Hexagon HTP0) on :$LOCAL_PORT"
    "${ADB[@]}" shell "cd $NPU_DIR && LD_LIBRARY_PATH=lib ADSP_LIBRARY_PATH=lib GGML_HEXAGON_OPPOLL=1 \
        nohup ./bin/llama-server --device HTP0 -ngl 99 --load-mode none \
        -m $LLAMA_DIR/$MODEL --host 127.0.0.1 --port $LOCAL_PORT --alias qwen3-4b \
        -c $CTX -t $THREADS --sse-ping-interval 15 \
        --cors-origins '*' --no-cors-credentials \
        </dev/null >$LOCAL_LOG 2>&1 & echo started"
  else
    warn "no NPU build at $NPU_DIR — falling back to the CPU build in $LLAMA_DIR"
    "${ADB[@]}" shell "cd $LLAMA_DIR && LD_LIBRARY_PATH=. nohup ./llama-server \
        -m $MODEL --host 127.0.0.1 --port $LOCAL_PORT --alias qwen3-4b \
        -c $CTX -t $THREADS --sse-ping-interval 15 \
        --cors-origins '*' --no-cors-credentials \
        </dev/null >$LOCAL_LOG 2>&1 & echo started"
  fi
}

serve_local() {
  require_device

  # Already answering? Leave it be — a restart costs a full model reload.
  if health_wait "$LOCAL_PORT" 1; then
    info "on-device engine already UP on :$LOCAL_PORT — leaving it alone"
    "${ADB[@]}" forward "tcp:$LOCAL_PORT" "tcp:$LOCAL_PORT" >/dev/null 2>&1 || true
    return 0
  fi

  # Retry once: a cold model load can lose the race with a stale port binding,
  # and the old version reported success without ever checking.
  local attempt
  for attempt in 1 2; do
    # On the retry, clear a half-dead process still holding the port — otherwise
    # the relaunch just fails to bind the same way.
    [[ $attempt -eq 2 ]] && stop_port "$LOCAL_PORT"
    launch_local
    info "waiting for /health on the phone (cold model load, attempt $attempt/2)..."
    if health_wait "$LOCAL_PORT" 45; then
      info "UP — on the phone this is localhost:$LOCAL_PORT (what the app uses)"
      "${ADB[@]}" forward "tcp:$LOCAL_PORT" "tcp:$LOCAL_PORT" >/dev/null 2>&1 || true
      info "forwarded :$LOCAL_PORT for dev-box access (the app does not need this)"
      return 0
    fi
    warn "no /health after 90s on attempt $attempt"
  done

  warn "on-device engine did not come up — last 40 lines of $LOCAL_LOG:"
  "${ADB[@]}" shell "tail -n 40 $LOCAL_LOG" || true
  return 1
}

# The numbers that go into FINDINGS.md — compare against the loopback table.
bench() {
  local ip=$1
  preflight "$ip"
  info "llama-bench pp128/tg32 through the split (-ngl $NGL) — this also pays the weight transfer"
  "${ADB[@]}" shell "cd $LLAMA_DIR && LD_LIBRARY_PATH=. ./llama-bench \
      -m $MODEL -p 128 -n 32 -r 2 -t $THREADS --rpc $ip:$WORKER_PORT -ngl $NGL"
}

bench_local() {
  require_device
  info "llama-bench pp128/tg32 all-local on the phone (baseline, no RPC)"
  "${ADB[@]}" shell "cd $LLAMA_DIR && LD_LIBRARY_PATH=. ./llama-bench \
      -m $MODEL -p 128 -n 32 -r 2 -t $THREADS -ngl 0"
}

# Kill only the server bound to one port. Both launches carry `--port <n>` on
# their command line, so the pattern discriminates them.
#
# `[l]lama-server` is deliberate: with a plain `llama-server` the pattern also
# matches the argv of the `sh -c` wrapper adb runs it in, so pkill kills its own
# shell — which returns a signal status and, under `set -e`, aborts the script.
# The bracket makes the regex still match "llama-server" while the wrapper's own
# literal "[l]lama-server" does not match it.
stop_port() {
  local port=$1
  info "stopping llama-server on :$port (other ports left running)"
  "${ADB[@]}" shell "pkill -f '[l]lama-server.*--port $port'; true"
}

# `stop` with no argument still stops everything — that is an explicit request.
# Automatic callers must use stop_port so they cannot take On-device down.
stop() {
  local port=${1:-}
  if [[ -n "$port" ]]; then stop_port "$port"; return; fi
  info "stopping ALL llama-server processes (including on-device :$LOCAL_PORT)"
  "${ADB[@]}" shell "pkill -f '[l]lama-server'; true"
}

logs()       { "${ADB[@]}" shell "tail -n 60 $LLAMA_DIR/$LOG"; }
# The on-device engine writes elsewhere, so `logs` never showed it.
logs_local() { "${ADB[@]}" shell "tail -n 60 $LOCAL_LOG"; }

usage() {
  cat <<EOF
usage: $0 <command> [laptop-ip]

  preflight <ip>   phone->laptop ping + worker port check (do this first)
  serve <ip>       launch the split MAIN server on the phone (:$PORT)
  bench <ip>       llama-bench pp128/tg32 through the split
  serve-local      launch the On-device engine on :$LOCAL_PORT (no RPC, no network)
                   — NPU build when present; idempotent, health-checked, retries
  bench-local      llama-bench all-local baseline on the phone
  logs             tail the split server log ($LOG)
  logs-local       tail the On-device server log ($LOCAL_LOG)
  stop [port]      kill llama-server: one port, or ALL when no port is given
                   (\`serve\` only stops :$PORT, so On-device survives it)

env: LLAMA_DIR=$LLAMA_DIR MODEL=$MODEL PORT=$PORT NGL=$NGL THREADS=$THREADS
     CTX=$CTX WORKER_PORT=$WORKER_PORT SERIAL=<adb serial>
EOF
}

cmd=${1:-}; shift || true
case "$cmd" in
  preflight)   [[ $# -ge 1 ]] || die "need the laptop IP"; preflight "$1" ;;
  serve)       [[ $# -ge 1 ]] || die "need the laptop IP"; serve "$1" ;;
  bench)       [[ $# -ge 1 ]] || die "need the laptop IP"; bench "$1" ;;
  serve-local) serve_local ;;
  bench-local) bench_local ;;
  logs)        logs ;;
  logs-local)  logs_local ;;
  stop)        stop "${1:-}" ;;
  *)           usage; exit 1 ;;
esac
