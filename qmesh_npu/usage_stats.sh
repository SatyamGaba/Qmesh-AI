#!/system/bin/sh
# Live CPU / GPU / NPU usage stream for the S25 Ultra (non-root shell).
# Emits one STAT line per second; consumed by usage_gui.ps1.
#
# What each figure IS (honesty matters -- see probes 2026-08-06):
#   cpu  = real %, /proc/stat delta over the interval
#   gpu  = real %, kgsl gpu_busy_percentage (Adreno driver's own counter)
#   npu  = NO true % exists without root on this build:
#            sysMonApp getstate/getinfo --q6 cdsp -> "failed with returnval = 44"
#          so we report evidence instead:
#            npu_pids  = processes holding an open fd on /dev/fastrpc-cdsp
#                        (kernel-level: a live NPU session, cannot be faked)
#            npu_irqps = ipcc/glink interrupt rate -- FastRPC rides these, so it
#                        rises with DSP traffic. Activity signal, NOT a percent.
#
# usage: sh usage_stats.sh stream   (Ctrl+C / kill to stop)
#        sh usage_stats.sh once

cpu_snap() { head -1 /proc/stat; }

irq_snap() {
    t=0
    grep ipcc /proc/interrupts | while read -r line; do
        i=0
        for f in $line; do
            i=$((i+1))
            case $f in (*[!0-9]*) ;; (*) [ $i -ge 2 ] && [ $i -le 9 ] && t=$((t+f)) ;; esac
        done
        echo $t
    done | tail -1
}

emit() {
    # ---- CPU % from /proc/stat delta ----
    set -- $CUR_CPU
    u2=$2; n2=$3; s2=$4; i2=$5; w2=$6; q2=$7; sq2=$8
    set -- $PRV_CPU
    u1=$2; n1=$3; s1=$4; i1=$5; w1=$6; q1=$7; sq1=$8
    dt=$(( (u2+n2+s2+i2+w2+q2+sq2) - (u1+n1+s1+i1+w1+q1+sq1) ))
    di=$(( (i2+w2) - (i1+w1) ))
    if [ $dt -gt 0 ]; then cpu=$(( 100 * (dt - di) / dt )); else cpu=0; fi

    # ---- GPU % straight from the Adreno driver ----
    gpu=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | tr -dc '0-9')

    # ---- NPU evidence ----
    dirq=$(( CUR_IRQ - PRV_IRQ ))
    [ $dirq -lt 0 ] && dirq=0
    npids=""
    for p in $(ps -A -o PID,NAME 2>/dev/null | grep -E 'llama|ggml' | while read pid rest; do echo $pid; done); do
        if ls -l /proc/$p/fd 2>/dev/null | grep -q fastrpc-cdsp; then
            npids="$npids$p,"
        fi
    done

    # ---- per-process rows ----
    procs=""
    for p in $(ps -A -o PID,NAME 2>/dev/null | grep -E 'llama|ggml' | while read pid rest; do echo $pid; done); do
        nm=$(cat /proc/$p/comm 2>/dev/null)
        be=CPU
        if ls -l /proc/$p/fd 2>/dev/null | grep -q fastrpc-cdsp; then be=NPU
        elif grep -q libggml-opencl /proc/$p/maps 2>/dev/null; then be=GPU; fi
        rss=$(grep VmRSS /proc/$p/status 2>/dev/null | tr -dc '0-9')
        procs="$procs$p:$nm:$be:$((${rss:-0}/1024));"
    done

    cpuss=$(cat /sys/class/thermal/thermal_zone5/temp 2>/dev/null)
    echo "STAT cpu=$cpu gpu=${gpu:-0} npu_irqps=$dirq npu_pids=${npids:-none} cpuss=${cpuss:-0} procs=$procs"
}

PRV_CPU=$(cpu_snap); PRV_IRQ=$(irq_snap)
sleep 1
if [ "$1" = "once" ]; then
    CUR_CPU=$(cpu_snap); CUR_IRQ=$(irq_snap)
    emit
    exit 0
fi
while true; do
    CUR_CPU=$(cpu_snap); CUR_IRQ=$(irq_snap)
    emit
    PRV_CPU=$CUR_CPU; PRV_IRQ=$CUR_IRQ
    sleep 1
done
