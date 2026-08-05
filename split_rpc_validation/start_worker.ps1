#Requires -Version 5.1
<#
.SYNOPSIS
    Start the ggml RPC worker. In the real topology this runs on the LAPTOP
    (the phone is the main host). For same-machine validation it runs on
    loopback.

.EXAMPLE
    .\start_worker.ps1                          # loopback, CPU device
    .\start_worker.ps1 -BindHost 0.0.0.0        # LAN-exposed (phone as main)
    .\start_worker.ps1 -Devices HTP0            # once the Hexagon build lands
#>
[CmdletBinding()]
param(
    [string]$BindHost = "127.0.0.1",
    [int]$Port = 50052,
    [string]$Devices = "",
    [int]$Threads = 6
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$bin = Join-Path $PSScriptRoot "bin\ggml-rpc-server.exe"
if (-not (Test-Path $bin)) { Write-Error "ggml-rpc-server.exe not found in bin\"; exit 1 }

$rpcArgs = @("-H", $BindHost, "-p", "$Port", "-t", "$Threads")
if ($Devices) { $rpcArgs += @("-d", $Devices) }

Write-Host "[worker] ggml-rpc-server on ${BindHost}:${Port} (devices: $(if ($Devices) { $Devices } else { 'all local' }))"
& $bin @rpcArgs
