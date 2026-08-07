#Requires -Version 5.1
<#
.SYNOPSIS
    Benchmark the RPC split shapes with llama-bench: baseline (no RPC) vs one
    or more -ngl offload depths. Start the worker(s) first (start_worker.ps1).

.DESCRIPTION
    Runs llama-bench pp<Pp>/tg<Tg> for each -ngl value in -NglList, plus a
    no-RPC baseline for reference, and prints one comparison table.

    Layer placement reminder: llama.cpp offloads the LAST -ngl layers to the
    RPC target(s); the first (n_layer - ngl) stay on the MAIN host. On the
    36-layer Qwen3-4B that means "first 4 layers stay on main" = -ngl 32.

.EXAMPLE
    # default sweep against one loopback worker
    .\bench_split.ps1

.EXAMPLE
    # deployment shape: first 4 layers on MAIN, last 32 on the single worker
    .\bench_split.ps1 -Rpc 127.0.0.1:50053 -NglList 32

.EXAMPLE
    # two-worker shape: worker A holds layers 0-3, worker B the rest
    .\bench_split.ps1 -Rpc "127.0.0.1:50052,127.0.0.1:50053" -NglList 99 -TensorSplit 4,32

.EXAMPLE
    # two-device over Wi-Fi (phone is MAIN; this is the laptop-side reference run)
    .\bench_split.ps1 -Rpc 192.168.1.58:50052 -NglList 32,28,24 -SkipBaseline
#>
[CmdletBinding()]
param(
    [string]$Model = "$env:LOCALAPPDATA\qmesh_split\models\qwen3-4b-instruct-2507-q4_0.gguf",

    # Comma-separated host:port list of RPC workers, in layer order.
    [string]$Rpc = "127.0.0.1:50052",

    # Offload depths to sweep. 99 = every layer to the worker(s).
    [int[]]$NglList = @(18, 99),

    # Proportional layer split across multiple workers. Accepts "4,32" or "4/32"
    # (llama-bench wants slashes; llama-cli wants commas - normalized here).
    [string]$TensorSplit = "",

    [int]$Pp = 128,
    [int]$Tg = 32,
    [int]$Reps = 2,
    [int]$Threads = 6,

    # Skip the local no-RPC reference row (e.g. when MAIN is the phone and the
    # baseline was already measured).
    [switch]$SkipBaseline,

    # Write the raw llama-bench output here as well as the console.
    [string]$LogDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$bin = Join-Path $PSScriptRoot "bin\llama-bench.exe"
if (-not (Test-Path $bin))   { Write-Error "llama-bench.exe not found in bin\"; exit 1 }
if (-not (Test-Path $Model)) { Write-Error "model not found: $Model"; exit 1 }

if ($LogDir -and -not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

# llama-bench's tensor-split separator is "/" (llama-cli uses ","). Accept either.
$tsArg = @()
if ($TensorSplit) { $tsArg = @("-ts", $TensorSplit.Replace(",", "/")) }

$common = @("-m", $Model, "-p", "$Pp", "-n", "$Tg", "-r", "$Reps", "-t", "$Threads")

# Parse the "| model | ... | pp128 | 213.94 ± 1.2 |" markdown rows llama-bench emits.
function Invoke-Bench {
    param([string]$Label, [string[]]$BenchArgs)

    Write-Host ""
    Write-Host "[bench] $Label" -ForegroundColor Cyan
    Write-Host "        $bin $($BenchArgs -join ' ')" -ForegroundColor DarkGray

    # PS 5.1: 2>&1 on a native exe wraps each stderr line in an ErrorRecord;
    # under ErrorActionPreference=Stop in a non-interactive host the FIRST
    # stderr line (llama-bench's harmless "load_backend" notice) becomes a
    # terminating error. Relax the preference for the native call only.
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $bin @BenchArgs 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = $eap
    $out | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }

    if ($LogDir) {
        $safe = ($Label -replace '[^\w\.-]', '_')
        $out | Set-Content -Path (Join-Path $LogDir "bench_$safe.log")
    }

    $row = [ordered]@{ Shape = $Label; Prefill = $null; Decode = $null }
    foreach ($line in $out) {
        # columns: ... | <test> | <t/s ± stddev> |
        # No ± anchor: llama-bench emits UTF-8, and under a non-interactive
        # host PowerShell decodes it with the OEM codepage, turning ± into
        # mojibake that a literal ± never matches. The leading number of the
        # t/s cell is unambiguous on its own.
        if ($line -match '\|\s*(pp|tg)(\d+)\s*\|\s*([\d\.]+)') {
            $val = [double]$Matches[3]
            if ($Matches[1] -eq 'pp') { $row.Prefill = $val } else { $row.Decode = $val }
        }
    }
    if ($null -eq $row.Prefill -and $null -eq $row.Decode) {
        Write-Warning "no results parsed for '$Label' - see output above (worker down? model path?)"
    }
    [pscustomobject]$row
}

$results = @()

if (-not $SkipBaseline) {
    # No --rpc at all: every layer on this host's CPU.
    $results += Invoke-Bench "baseline (no RPC, all local)" ($common + @("-ngl", "0"))
}

foreach ($ngl in $NglList) {
    $label = if ($ngl -ge 99) { "split -ngl 99 (all layers remote)" } else { "split -ngl $ngl" }
    if ($TensorSplit) { $label += " -ts $TensorSplit" }
    $results += Invoke-Bench $label ($common + @("--rpc", $Rpc, "-ngl", "$ngl") + $tsArg)
}

Write-Host ""
Write-Host "=== bench_split summary ===" -ForegroundColor Green
Write-Host "model : $(Split-Path $Model -Leaf)"
Write-Host "rpc   : $Rpc"
Write-Host "shape : pp$Pp / tg$Tg, r=$Reps, main -t $Threads"
Write-Host ""
$results | Format-Table -AutoSize @(
    @{ Label = "Shape";        Expression = { $_.Shape } }
    @{ Label = "Prefill t/s";  Expression = { $_.Prefill }; Align = "right" }
    @{ Label = "Decode t/s";   Expression = { $_.Decode  }; Align = "right" }
)

# Emit the objects too, so a caller can pipe into ConvertTo-Json for FINDINGS.md.
$results
