#Requires -Version 5.1
<#
.SYNOPSIS
    Single-turn generation sanity check through the split (start_worker.ps1 first).

.EXAMPLE
    .\chat_split.ps1
    .\chat_split.ps1 -Ngl 18 -Prompt "Explain KV cache in one sentence."
#>
[CmdletBinding()]
param(
    [string]$Model = "$env:LOCALAPPDATA\qmesh_split\models\qwen3-4b-instruct-2507-q4_0.gguf",
    [string]$Rpc = "127.0.0.1:50052",
    [string]$TensorSplit = "",
    [int]$Ngl = 18,
    [string]$Prompt = "The capital of France is",
    [int]$MaxTokens = 64
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$bin = Join-Path $PSScriptRoot "bin\llama-cli.exe"
if (-not (Test-Path $bin)) { Write-Error "llama-cli.exe not found in bin\"; exit 1 }

# -st (single turn) exits after one response instead of looping on stdin.
$extra = @()
# llama-cli expects comma-separated proportions (llama-bench uses slashes)
if ($TensorSplit) { $extra = @("-ts", $TensorSplit.Replace("/", ",")) }
& $bin -m $Model --rpc $Rpc -ngl $Ngl -n $MaxTokens -st --temp 0 -p $Prompt @extra
