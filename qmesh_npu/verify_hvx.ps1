$ErrorActionPreference = 'Continue'

# Track B verification:
#   1. does the Hexagon backend register HTP0 as a ggml device?  (B3 gate)
#   2. does it actually compute on HVX?                          (bench vs CPU)
#   3. does rpc-server expose HTP0?                              (open question #2 / B2)

$dst   = "$PSScriptRoot\hvx"
$model = "$env:LOCALAPPDATA\qmesh_split\models\qwen3-4b-instruct-2507-q4_0.gguf"
$small = "$env:LOCALAPPDATA\qmesh_split\models\qwen2.5-0.5b-q4_0.gguf"
$log   = "$PSScriptRoot\verify_hvx.log"

$env:PATH = "$dst;$env:PATH"
Set-Location $dst

"=== verify_hvx $(Get-Date -Format o) ===" | Set-Content $log

"--- 1. device enumeration (llama-bench --list-devices) ---" | Add-Content $log
(& "$dst\llama-bench.exe" --list-devices 2>&1 | Out-String) | Add-Content $log

"--- 2. hexagon backend init, verbose, small model ---" | Add-Content $log
$env:GGML_HEXAGON_VERBOSE = "1"
(& "$dst\llama-bench.exe" -m $small -p 64 -n 16 -r 1 --device HTP0 2>&1 | Out-String) | Add-Content $log
Remove-Item Env:\GGML_HEXAGON_VERBOSE -ErrorAction SilentlyContinue

"--- 3. Qwen3-4B Q4_0 on HTP0 (pp128/tg32) ---" | Add-Content $log
(& "$dst\llama-bench.exe" -m $model -p 128 -n 32 -r 2 --device HTP0 2>&1 | Out-String) | Add-Content $log

"--- 4. Qwen3-4B Q4_0 on CPU (baseline, same build, -ngl 0) ---" | Add-Content $log
(& "$dst\llama-bench.exe" -m $model -p 128 -n 32 -r 2 -ngl 0 2>&1 | Out-String) | Add-Content $log

"--- 5. OPEN QUESTION #2: rpc-server --device HTP0 ---" | Add-Content $log
$rpc = Start-Process -FilePath "$dst\ggml-rpc-server.exe" `
    -ArgumentList '--host','127.0.0.1','--port','50052','--device','HTP0' `
    -WorkingDirectory $dst -PassThru -RedirectStandardOutput "$dst\rpc_out.txt" -RedirectStandardError "$dst\rpc_err.txt"
Start-Sleep -Seconds 6
if (-not $rpc.HasExited) {
    "rpc-server ALIVE (pid $($rpc.Id)) after 6s" | Add-Content $log
} else {
    "rpc-server EXITED early, code $($rpc.ExitCode)" | Add-Content $log
}
"--- rpc stdout ---" | Add-Content $log
(Get-Content "$dst\rpc_out.txt" -ErrorAction SilentlyContinue | Out-String) | Add-Content $log
"--- rpc stderr ---" | Add-Content $log
(Get-Content "$dst\rpc_err.txt" -ErrorAction SilentlyContinue | Out-String) | Add-Content $log

if (-not $rpc.HasExited) {
    "--- 6. split over loopback RPC with HTP0 worker (small model) ---" | Add-Content $log
    (& "$dst\llama-bench.exe" -m $small -p 64 -n 16 -r 1 --rpc 127.0.0.1:50052 -ngl 99 2>&1 | Out-String) | Add-Content $log
    Stop-Process -Id $rpc.Id -Force -ErrorAction SilentlyContinue
}

"=== done ===" | Add-Content $log
