<#
  One-command demo bring-up for the whole QMesh stack:

    1. laptop NPU engine   llama-server (hvx, HTP0) on http://<hotspot>:8082
    2. laptop RPC worker   ggml-rpc-server (hvx, HTP0) on <hotspot>:50052
    3. phone NPU server    llama-server on phone loopback :8082  (picker On-device)
    4. phone split server  llama-server -ngl 32 --rpc <hotspot>:50052 on :8081 (picker Split)
    5. QMesh app (PWA in the WebView APK) foregrounded on the phone
    6. telemetry dashboard (live_stats.ps1) in its own window

      powershell -NoProfile -ExecutionPolicy Bypass -File launch_demo.ps1
      ... -NoPwa -NoTelemetry               # skip app launch / dashboard
      ... -Serial 192.168.137.2:40629       # skip mDNS port discovery
      ... -SplitValidation                  # run split_rpc_validation instead
                                            # (loopback CPU split bench; needs no
                                            # hotspot/phone; worker on :50053 so it
                                            # never collides with the demo worker)

  Idempotent: every component is health-checked first and skipped if already
  up, so re-running after a partial failure (or a phone reboot) only starts
  what is missing. Order matters once: the RPC worker must listen before the
  phone split server loads (it transfers 32 layers to the worker at startup).

  It does NOT: start the Windows Mobile Hotspot (needs the UI), install the
  APK, or push models/binaries to the phone -- it verifies and tells you.

  Wireless-adb notes baked in from 2026-08-06: the Wireless-debugging port
  changes on every toggle, but `adb mdns services` discovers it without
  touching the phone; phone processes are launched nohup </dev/null so an
  adb transport drop cannot SIGHUP them.
#>
param(
    [string]$HotspotIP  = '192.168.137.1',
    [string]$PhoneIP    = '192.168.137.2',
    [string]$Serial     = '',    # adb serial; discovered via mDNS when empty
    [int]   $LaptopPort = 8082,
    [int]   $WorkerPort = 50052,
    [string]$PhoneModel = '/data/local/tmp/llama/qwen3-4b-instruct-2507-q4_0.gguf',
    [switch]$NoPwa,
    [switch]$NoTelemetry,
    # Run ../split_rpc_validation (loopback CPU split: worker + bench_split.ps1
    # sweep) and exit -- a validation pass, not part of the demo stack.
    [switch]$SplitValidation,
    [int]   $ValidationPort = 50053
)
$ErrorActionPreference = 'Continue'
# $PSScriptRoot is empty inside a ps2exe-compiled exe; fall back to the exe's
# directory so the same file works as .ps1 and as launch_demo.exe
$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) { $ScriptRoot = Split-Path -Parent ([Environment]::GetCommandLineArgs()[0]) }
$adb  = "$env:LOCALAPPDATA\platform-tools\adb.exe"
$hvx  = "$ScriptRoot\hvx"
$fail = @()

function Step([string]$m) { Write-Host "== $m" -ForegroundColor Cyan }
function Ok  ([string]$m) { Write-Host "   $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "   $m" -ForegroundColor Yellow }

function Test-HttpOk([string]$url) {
    try { return ((Invoke-RestMethod $url -TimeoutSec 3 -ErrorAction Stop).status -eq 'ok') }
    catch { return $false }
}

# Every adb call goes through this hard-timeout wrapper. Wireless adbd on the
# phone half-hangs routinely; a bare `& $adb ...` then blocks forever and the
# step deadlines (which are only checked BETWEEN calls) never fire -- one
# launch was observed wedged for 12 minutes this way. Returns combined
# stdout+stderr, or '' if the call had to be killed.
function Invoke-Adb([string[]]$adbArgs, [int]$timeoutMs = 4000) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $adb
    $psi.Arguments = ($adbArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutMs)) { try { $p.Kill() } catch {} }
    return ($so.Result + $se.Result)
}

# phone-side health probe, tolerant of transient adb hiccups during model load
function Wait-PhoneHealth([int]$port, [int]$secs) {
    $deadline = (Get-Date).AddSeconds($secs)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $h = Invoke-Adb @('-s', $Serial, 'shell', "curl -s -m 2 http://127.0.0.1:$port/health")
        if ("$h" -match '"ok"') { return $true }
    }
    return $false
}

# ---- split_rpc_validation mode ---------------------------------------------
# Self-contained: loopback only, so no hotspot / adb / phone required.
if ($SplitValidation) {
    Step "split_rpc_validation (loopback CPU split, worker on :$ValidationPort)"
    $svd = Join-Path (Split-Path $ScriptRoot -Parent) 'split_rpc_validation'
    if (-not (Test-Path "$svd\bench_split.ps1"))    { "bench_split.ps1 missing at $svd"; exit 1 }
    if (-not (Test-Path "$svd\bin\llama-bench.exe")) { "b10270 bin missing at $svd\bin"; exit 1 }

    # The compiled launch_demo.exe CARRIES the validation worker: at build time
    # build_launch_demo.ps1 swaps these placeholders for the base64 + sha256 of
    # bin\ggml-rpc-server-split.exe. If the on-disk worker is missing (it is the
    # one bin file git does not track, and a `git clean` once ate it), the exe
    # re-materializes it HERE, next to the ggml*.dll it needs to run. Running
    # the plain .ps1 (placeholders intact) keeps requiring the on-disk copy.
    $EmbeddedWorkerB64    = '@@EMBEDDED_WORKER_B64@@'
    $EmbeddedWorkerSha256 = '@@EMBEDDED_WORKER_SHA256@@'
    $workerExe = "$svd\bin\ggml-rpc-server-split.exe"
    if (-not (Test-Path $workerExe)) {
        if ($EmbeddedWorkerB64 -like '@@*') {
            "validation worker missing at $workerExe and this build has no embedded copy (compile with build_launch_demo.ps1)"; exit 1
        }
        Warn "worker missing on disk -- extracting the embedded b10270 copy"
        [IO.File]::WriteAllBytes($workerExe, [Convert]::FromBase64String($EmbeddedWorkerB64))
        $sha = (Get-FileHash $workerExe -Algorithm SHA256).Hash.ToLower()
        if ($sha -ne $EmbeddedWorkerSha256.ToLower()) {
            Remove-Item $workerExe -Force
            "extracted worker failed its sha256 check -- aborting"; exit 1
        }
        Ok "extracted ggml-rpc-server-split.exe (sha256 verified)"
    }

    $existing = Get-NetTCPConnection -State Listen -LocalPort $ValidationPort -LocalAddress '127.0.0.1' -ErrorAction SilentlyContinue
    $w = $null
    if ($existing) {
        Warn "a worker already listens on 127.0.0.1:$ValidationPort -- reusing it (will not stop it afterwards)"
    } else {
        # ggml-rpc-server-split.exe = the b10270 CPU validation worker (renamed
        # so process lists can't confuse it with the hvx NPU worker on :50052)
        $w = Start-Process -FilePath $workerExe -WorkingDirectory $svd -PassThru `
             -ArgumentList '-H', '127.0.0.1', '-p', "$ValidationPort", '-t', '6' `
             -RedirectStandardOutput "$svd\worker.out.log" -RedirectStandardError "$svd\worker.err.log"
        $up = $false
        foreach ($i in 1..10) {
            Start-Sleep -Seconds 1
            if ($w.HasExited) { break }
            if (Get-NetTCPConnection -State Listen -LocalPort $ValidationPort -LocalAddress '127.0.0.1' -ErrorAction SilentlyContinue) { $up = $true; break }
        }
        if (-not $up) { "validation worker FAILED to listen (see $svd\worker.err.log)"; exit 1 }
        Ok "worker up, pid $($w.Id)"
    }

    # child process: bench_split uses Set-StrictMode/-ErrorAction Stop and must
    # not be able to tear down this script; its table streams to the console
    powershell -NoProfile -ExecutionPolicy Bypass -File "$svd\bench_split.ps1" -Rpc "127.0.0.1:$ValidationPort"
    $rc = $LASTEXITCODE

    if ($w) { Stop-Process -Id $w.Id -Force -ErrorAction SilentlyContinue; Ok "worker stopped" }
    if ($rc -ne 0) { Write-Host "bench_split FAILED (exit $rc)" -ForegroundColor Red; exit 1 }
    Ok "split_rpc_validation complete (table above; FINDINGS.md has the reference numbers)"
    exit 0
}

# ---- 0. prerequisites -------------------------------------------------------
Step "prerequisites"
if (-not (Test-Path $adb))                    { "adb not found at $adb"; exit 1 }
if (-not (Test-Path "$hvx\llama-server.exe")) { "hvx build missing at $hvx"; exit 1 }
$have = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $HotspotIP }
if (-not $have) {
    "hotspot address $HotspotIP is not present -- turn on Mobile Hotspot first (Settings > Network)."
    exit 1
}
Ok "hotspot up at $HotspotIP"
$env:GGML_HEXAGON_OPPOLL = '1'   # inherited by every engine started below

# ---- 1. adb link to the phone ----------------------------------------------
Step "phone adb link"
# connect + PROVE the link with a real shell echo -- `adb devices` happily
# lists a dead wireless session as "device" (seen live 2026-08-06), so listed
# state alone means nothing
function Connect-Phone([string]$try) {
    if (-not $try) { return $null }
    Invoke-Adb @('connect', $try) 6000 | Out-Null
    $e = Invoke-Adb @('-s', $try, 'shell', 'echo up')
    if ("$e" -match 'up') { return $try }
    Invoke-Adb @('disconnect', $try) | Out-Null   # drop the stale registration
    return $null
}
$link = Connect-Phone $Serial
if (-not $link) {
    $dev = (Invoke-Adb @('devices') 5000) -split "`r?`n" | Where-Object { "$_" -match "^$([regex]::Escape($PhoneIP)):(\d+)\s+device" }
    if ($dev) { $link = Connect-Phone (("$($dev | Select-Object -First 1)" -split '\s+')[0]) }
}
if (-not $link) {
    # the Wireless-debugging port rotates; mDNS advertises the current one
    foreach ($line in ((Invoke-Adb @('mdns', 'services') 6000) -split "`r?`n")) {
        if ("$line" -match "_adb-tls-connect\._tcp\s+$([regex]::Escape($PhoneIP)):(\d+)") {
            $link = Connect-Phone "${PhoneIP}:$($Matches[1])"; break
        }
    }
}
if (-not $link) { $link = Connect-Phone "${PhoneIP}:5555" }  # adb-tcpip fallback
if (-not $link) {
    "phone unreachable at $PhoneIP (tried given serial, listed devices, mDNS, :5555) -- toggle Wireless debugging on the phone and re-run."
    exit 1
}
$Serial = $link
Ok "phone connected: $Serial"
$m = Invoke-Adb @('-s', $Serial, 'shell', "ls $PhoneModel 2>/dev/null")
if ("$m" -notmatch [regex]::Escape($PhoneModel)) { Warn "model missing on phone: $PhoneModel"; $fail += 'phone-model' }

# ---- 2. laptop NPU engine ---------------------------------------------------
Step "laptop NPU engine (http://${HotspotIP}:$LaptopPort)"
if (Test-HttpOk "http://${HotspotIP}:${LaptopPort}/health") {
    $alias = ''
    try { $alias = (Invoke-RestMethod "http://${HotspotIP}:${LaptopPort}/v1/models" -TimeoutSec 3).models[0].name } catch {}
    if ($alias -like '*@npu*') { Ok "already up (alias $alias)" }
    else { Warn "port $LaptopPort is served by a different engine (alias '$alias') -- leaving it; stop it manually for the NPU engine" }
} else {
    powershell -NoProfile -ExecutionPolicy Bypass -File "$ScriptRoot\run_npu_server.ps1" `
        -BindHost $HotspotIP -Port $LaptopPort
    if ($LASTEXITCODE -ne 0) { Warn "laptop NPU engine FAILED (see npu_server.err)"; $fail += 'laptop-engine' }
    else { Ok "started (run_npu_server.ps1, HTP0)" }
}

# ---- 3. laptop RPC worker ---------------------------------------------------
Step "laptop RPC worker (${HotspotIP}:$WorkerPort, HTP0)"
$listen = Get-NetTCPConnection -State Listen -LocalPort $WorkerPort -LocalAddress $HotspotIP -ErrorAction SilentlyContinue
if ($listen) {
    Ok "already listening"
} else {
    # the worker occasionally dies right after its startup banner (cause not
    # yet pinned down -- seen 2026-08-07); one retry papers over the flake,
    # and on real failure the stderr tail is printed instead of buried
    $up = $false
    foreach ($attempt in 1..2) {
        $p = Start-Process -FilePath "$hvx\ggml-rpc-server.exe" -WorkingDirectory $hvx -PassThru `
             -ArgumentList '-H', $HotspotIP, '-p', "$WorkerPort", '-d', 'HTP0', '-c' `
             -RedirectStandardOutput "$ScriptRoot\rpc_worker.out" -RedirectStandardError "$ScriptRoot\rpc_worker.err"
        foreach ($i in 1..10) {
            Start-Sleep -Seconds 2
            if ($p.HasExited) { break }
            if (Get-NetTCPConnection -State Listen -LocalPort $WorkerPort -LocalAddress $HotspotIP -ErrorAction SilentlyContinue) { $up = $true; break }
        }
        if ($up) { break }
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        if ($attempt -eq 1) { Warn "worker did not come up -- retrying once"; Start-Sleep -Seconds 2 }
    }
    if ($up) { $p.Id | Set-Content "$ScriptRoot\rpc_worker.pid"; Ok "started, pid $($p.Id)" }
    else {
        Warn "worker FAILED to listen after 2 attempts -- last stderr:"
        Get-Content "$ScriptRoot\rpc_worker.err" -Tail 4 -ErrorAction SilentlyContinue | ForEach-Object { Warn "  $_" }
        $fail += 'rpc-worker'
    }
}
# ggml-rpc has unauthenticated-RCE advisories (STATUS open question #7):
$wild = Get-NetTCPConnection -State Listen -LocalPort $WorkerPort -LocalAddress '0.0.0.0' -ErrorAction SilentlyContinue
if ($wild) { Warn "SECURITY: a second rpc-server listens on 0.0.0.0:$WorkerPort (reachable from corp Wi-Fi) -- kill it when found (owning pid $($wild.OwningProcess))" }

# ---- 4. phone NPU server (:8082 on phone loopback) --------------------------
Step "phone NPU server (phone-local :8082)"
if (Wait-PhoneHealth 8082 3) {
    Ok "already up"
} else {
    $cmd = "cd /data/local/tmp/llama.cpp && LD_LIBRARY_PATH=lib ADSP_LIBRARY_PATH=lib GGML_HEXAGON_OPPOLL=1 " +
           "nohup ./bin/llama-server --device HTP0 -ngl 99 --load-mode none -m $PhoneModel " +
           "--host 127.0.0.1 --port 8082 --alias 'qwen3-4b@npu' -c 4096 -t 6 --sse-ping-interval 15 " +
           "--cors-origins '*' --no-cors-credentials > /data/local/tmp/server_8082.log 2>&1 < /dev/null &"
    Invoke-Adb @('-s', $Serial, 'shell', $cmd) 8000 | Out-Null
    if (Wait-PhoneHealth 8082 150) { Ok "started (HTP0, alias qwen3-4b@npu)" }
    else { Warn "phone NPU server FAILED (adb shell tail /data/local/tmp/server_8082.log)"; $fail += 'phone-npu' }
}

# ---- 5. phone split server (:8081 -> laptop worker) -------------------------
Step "phone split server (phone-local :8081 -> ${HotspotIP}:$WorkerPort)"
if ($fail -contains 'rpc-worker') {
    Warn "skipped: RPC worker is down"
    $fail += 'phone-split'
} elseif (Wait-PhoneHealth 8081 3) {
    Ok "already up"
} else {
    $cmd = "cd /data/local/tmp/llama.cpp && LD_LIBRARY_PATH=lib ADSP_LIBRARY_PATH=lib GGML_HEXAGON_OPPOLL=1 " +
           "nohup ./bin/llama-server -ngl 32 --rpc ${HotspotIP}:$WorkerPort --load-mode none -m $PhoneModel " +
           "--host 127.0.0.1 --port 8081 --alias 'qwen3-4b@split' -c 4096 -t 6 --sse-ping-interval 15 " +
           "--cors-origins '*' --no-cors-credentials > /data/local/tmp/server_8081.log 2>&1 < /dev/null &"
    Invoke-Adb @('-s', $Serial, 'shell', $cmd) 8000 | Out-Null
    # slower: ships 32 layers (~1.1 GB) to the worker over Wi-Fi at load
    if (Wait-PhoneHealth 8081 240) { Ok "started (split 4/32, alias qwen3-4b@split)" }
    else { Warn "phone split server FAILED (adb shell tail /data/local/tmp/server_8081.log)"; $fail += 'phone-split' }
}

# ---- 6. QMesh app on the phone ---------------------------------------------
if (-not $NoPwa) {
    Step "QMesh app (ai.qmesh.app)"
    $pkg = Invoke-Adb @('-s', $Serial, 'shell', 'pm path ai.qmesh.app 2>/dev/null')
    if ("$pkg" -match 'package:') {
        Invoke-Adb @('-s', $Serial, 'shell', 'am start -n ai.qmesh.app/.MainActivity') 6000 | Out-Null
        Ok "foregrounded on the phone"
    } else {
        Warn "APK not installed -- cd Qmesh-Android && ./build-apk.sh --install"
        $fail += 'pwa'
    }
}

# ---- 7. telemetry dashboard -------------------------------------------------
if (-not $NoTelemetry) {
    Step "telemetry dashboard (live_stats.ps1)"
    # match by command line, not window title: under Windows Terminal the
    # console window belongs to WindowsTerminal.exe, so powershell.exe's
    # MainWindowTitle is empty and title-based dedupe silently fails
    $existing = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match 'live_stats\.ps1' })
    if ($existing.Count -gt 0) {
        Ok "already running (pid $($existing[0].ProcessId))"
    } else {
        Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',
            '-File', "$ScriptRoot\live_stats.ps1", '-Serial', $Serial | Out-Null
        Ok "opened in its own window (serial $Serial)"
    }
}

# ---- summary ----------------------------------------------------------------
Write-Host ""
Write-Host "== stack ==" -ForegroundColor Cyan
Write-Host "  laptop engine   http://${HotspotIP}:$LaptopPort/v1   (Remote mode, qwen3-4b@npu)"
Write-Host "  rpc worker      ${HotspotIP}:$WorkerPort   (HTP0, split backend)"
Write-Host "  phone on-device http://127.0.0.1:8082/v1   (on the phone; picker On-device)"
Write-Host "  phone split     http://127.0.0.1:8081/v1   (on the phone; picker Split)"
Write-Host "  app             ai.qmesh.app   telemetry: live_stats window"
if ($fail.Count -gt 0) {
    Write-Host "FAILED components: $($fail -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host "all components up" -ForegroundColor Green
