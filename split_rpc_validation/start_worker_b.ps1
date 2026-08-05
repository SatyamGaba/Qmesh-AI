#Requires -Version 5.1
<#
.SYNOPSIS
    Worker B on port 50053 - the "laptop role" end (holds the REMAINING layers
    when used with a tensor split like -TensorSplit 4,32).
#>
[CmdletBinding()]
param(
    [string]$BindHost = "127.0.0.1",
    [string]$Devices = "",
    [int]$Threads = 6
)
& (Join-Path $PSScriptRoot "start_worker.ps1") -BindHost $BindHost -Port 50053 -Devices $Devices -Threads $Threads
