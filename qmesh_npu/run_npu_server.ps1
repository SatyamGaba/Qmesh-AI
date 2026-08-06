param(
    # Default binds the hotspot interface so the phone (192.168.137.2) can reach the
    # engine while the corporate Wi-Fi (10.73.51.58) cannot see it at all.
    # Use 127.0.0.1 for laptop-only, or 0.0.0.0 to expose on every interface.
    [string]$BindHost = '192.168.137.1',
    [int]   $Port     = 8082,
    [string]$Model    = "$env:LOCALAPPDATA\qmesh_split\models\qwen3-4b-instruct-2507-q4_0.gguf",
    # Launch with the GGML profiling flag (GGML_HEXAGON_PROFILE=1 + -v) and
    # verify AFTER health that the server really executes ops on the NPU:
    # the hexagon backend emits one "profile-op ... usec N" debug line per
    # DSP-executed op, which is direct evidence -- this supersedes the
    # throughput-fingerprinting attribution STATUS.md had to use (llama-server
    # swallows backend logs at default verbosity). Opt-in because -v +
    # per-op profiling costs log volume and a little throughput; use it for
    # attribution/telemetry runs, not demo-performance runs.
    [switch]$GgmlProfile
)
$ErrorActionPreference = 'Continue'

# Run the laptop engine on the Hexagon NPU (HTP0).
#
# On exposure: STATUS.md open question #6 notes pre-existing any-port/any-remote
# Windows Firewall rules for llama-server.exe that OR-override any narrower
# per-port rule -- so firewall scoping cannot restrict this. Binding to a single
# interface can: if the socket never listens on 10.73.51.58, no firewall rule is
# needed to keep the corporate LAN out. That is why the default is the hotspot
# address rather than 0.0.0.0.

$dst = "$PSScriptRoot\hvx"
$log = "$PSScriptRoot\npu_server"

if (-not (Test-Path $Model)) { "model not found: $Model"; exit 1 }
if ($BindHost -ne '127.0.0.1' -and $BindHost -ne '0.0.0.0') {
    $have = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $BindHost }
    if (-not $have) { "bind address $BindHost is not present on this host -- is the hotspot up?"; exit 1 }
}

$env:GGML_HEXAGON_OPPOLL = "1"   # measured +30% prefill / +34% decode
# explicit either way so a value inherited from the calling shell can't leak in
$env:GGML_HEXAGON_PROFILE = if ($GgmlProfile) { '1' } else { '0' }

# Advertise the backend through the alias. llama-server exposes no device
# field, so this alias is the ONLY way the client can learn what it is talking
# to (Qmesh-App parses the suffix -- see Qmesh-App/src/lib/config.ts). Safe:
# llama-server ignores the `model` field in requests and answers with its own
# alias regardless, so this does not have to match NEXT_PUBLIC_ENGINE_MODEL.
# Only claim @npu because we passed --device HTP0 and the health check below
# confirms the server came up with it.
$alias = 'qwen3-4b@npu'

$argl = @('-m', $Model, '--device','HTP0', '-ngl','99',
          '--host',$BindHost, '--port',"$Port", '--alias',$alias,
          '-c','4096', '--sse-ping-interval','15')
# CORS only matters when a browser on another device calls in. --no-cors-credentials
# is load-bearing with '*': Allow-Credentials:true + Origin:* is spec-invalid and
# Chrome rejects it (works in curl, fails in-browser). See STATUS.md client plane.
if ($BindHost -ne '127.0.0.1') { $argl += @('--cors-origins','*','--no-cors-credentials') }
# profile-op lines are GGML_LOG_DEBUG; without -v the server filters them out
if ($GgmlProfile) { $argl += '-v' }

$p = Start-Process -FilePath "$dst\llama-server.exe" -WorkingDirectory $dst -PassThru `
     -ArgumentList $argl -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"

"pid $($p.Id), binding ${BindHost}:$Port, waiting for /health ..."
$probe = if ($BindHost -eq '0.0.0.0') { '127.0.0.1' } else { $BindHost }
$ok = $false
foreach ($i in 1..90) {
    Start-Sleep -Seconds 2
    if ($p.HasExited) { "SERVER EXITED early, code $($p.ExitCode)"; break }
    try {
        if ((Invoke-RestMethod "http://${probe}:$Port/health" -TimeoutSec 3 -ErrorAction Stop).status -eq 'ok') {
            "health ok after $($i*2)s"; $ok = $true; break
        }
    } catch { }
}
if (-not $ok) {
    "NEVER BECAME HEALTHY -- last stderr:"
    Get-Content "$log.err" -Tail 15 -ErrorAction SilentlyContinue
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    exit 1
}

if ($GgmlProfile) {
    # fire a tiny generation so ops actually execute, then read the evidence.
    # NPU = profile-op lines; GPU = "OpenCL ... buffer size =" allocations
    # (the "=" matters -- "OpenCL compute buffer size is 0.0000" shows up even
    # in CPU runs); CPU = neither. Rules validated on this build 2026-08-06.
    try {
        Invoke-RestMethod -Method Post -Uri "http://${probe}:$Port/completion" -TimeoutSec 120 `
            -ContentType 'application/json' -Body '{"prompt":"hi","n_predict":4}' | Out-Null
    } catch { "backend-verify probe request failed: $($_.Exception.Message)" }
    $logs = @("$log.err", "$log.out") | Where-Object { Test-Path $_ }
    $ops = @(Select-String -Path $logs -Pattern 'profile-op' -SimpleMatch -ErrorAction SilentlyContinue).Count
    $gpu = @(Select-String -Path $logs -Pattern 'OpenCL.*buffer size =' -ErrorAction SilentlyContinue).Count
    $be  = if ($ops -gt 0) { 'NPU' } elseif ($gpu -gt 0) { 'GPU' } else { 'CPU' }
    "backend by GGML profiling flag: $be ($ops DSP ops profiled, $gpu OpenCL buffer allocations)"
    if ($be -ne 'NPU') {
        "WARNING: alias claims @npu but the profiling evidence says $be -- check --device/-ngl before demoing"
    }
}

$p.Id | Set-Content "$PSScriptRoot\npu_server.pid"
"server pid $($p.Id) listening on http://${BindHost}:$Port"
