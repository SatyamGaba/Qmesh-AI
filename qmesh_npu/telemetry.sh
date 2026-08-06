#!/system/bin/sh
# Phone telemetry for NPU vs CPU inference.
#
# Findings that shaped this script (S25 Ultra / OneUI, non-root shell):
#   /sys/class/power_supply/battery/*  -> SELinux DENIED
#   dumpsys battery                    -> WORKS (current now, voltage, temp)
#   /sys/class/thermal/thermal_zone*   -> WORKS (millidegrees C)
#   /sys/class/devfreq                 -> GPU only, no NPU/DSP domain exposed
#
# Power is derived: P(W) = |current_uA| * 1e-6 * voltage_mV * 1e-3

BASE=/data/local/tmp/llama.cpp
LIB=$BASE/lib
MODEL=/data/local/tmp/llama/qwen3-4b-instruct-2507-q4_0.gguf

# one CSV row per sample: elapsed, current_uA, voltage_mV, batt_dC, ap_mC, cpuss_mC
sample() {
    out=$1; secs=$2
    echo "t,current_ua,voltage_mv,batt_dc,aoss_mc,cpuss_mc" > $out
    i=0
    while [ $i -lt $secs ]; do
        b=$(dumpsys battery 2>/dev/null)
        c=$(echo "$b" | grep 'current now' | tr -dc '0-9-')
        # must anchor: a bare 'voltage' also matches "Max charging voltage: 0"
        v=$(echo "$b" | grep -E '^[[:space:]]*voltage:' | head -1 | tr -dc '0-9-')
        t=$(echo "$b" | grep -w 'temperature' | head -1 | tr -dc '0-9-')
        a=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
        s=$(cat /sys/class/thermal/thermal_zone5/temp 2>/dev/null)
        echo "$i,${c:-NA},${v:-NA},${t:-NA},${a:-NA},${s:-NA}" >> $out
        i=$((i+1))
        sleep 1
    done
}

bench() {
    dev=$1
    if [ "$dev" = "cpu" ]; then extra="-ngl 0"; else extra="--device HTP0 -ngl 99"; fi
    cd $BASE
    LD_LIBRARY_PATH=$LIB ADSP_LIBRARY_PATH=$LIB \
      ./bin/llama-bench $extra -m $MODEL --load-mode none \
      -t 6 --cpu-mask 0xfc --cpu-strict 1 --ubatch-size 1024 -fa 1 \
      -p 128 -n 64 -r 2 2>/dev/null
}

# run <HTP0|cpu> <label> -- sample in background while benching
run() {
    dev=$1; label=$2
    sample /data/local/tmp/pwr_$label.csv 90 &
    SP=$!
    sleep 3
    bench $dev > /data/local/tmp/bench_$label.txt 2>&1
    sleep 2
    kill $SP 2>/dev/null
    echo "--- $label done ---"
}

# soak <HTP0|cpu> <label> <reps>
# Sustained load in ONE process (single model load), long generations, so the
# SoC actually heats up. Answers two things the short r=2 bench cannot:
#   1. does throughput hold, or does it throttle? (watch tg stddev + the temp curve)
#   2. enough SDHMS samples (~10s cadence) for a real power mean
soak() {
    dev=$1; label=$2; reps=$3
    if [ "$dev" = "cpu" ]; then extra="-ngl 0"; else extra="--device HTP0 -ngl 99"; fi
    sample /data/local/tmp/soak_$label.csv 900 &
    SP=$!
    sleep 3
    cd $BASE
    LD_LIBRARY_PATH=$LIB ADSP_LIBRARY_PATH=$LIB \
      ./bin/llama-bench $extra -m $MODEL --load-mode none \
      -t 6 --cpu-mask 0xfc --cpu-strict 1 --ubatch-size 1024 -fa 1 \
      -p 512 -n 512 -r $reps > /data/local/tmp/soak_$label.txt 2>&1
    sleep 2
    kill $SP 2>/dev/null
    echo "--- soak $label done ---"
}

# stats -- one machine-readable snapshot, KEY=VALUE lines. Consumed by live_stats.ps1.
#
# Backend attribution is evidence-based, in priority order:
#   NPU : process holds an open fd on /dev/fastrpc-cdsp  (kernel-level, cannot be faked)
#   GPU : libggml-opencl.so mapped AND no fastrpc fd
#   CPU : neither
# The command line is reported separately so you can see what was *asked* for
# versus what is *actually* attached.
stats() {
    b=$(dumpsys battery 2>/dev/null)
    echo "CUR=$(echo "$b" | grep 'current now' | tr -dc '0-9-')"
    echo "VOLT=$(echo "$b" | grep -E '^[[:space:]]*voltage:' | head -1 | tr -dc '0-9-')"
    echo "BATT=$(echo "$b" | grep -E '^[[:space:]]*temperature:' | head -1 | tr -dc '0-9-')"
    echo "AOSS=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
    echo "CPUSS=$(cat /sys/class/thermal/thermal_zone5/temp 2>/dev/null)"

    for p in $(ps -A -o PID,NAME 2>/dev/null | grep -E 'llama-(server|bench|cli|completion)|ggml-rpc' | while read pid rest; do echo $pid; done); do
        nm=$(cat /proc/$p/comm 2>/dev/null)
        cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')
        be="CPU"
        if ls -l /proc/$p/fd 2>/dev/null | grep -q 'fastrpc-cdsp'; then
            be="NPU"
        elif grep -q 'libggml-opencl' /proc/$p/maps 2>/dev/null; then
            be="GPU"
        fi
        rss=$(grep VmRSS /proc/$p/status 2>/dev/null | tr -dc '0-9')
        echo "PROC=$p|$nm|$be|${rss:-0}|$cmd"
    done
}

case "$1" in
    stats)  stats ;;
    sample) sample $2 $3 ;;
    bench)  bench $2 ;;
    run)    run $2 $3 ;;
    soak)   soak $2 $3 $4 ;;
    idle)   sample /data/local/tmp/pwr_idle.csv $2 ;;
    *)      echo "usage: $0 sample <out> <secs> | bench <dev> | run <dev> <label> | soak <dev> <label> <reps> | idle <secs>" ;;
esac
