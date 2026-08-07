#!/usr/bin/env bash
# gen_load.sh <adb-serial> <url> <payload-on-phone> <tag> <outdir>
# One streamed generation driven FROM THE PHONE (the exact path the app takes).
# Captures TTFT (time_starttransfer = first SSE byte, i.e. end of prefill), total
# wall time, and the raw SSE stream (data: chunk count ≈ completion tokens — the
# only token count available for the remote NPU server, which logs nowhere).
# Window marks use the PHONE clock so they slice the sampler CSV without skew.
set -euo pipefail
SERIAL=$1; URL=$2; PAYLOAD=$3; TAG=$4; OUTDIR=$5
STREAM=/data/local/tmp/llama/stream_$TAG.txt
T0=$(adb -s "$SERIAL" shell date +%s | tr -d '\r')
echo "START $TAG $T0" >> "$OUTDIR/marks.txt"
adb -s "$SERIAL" shell "curl -s -N -X POST '$URL/chat/completions' \
  -H 'Content-Type: application/json' -d @$PAYLOAD -o $STREAM \
  -w 'tag=$TAG http=%{http_code} ttft=%{time_starttransfer} total=%{time_total} bytes=%{size_download}\n'" \
  | tr -d '\r' >> "$OUTDIR/curl_timings.txt"
T1=$(adb -s "$SERIAL" shell date +%s | tr -d '\r')
echo "END $TAG $T1" >> "$OUTDIR/marks.txt"
CHUNKS=$(adb -s "$SERIAL" shell "grep -c '^data:' $STREAM" | tr -d '\r')
echo "chunks $TAG $CHUNKS" >> "$OUTDIR/marks.txt"
adb -s "$SERIAL" pull "$STREAM" "$OUTDIR/stream_$TAG.txt" >/dev/null
tail -1 "$OUTDIR/curl_timings.txt"; echo "chunks=$CHUNKS window=$((T1-T0))s"
