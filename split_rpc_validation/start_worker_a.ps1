#Requires -Version 5.1
<#
.SYNOPSIS
    Worker A on port 50052 - the "phone role" end (holds the FIRST layers
    when used with a tensor split like -TensorSplit 4,32).
#>
[CmdletBinding()]
param(
    [string]$BindHost = "127.0.0.1",
    [string]$Devices = "",
    [int]$Threads = 4
)
& (Join-Path $PSScriptRoot "start_worker.ps1") -BindHost $BindHost -Port 50052 -Devices $Devices -Threads $Threads
