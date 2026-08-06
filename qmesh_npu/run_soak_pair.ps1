<#
  Sustained NPU-vs-CPU soak with power + thermal + throughput.

  Answers the two questions the short r=2 bench could not:
    1. Does the CPU's decode lead survive sustained load, or does it throttle?
       (CPU hit 101 C in a short burst; NPU stayed ~53 C)
    2. What is the real perf-per-watt?
       (needs the phone DISCHARGING -- on AC the current reading clamps)

  Writes soak_<label>.csv / soak_<label>.txt on the device, plus sdhms_<label>.txt
  on the host from logcat.
#>
param(
    [int]$Reps = 10,
    [string]$Serial = "192.168.137.2:5555",
    [string]$OutDir = "$PSScriptRoot\phone_logs"
)

$adb = "$env:LOCALAPPDATA\platform-tools\adb.exe"
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$log = "$PSScriptRoot\soak_pair.log"
"=== soak pair $(Get-Date -Format o) ===" | Set-Content $log

# --- clear the decks: stale engines hold ~5.9 GB on a ~10 GB phone ----------
& $adb -s $Serial shell "pkill -f llama-server; pkill -f llama-bench; pkill -f llama-completion" 2>&1 | Out-Null
Start-Sleep -Seconds 3
$still = & $adb -s $Serial shell "ps -A -o PID,NAME | grep -E 'llama|ggml'" 2>&1
"after cleanup, still running: $still" | Add-Content $log

$b = & $adb -s $Serial shell "dumpsys battery | grep -E 'AC powered|status:'" 2>&1
"charging state: $b" | Add-Content $log

foreach ($cfg in @(@{d='HTP0'; n='npu'}, @{d='cpu'; n='cpu'})) {
    "--- soak $($cfg.n) start $(Get-Date -Format HH:mm:ss) ---" | Add-Content $log
    & $adb -s $Serial logcat -c 2>&1 | Out-Null

    & $adb -s $Serial shell "sh /data/local/tmp/telemetry.sh soak $($cfg.d) $($cfg.n) $Reps" 2>&1 |
        Add-Content $log

    # SDHMS emits ~every 10s; a 3-6 min soak yields a usable sample count
    & $adb -s $Serial logcat -d 2>&1 | Select-String 'SDHMS' |
        ForEach-Object { $_.Line } | Set-Content "$OutDir\sdhms_$($cfg.n).txt" -Encoding utf8

    & $adb -s $Serial pull "/data/local/tmp/soak_$($cfg.n).csv" "$OutDir\soak_$($cfg.n).csv" 2>&1 | Out-Null
    & $adb -s $Serial pull "/data/local/tmp/soak_$($cfg.n).txt" "$OutDir\soak_$($cfg.n).txt" 2>&1 | Out-Null
    "--- soak $($cfg.n) done $(Get-Date -Format HH:mm:ss) ---" | Add-Content $log

    # let the SoC settle so the second run doesn't start hot
    Start-Sleep -Seconds 45
}
"=== SOAK PAIR COMPLETE ===" | Add-Content $log
