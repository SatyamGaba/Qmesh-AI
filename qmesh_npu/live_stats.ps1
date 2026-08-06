<#
  Live phone telemetry dashboard. Run in its own terminal:

      powershell -NoProfile -ExecutionPolicy Bypass -File live_stats.ps1
      powershell ... -File live_stats.ps1 -IntervalSec 1

  Backend attribution is two-layered:
    ACTUAL column -- kernel evidence (attachment):
      NPU  process holds an open fd on /dev/fastrpc-cdsp  (kernel-level truth)
      GPU  libggml-opencl.so mapped, no fastrpc fd
      CPU  neither
    Probe verdicts (bottom panel) -- GGML profiling flag (execution):
      telemetry.sh probes run llama-bench with GGML_HEXAGON_PROFILE=1 -v;
      NPU = "profile-op" lines (one per DSP-executed op), GPU = "OpenCL ...
      buffer size =" allocations, CPU = neither. This is where ops actually
      RAN, not just what the process is attached to.
  The requested device from the command line is shown alongside, so you can
  see a mismatch between what was asked for and what is actually attached.
  PROF shows the GGML_HEXAGON_PROFILE value the process was launched with.

  Power needs the phone UNPLUGGED -- on AC the charging current swamps the
  discharge reading and `current now` clamps to a couple of fixed buckets.
#>
param(
    [int]$IntervalSec = 2,
    [string]$Serial = "192.168.137.2:5555"
)

$adb = "$env:LOCALAPPDATA\platform-tools\adb.exe"
if (-not (Test-Path $adb)) { Write-Host "adb not found at $adb" -ForegroundColor Red; exit 1 }

function Color([string]$be) {
    switch ($be) { "NPU" { "Green" } "GPU" { "Cyan" } default { "DarkYellow" } }
}

$host.UI.RawUI.WindowTitle = "QMesh phone telemetry"
$peakC = 0.0

while ($true) {
    $raw = & $adb -s $Serial shell "sh /data/local/tmp/telemetry.sh stats" 2>&1
    Clear-Host
    Write-Host "  QMesh phone telemetry   $(Get-Date -Format 'HH:mm:ss')   refresh ${IntervalSec}s   Ctrl+C to quit" -ForegroundColor White
    Write-Host ("  " + ("-" * 96)) -ForegroundColor DarkGray

    if ($raw -match 'no devices|not found|error:') {
        Write-Host "  phone unreachable -- try: adb connect $Serial" -ForegroundColor Red
        Start-Sleep -Seconds $IntervalSec; continue
    }

    $kv = @{}; $procs = @(); $verdicts = @()
    foreach ($line in $raw) {
        $l = "$line".Trim()
        if ($l -like 'PROC=*') { $procs += $l.Substring(5) }
        elseif ($l -like 'VERDICT=*') { $verdicts += $l.Substring(8) }
        elseif ($l -match '^(\w+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] }
    }

    # ---- thermals + power -------------------------------------------------
    $cpuss = if ($kv.CPUSS) { [int]$kv.CPUSS / 1000 } else { 0 }
    $aoss  = if ($kv.AOSS)  { [int]$kv.AOSS  / 1000 } else { 0 }
    $batt  = if ($kv.BATT)  { [int]$kv.BATT  / 10   } else { 0 }
    if ($cpuss -gt $peakC) { $peakC = $cpuss }

    $tcol = if ($cpuss -ge 85) { "Red" } elseif ($cpuss -ge 60) { "Yellow" } else { "Green" }
    Write-Host ("  cpuss {0,6:N1} C   aoss {1,5:N1} C   batt {2,5:N1} C   peak cpuss {3,5:N1} C" -f `
        $cpuss, $aoss, $batt, $peakC) -ForegroundColor $tcol

    if ($kv.CUR -and $kv.VOLT -and [double]$kv.VOLT -gt 0) {
        $amps = [math]::Abs([double]$kv.CUR) * 1e-6
        $volts = [double]$kv.VOLT * 1e-3
        $w = $amps * $volts
        $note = if ([double]$kv.CUR -gt 0) { "  (charging -- power invalid, unplug for real numbers)" } else { "" }
        Write-Host ("  power {0,6:N2} W   ({1:N0} mA @ {2:N2} V){3}" -f $w, ($amps*1000), $volts, $note) `
            -ForegroundColor $(if ($note) { "DarkYellow" } else { "White" })
    } else {
        Write-Host "  power   n/a" -ForegroundColor DarkGray
    }

    # ---- inference processes ---------------------------------------------
    Write-Host ""
    Write-Host ("  {0,-6} {1,-16} {2,-6} {3,-6} {4,8}  {5}" -f "PID","PROCESS","ACTUAL","PROF","RSS MB","REQUESTED / PORT") -ForegroundColor Gray
    Write-Host ("  " + ("-" * 96)) -ForegroundColor DarkGray

    if (-not $procs) {
        Write-Host "  (no llama/ggml inference process running)" -ForegroundColor DarkGray
    }
    foreach ($p in $procs) {
        $f = $p -split '\|'
        if ($f.Count -lt 5) { continue }
        $pid_ = $f[0]; $nm = $f[1]; $be = $f[2]; $rssMb = [math]::Round([double]$f[3]/1024)
        if ($f.Count -ge 6) {
            # new telemetry.sh: pid|name|actual|rss|prof:<v>|cmd
            $prof = $f[4] -replace '^prof:', ''
            $cmd  = $f[5..($f.Count - 1)] -join '|'
        } else {
            # pre-profiling telemetry.sh still deployed on the phone
            $prof = '-'; $cmd = $f[4]
        }

        # what the command line ASKED for -- may differ from what's attached
        $req = "cpu"
        if ($cmd -match '--device\s+(\S+)')  { $req = $Matches[1] }
        elseif ($cmd -match '-ngl\s+0\b')    { $req = "cpu (-ngl 0)" }
        $port = if ($cmd -match '--port\s+(\d+)') { $Matches[1] } else { "-" }
        if ($cmd -match '--rpc\s+(\S+)') { $port += " split->$($Matches[1])" }

        Write-Host ("  {0,-6} {1,-16} " -f $pid_, $nm) -NoNewline
        Write-Host ("{0,-6}" -f $be) -ForegroundColor (Color $be) -NoNewline
        Write-Host (" {0,-6} {1,8}  {2}  :{3}" -f $prof, $rssMb, $req, $port)
    }

    # ---- flag-based verdicts from telemetry.sh probes ---------------------
    if ($verdicts.Count -gt 0) {
        Write-Host ""
        Write-Host "  GGML-profiled probes (GGML_HEXAGON_PROFILE -- where ops actually ran):" -ForegroundColor Gray
        foreach ($v in $verdicts) {
            $g = $v -split '\|'
            if ($g.Count -lt 2) { continue }
            Write-Host ("  {0,-14} " -f $g[0]) -NoNewline
            Write-Host ("{0,-4}" -f $g[1]) -ForegroundColor (Color $g[1]) -NoNewline
            Write-Host ("  " + (($g | Select-Object -Skip 2) -join '  '))
        }
    }

    Write-Host ""
    Write-Host "  ACTUAL = /proc/<pid>/fd evidence (attachment). Probe verdicts = GGML profiling flag (execution)." -ForegroundColor DarkGray
    Start-Sleep -Seconds $IntervalSec
}
