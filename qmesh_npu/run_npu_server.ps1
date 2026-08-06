param(
    # Default binds the hotspot interface so the phone (192.168.137.2) can reach the
    # engine while the corporate Wi-Fi (10.73.51.58) cannot see it at all.
    # Use 127.0.0.1 for laptop-only, or 0.0.0.0 to expose on every interface.
    [string]$BindHost = '192.168.137.1',
    [int]   $Port     = 8082,
    [string]$Model    = "$env:LOCALAPPDATA\qmesh_split\models\qwen3-4b-instruct-2507-q4_0.gguf"
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

$p.Id | Set-Content "$PSScriptRoot\npu_server.pid"
"server pid $($p.Id) listening on http://${BindHost}:$Port"
