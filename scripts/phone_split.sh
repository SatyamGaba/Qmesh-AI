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
LOG=split.log

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

serve() {
  local ip=$1
  preflight "$ip"
  stop >/dev/null 2>&1 || true
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

# all_local reference mode (no --rpc), for the side-by-side comparison.
serve_local() {
  require_device
  info "starting llama-server all_local on :8082 (no RPC, all 36 layers on the phone)"
  "${ADB[@]}" shell "cd $LLAMA_DIR && LD_LIBRARY_PATH=. nohup ./llama-server \
      -m $MODEL --host 127.0.0.1 --port 8082 --alias qwen3-4b \
      -c $CTX -t $THREADS --sse-ping-interval 15 </dev/null >local.log 2>&1 & echo started"
  "${ADB[@]}" forward tcp:8082 tcp:8082 >/dev/null
  info "forwarded :8082"
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

stop() {
  info "stopping llama-server on the phone"
  "${ADB[@]}" shell "pkill -f llama-server || true"
}

logs() { "${ADB[@]}" shell "tail -n 60 $LLAMA_DIR/$LOG"; }

usage() {
  cat <<EOF
usage: $0 <command> [laptop-ip]

  preflight <ip>   phone->laptop ping + worker port check (do this first)
  serve <ip>       launch the split MAIN server on the phone (:$PORT)
  bench <ip>       llama-bench pp128/tg32 through the split
  serve-local      launch all_local on :8082 (no RPC) for comparison
  bench-local      llama-bench all-local baseline on the phone
  logs             tail the phone-side server log
  stop             kill llama-server on the phone

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
  stop)        stop ;;
  *)           usage; exit 1 ;;
esac
