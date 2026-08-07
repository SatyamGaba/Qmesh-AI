#!/system/bin/sh
# run_leg.sh <tag> <base-url> <payload> — one streamed generation, fully on-phone.
# Marks + timings + stream all land in /data/local/tmp/llama; pull them later.
TAG=$1; URL=$2; PAYLOAD=$3
D=/data/local/tmp/llama
echo "START $TAG $(date +%s)" >> $D/marks_phone.txt
curl -s -N -X POST "$URL/chat/completions" -H 'Content-Type: application/json' \
  -d @$PAYLOAD -o $D/stream_$TAG.txt \
  -w "tag=$TAG http=%{http_code} ttft=%{time_starttransfer} total=%{time_total} bytes=%{size_download}\n" >> $D/curl_phone.txt 2>&1
echo "END $TAG $(date +%s)" >> $D/marks_phone.txt
echo "chunks $TAG $(grep -c '^data:' $D/stream_$TAG.txt)" >> $D/marks_phone.txt
