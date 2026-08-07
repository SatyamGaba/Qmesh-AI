<#
  Build launch_demo.exe with the split_rpc_validation worker EMBEDDED.

      powershell -NoProfile -ExecutionPolicy Bypass -File build_launch_demo.ps1

  Why a build script: the exe must carry bin\ggml-rpc-server-split.exe (user
  requirement -- the launcher self-heals the one bin file git does not track),
  but a 124 KB base64 blob does not belong in the git-tracked .ps1 source. So
  launch_demo.ps1 holds @@EMBEDDED_WORKER_B64@@ / @@EMBEDDED_WORKER_SHA256@@
  placeholders and this script swaps in the real values at compile time.

  Known rebuild traps handled here (all hit live on 2026-08-06):
   - a lingering launch_demo host process holds the old exe -> killed first
   - OneDrive sync locks the destination -> compile to %TEMP%, Copy-Item over
     with retries
#>
param(
    [string]$Out = "$PSScriptRoot\launch_demo.exe"
)
$ErrorActionPreference = 'Stop'

$src    = "$PSScriptRoot\launch_demo.ps1"
$worker = Join-Path (Split-Path $PSScriptRoot -Parent) 'split_rpc_validation\bin\ggml-rpc-server-split.exe'
if (-not (Test-Path $src))    { Write-Error "source not found: $src" }
if (-not (Test-Path $worker)) { Write-Error "worker not found: $worker -- nothing to embed" }
if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    Write-Error "ps2exe module not available (Install-Module ps2exe -Scope CurrentUser)"
}

$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($worker))
$sha = (Get-FileHash $worker -Algorithm SHA256).Hash.ToLower()
"embedding $(Split-Path $worker -Leaf): $([math]::Round((Get-Item $worker).Length/1KB)) KB, sha256 $sha"

$text = [IO.File]::ReadAllText($src)
if ($text -notmatch '@@EMBEDDED_WORKER_B64@@') {
    Write-Error "placeholder @@EMBEDDED_WORKER_B64@@ not found in launch_demo.ps1"
}
$text = $text.Replace('@@EMBEDDED_WORKER_B64@@', $b64).Replace('@@EMBEDDED_WORKER_SHA256@@', $sha)

$tmpPs  = "$env:TEMP\launch_demo_embedded.ps1"
$tmpExe = "$env:TEMP\launch_demo_build.exe"
[IO.File]::WriteAllText($tmpPs, $text, [Text.UTF8Encoding]::new($true))

Get-Process launch_demo -ErrorAction SilentlyContinue | Stop-Process -Force -Confirm:$false

Invoke-ps2exe -inputFile $tmpPs -outputFile $tmpExe -noConfigFile `
    -title 'QMesh demo launcher' -description 'One-command QMesh demo stack bring-up (validation worker embedded)' | Out-Null
if (-not (Test-Path $tmpExe)) { Write-Error "ps2exe produced no output" }

$done = $false
foreach ($i in 1..10) {
    try { Copy-Item $tmpExe $Out -Force -ErrorAction Stop; $done = $true; break }
    catch { Start-Sleep -Seconds 3 }
}
Remove-Item $tmpPs, $tmpExe -Force -ErrorAction SilentlyContinue
if (-not $done) { Write-Error "could not replace $Out (still locked after 10 tries)" }
"built $Out ($([math]::Round((Get-Item $Out).Length/1KB)) KB)"
