#Requires -Version 5.1
<#
.SYNOPSIS
    Start the ggml RPC worker. In the real topology this runs on the LAPTOP
    (the phone is the main host). For same-machine validation it runs on
    loopback.

.EXAMPLE
    .\start_worker.ps1                          # loopback, CPU device
    .\start_worker.ps1 -BindHost 0.0.0.0 -Cache # LAN-exposed (phone as main)
    .\start_worker.ps1 -Devices HTP0            # once the Hexagon build lands

.NOTES
    -Cache is load-bearing for the two-device run. The MAIN host streams the
    weights of every offloaded layer to the worker at load time (~1.9 GiB at
    -ngl 32 on Qwen3-4B Q4_0). On loopback that is invisible; over Wi-Fi it is
    minutes on EVERY start. -c makes the worker cache them on disk so only the
    first load pays. Cache lives in %LOCALAPPDATA%\llama.cpp\rpc\.
#>
[CmdletBinding()]
param(
    [string]$BindHost = "127.0.0.1",
    [int]$Port = 50052,
    [string]$Devices = "",
    [int]$Threads = 6,

    # Cache offloaded weights on disk so restarts skip the network re-transfer.
    [switch]$Cache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# renamed from ggml-rpc-server.exe (2026-08-06) to disambiguate from the hvx
# NPU worker of the same name -- this is the b10270 CPU validation worker
$bin = Join-Path $PSScriptRoot "bin\ggml-rpc-server-split.exe"
if (-not (Test-Path $bin)) { Write-Error "ggml-rpc-server-split.exe not found in bin\"; exit 1 }

$rpcArgs = @("-H", $BindHost, "-p", "$Port", "-t", "$Threads")
# Long form only: rpc-server has no -d shorthand for device selection.
if ($Devices) { $rpcArgs += @("--device", $Devices) }
if ($Cache)   { $rpcArgs += "-c" }

Write-Host "[worker] ggml-rpc-server on ${BindHost}:${Port} (devices: $(if ($Devices) { $Devices } else { 'all local' }), cache: $Cache)"
if ($BindHost -ne "127.0.0.1") {
    Write-Warning "ggml-rpc is unauthenticated and has known RCE advisories - only bind to a trusted LAN, with a firewall rule scoped to the phone's IP."
}
& $bin @rpcArgs
