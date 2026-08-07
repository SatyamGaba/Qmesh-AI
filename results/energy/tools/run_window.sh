#!/system/bin/sh
# run_window.sh <tag> <base-url> <payload> <count> — N back-to-back generations
# under ONE mark pair, so the ~2-min window is long enough for the fuel gauge's
# coulomb counter to resolve reliably (short windows straddle its coarse updates).
TAG=$1; URL=$2; PAYLOAD=$3; N=$4
D=/data/local/tmp/llama
TOT=0
echo "START $TAG $(date +%s)" >> $D/marks_phone.txt
i=1
while [ $i -le $N ]; do
  curl -s -N -X POST "$URL/chat/completions" -H 'Content-Type: application/json' \
    -d @$PAYLOAD -o $D/stream_${TAG}_$i.txt \
    -w "tag=${TAG}_$i http=%{http_code} ttft=%{time_starttransfer} total=%{time_total} bytes=%{size_download}\n" >> $D/curl_phone.txt 2>&1
  C=$(grep -c '^data:' $D/stream_${TAG}_$i.txt)
  TOT=$((TOT+C))
  i=$((i+1))
done
echo "END $TAG $(date +%s)" >> $D/marks_phone.txt
echo "chunks $TAG $TOT" >> $D/marks_phone.txt
