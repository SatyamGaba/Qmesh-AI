#!/system/bin/sh
# Phone telemetry for NPU vs CPU vs GPU inference.
#
# Findings that shaped this script (S25 Ultra / OneUI, non-root shell):
#   /sys/class/power_supply/battery/*  -> SELinux DENIED
#   dumpsys battery                    -> WORKS (current now, voltage, temp)
#   /sys/class/thermal/thermal_zone*   -> WORKS (millidegrees C)
#   /sys/class/devfreq                 -> GPU only, no NPU/DSP domain exposed
#
# Power is derived: P(W) = |current_uA| * 1e-6 * voltage_mV * 1e-3
#
# Backend attribution is two-layered:
#   stats (live)  : kernel evidence -- fastrpc fd / opencl maps. Works on any
#                   running process but only proves ATTACHMENT, not execution.
#   probe/verdict : GGML profiling flag. GGML_HEXAGON_PROFILE=1 makes the
#                   hexagon backend emit one "profile-op ... usec N" debug
#                   line per op the DSP actually EXECUTES; GPU runs place
#                   "OpenCL ... buffer size =" allocations. The "=" is
#                   load-bearing: "OpenCL compute buffer size is 0.0000"
#                   diagnostics appear even in pure-CPU runs. llama-bench
#                   drops ALL logs unless -v, so probes pass -v and keep
#                   stderr. Rules validated on the laptop hvx build
#                   2026-08-06: HTP0 -> 4157 profile-ops / 0 opencl-eq;
#                   CPU -> 0/0; GPUOpenCL -> 0/5.
# Probes are separate tiny runs so bench/soak numbers keep the exact same
# flags as all earlier sessions (profiling + -v would perturb the timings).

BASE=/data/local/tmp/llama.cpp
LIB=$BASE/lib
MODEL=/data/local/tmp/llama/qwen3-4b-instruct-2507-q4_0.gguf
TMP=/data/local/tmp

# Wireless-adb transport drops SIGHUP the shell and kill the run in flight --
# it cut a CPU soak once (STATUS.md) and a CPU probe on 2026-08-06. Ignore it:
# all real output goes to files, so losing the pts costs nothing.
trap '' HUP

# cpu | gpu | HTP0 (or any raw --device name) -> llama-bench flags
devflags() {
    case "$1" in
        cpu) echo "-ngl 0" ;;
        gpu) echo "--device GPUOpenCL -ngl 99" ;;
        *)   echo "--device $1 -ngl 99" ;;
    esac
}

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
    extra=$(devflags $dev)
    cd $BASE
    LD_LIBRARY_PATH=$LIB ADSP_LIBRARY_PATH=$LIB \
      ./bin/llama-bench $extra -m $MODEL --load-mode none \
      -t 6 --cpu-mask 0xfc --cpu-strict 1 --ubatch-size 1024 -fa 1 \
      -p 128 -n 64 -r 2 2>/dev/null
}

# probe <dev> <label> -- tiny GGML-profiled run (~20 s incl. model load).
# Writes ggmlprof_<label>.log + verdict_<label>.txt and echoes the verdict.
# Separate from bench/soak on purpose: their numbers stay flag-identical to
# every earlier session, while the probe carries the attribution evidence.
probe() {
    dev=$1; label=$2
    extra=$(devflags $dev)
    cd $BASE
    LD_LIBRARY_PATH=$LIB ADSP_LIBRARY_PATH=$LIB \
      GGML_HEXAGON_PROFILE=${GGML_HEXAGON_PROFILE:-1} \
      ./bin/llama-bench $extra -m $MODEL --load-mode none \
      -t 6 --cpu-mask 0xfc --cpu-strict 1 --ubatch-size 1024 -fa 1 \
      -p 16 -n 8 -r 1 -v >/dev/null 2>$TMP/ggmlprof_$label.log
    verdict $label
}

# verdict <label> -- CPU/NPU/GPU from the probe's ggml log:
#   NPU: any profile-op line (flag-driven, one per DSP-executed op)
#   GPU: OpenCL model/KV/compute buffers actually allocated ("... size =")
#   CPU: neither
verdict() {
    label=$1
    prof=$TMP/ggmlprof_$label.log
    if [ ! -f "$prof" ]; then echo "VERDICT=$label|NA|no_profile_log"; return 1; fi
    npu=$(grep -c 'profile-op' "$prof")
    gpu=$(grep -c 'OpenCL.*buffer size =' "$prof")
    be=CPU
    if [ "${npu:-0}" -gt 0 ]; then be=NPU
    elif [ "${gpu:-0}" -gt 0 ]; then be=GPU; fi
    ms=""
    if [ "$be" = NPU ] && command -v awk >/dev/null 2>&1; then
        # fields are |-delimited with spaces inside, so split on both
        ms=$(awk -F'[| ]' '/profile-op/ {for(i=1;i<NF;i++) if($i=="usec"){s+=$(i+1);break}} END{printf "%d", s/1000}' "$prof")
    fi
    line="VERDICT=$label|$be|npu_ops=${npu:-0}|gpu_bufs=${gpu:-0}${ms:+|npu_ms=$ms}"
    echo "$line" > $TMP/verdict_$label.txt
    echo "$line"
}

# run <HTP0|cpu|gpu> <label> -- probe for attribution, then sample + bench
run() {
    dev=$1; label=$2
    probe $dev $label
    sample $TMP/pwr_$label.csv 90 &
    SP=$!
    sleep 3
    bench $dev > $TMP/bench_$label.txt 2>&1
    sleep 2
    kill $SP 2>/dev/null
    echo "--- $label done ---"
}

# soak <HTP0|cpu|gpu> <label> <reps>
# Sustained load in ONE process (single model load), long generations, so the
# SoC actually heats up. Answers two things the short r=2 bench cannot:
#   1. does throughput hold, or does it throttle? (watch tg stddev + the temp curve)
#   2. enough SDHMS samples (~10s cadence) for a real power mean
# Preceded by a probe (verdict_soak_<label>.txt) -- the soak itself runs
# UNprofiled so the thermal/throughput numbers are unperturbed.
soak() {
    dev=$1; label=$2; reps=$3
    extra=$(devflags $dev)
    probe $dev soak_$label
    sample $TMP/soak_$label.csv 900 &
    SP=$!
    sleep 3
    cd $BASE
    LD_LIBRARY_PATH=$LIB ADSP_LIBRARY_PATH=$LIB \
      ./bin/llama-bench $extra -m $MODEL --load-mode none \
      -t 6 --cpu-mask 0xfc --cpu-strict 1 --ubatch-size 1024 -fa 1 \
      -p 512 -n 512 -r $reps > $TMP/soak_$label.txt 2>&1
    sleep 2
    kill $SP 2>/dev/null
    echo "--- soak $label done ---"
}

# stats -- one machine-readable snapshot, KEY=VALUE lines. Consumed by live_stats.ps1.
#
# Backend attribution here is evidence-based, in priority order:
#   NPU : process holds an open fd on /dev/fastrpc-cdsp  (kernel-level, cannot be faked)
#   GPU : libggml-opencl.so mapped AND no fastrpc fd
#   CPU : neither
# This proves attachment only. Execution-level truth comes from the probe
# verdicts (GGML_HEXAGON_PROFILE), which are replayed at the end with their age.
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
        # was the process launched with the GGML profiling flag?
        pf=$(tr '\0' '\n' < /proc/$p/environ 2>/dev/null | sed -n 's/^GGML_HEXAGON_PROFILE=//p')
        echo "PROC=$p|$nm|$be|${rss:-0}|prof:${pf:--}|$cmd"
    done

    # flag-based verdicts from past probes, with age so staleness is visible
    now=$(date +%s)
    for v in $TMP/verdict_*.txt; do
        [ -f "$v" ] || continue
        m=$(stat -c %Y "$v" 2>/dev/null)
        echo "$(cat "$v")|age_s=$((now-${m:-$now}))"
    done
}

case "$1" in
    stats)   stats ;;
    sample)  sample $2 $3 ;;
    bench)   bench $2 ;;
    probe)   probe $2 $3 ;;
    verdict) verdict $2 ;;
    run)     run $2 $3 ;;
    soak)    soak $2 $3 $4 ;;
    idle)    sample $TMP/pwr_idle.csv $2 ;;
    *)       echo "usage: $0 sample <out> <secs> | bench <dev> | probe <dev> <label> | verdict <label> | run <dev> <label> | soak <dev> <label> <reps> | idle <secs>   (dev: cpu | gpu | HTP0)" ;;
esac
