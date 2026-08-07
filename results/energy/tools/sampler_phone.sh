#!/system/bin/sh
# Battery sampler that lives ON the phone — survives adb/tunnel drops.
D=/data/local/tmp/llama
while true; do
  echo "$(date +%s)|$(dumpsys battery | grep -E '^  level|^  voltage|^  temperature|current now|charge counter:' | tr '\n' '|' | tr -s ' ')" >> $D/battery_phone.log
  sleep 1
done
