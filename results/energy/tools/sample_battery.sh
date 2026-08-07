#!/usr/bin/env bash
# sample_battery.sh <adb-serial> <outfile>
# ~1 Hz battery telemetry for the S25 Ultra via `dumpsys battery` — direct sysfs
# (/sys/class/power_supply/**) is permission-denied for shell on this Samsung build.
# Fields captured per line (phone clock, epoch seconds):
#   level (%), voltage (mV), temperature (0.1 °C), current now (µA, + = charging),
#   charge counter (µAh coulomb counter — the energy integral cross-check).
# `current now`/`voltage` refresh every ~2-4 s at the HAL; 60 s+ windows give ~15+
# independent samples. One persistent adb shell so per-sample overhead is one dumpsys.
set -euo pipefail
SERIAL=$1; OUT=$2
exec adb -s "$SERIAL" shell 'while true; do
  echo "$(date +%s)|$(dumpsys battery | grep -E "^  level|^  voltage|^  temperature|current now|charge counter:" | tr "\n" "|" | tr -s " ")"
  sleep 1
done' >> "$OUT"
