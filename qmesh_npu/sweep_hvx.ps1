$ErrorActionPreference = 'Continue'

# Hexagon tuning sweep, Qwen3-4B Q4_0, laptop HTP0 (v73).
# Target: decode (tg32). Prefill kept in view to catch regressions.
#
# Hypothesis under test: HMX is a matrix engine that pays off on batched GEMM
# (prefill, where HTP already wins 433 vs 363) but costs latency on batch-1
# GEMV (decode, where HTP loses 12.2 vs 33.6). Knobs nhmx/mm_select/fa_select
# all disable HMX at different layers. oppoll removes the blocking dspqueue
# wait, which is pure per-op dispatch latency -- also a decode-shaped win.

$dst   = "$PSScriptRoot\hvx"
$model = "$env:LOCALAPPDATA\qmesh_split\models\qwen3-4b-instruct-2507-q4_0.gguf"
$out   = "$PSScriptRoot\sweep"
$log   = "$PSScriptRoot\sweep_hvx.log"

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null

# name -> env overrides
$configs = [ordered]@{
    'baseline'            = @{}
    'oppoll1'             = @{ GGML_HEXAGON_OPPOLL = '1' }
    'nhmx0'               = @{ GGML_HEXAGON_NHMX = '0' }
    'mmsel2_noHMX'        = @{ GGML_HEXAGON_MM_SELECT = '2' }
    'fasel1_noHMX'        = @{ GGML_HEXAGON_FA_SELECT = '1' }
    'nhmx0_oppoll1'       = @{ GGML_HEXAGON_NHMX = '0'; GGML_HEXAGON_OPPOLL = '1' }
    'opbatch128'          = @{ GGML_HEXAGON_OPBATCH = '128' }
    'ndev2'               = @{ GGML_HEXAGON_NDEV = '2' }
    'nofusion'            = @{ GGML_HEXAGON_OPFUSION = '0' }
}

$all = @('GGML_HEXAGON_OPPOLL','GGML_HEXAGON_NHMX','GGML_HEXAGON_MM_SELECT',
         'GGML_HEXAGON_FA_SELECT','GGML_HEXAGON_OPBATCH','GGML_HEXAGON_NDEV',
         'GGML_HEXAGON_OPFUSION')

"=== sweep_hvx $(Get-Date -Format o) ===" | Set-Content $log

foreach ($name in $configs.Keys) {
    # clear every knob, then apply this config
    foreach ($v in $all) { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
    foreach ($kv in $configs[$name].GetEnumerator()) {
        Set-Item -Path "Env:\$($kv.Key)" -Value $kv.Value
    }
    $desc = ($configs[$name].GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
    if (-not $desc) { $desc = '(defaults)' }

    "--- $name : $desc ---" | Add-Content $log

    $p = Start-Process -FilePath "$dst\llama-bench.exe" `
        -ArgumentList '-m', $model, '-p', '128', '-n', '32', '-r', '3', '--device', 'HTP0' `
        -WorkingDirectory $dst -PassThru -Wait -NoNewWindow `
        -RedirectStandardOutput "$out\$name.out" -RedirectStandardError "$out\$name.err"

    "exit $($p.ExitCode)" | Add-Content $log
    # hwinfo proves whether the knob actually reached the DSP (e.g. hmx 1 -> 0)
    (Get-Content "$out\$name.err" -ErrorAction SilentlyContinue |
        Select-String -Pattern 'hwinfo|op batching' | ForEach-Object { $_.Line } | Out-String) | Add-Content $log
    (Get-Content "$out\$name.out" -ErrorAction SilentlyContinue |
        Where-Object { $_ -match 'qwen|test|---' } | Out-String) | Add-Content $log
}

foreach ($v in $all) { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
"=== sweep done ===" | Add-Content $log
