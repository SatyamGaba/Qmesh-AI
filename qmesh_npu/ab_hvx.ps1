$ErrorActionPreference = 'Continue'

# Interleaved A/B/C/D/E, 3 rounds. The first sweep ran each config once, back to
# back, on battery -- so a config's score was confounded with when it ran. Here
# every arm is sampled once per round in the same order, so thermal/DCVS drift
# hits all arms roughly equally and BETWEEN-ARM comparison stays valid even if
# the absolute numbers sag over time.
#
# The CPU arm is included in the interleave on purpose: the headline
# "HTP 12.2 vs CPU 33.6" compared runs taken at different times, which is
# exactly the confound this script removes.

$dst   = "$PSScriptRoot\hvx"
$q4    = "$env:LOCALAPPDATA\qmesh_split\models\qwen3-4b-instruct-2507-q4_0.gguf"
$mx    = "$env:LOCALAPPDATA\qmesh_split\models\qwen3-4b-mxfp4.gguf"
$out   = "$PSScriptRoot\ab"
$log   = "$PSScriptRoot\ab_hvx.log"
$rounds = 3

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null

$arms = @(
    @{ name='htp_q4_base';     model=$q4; args=@('--device','HTP0'); env=@{} }
    @{ name='htp_q4_oppoll';   model=$q4; args=@('--device','HTP0'); env=@{ GGML_HEXAGON_OPPOLL='1' } }
    @{ name='htp_q4_nofusion'; model=$q4; args=@('--device','HTP0'); env=@{ GGML_HEXAGON_OPFUSION='0' } }
    @{ name='cpu_q4';          model=$q4; args=@('-ngl','0');        env=@{} }
)
if (Test-Path $mx) {
    $arms += @{ name='htp_mxfp4_oppoll'; model=$mx; args=@('--device','HTP0'); env=@{ GGML_HEXAGON_OPPOLL='1' } }
    $arms += @{ name='cpu_mxfp4';        model=$mx; args=@('-ngl','0');        env=@{} }
}

$knobs = @('GGML_HEXAGON_OPPOLL','GGML_HEXAGON_OPFUSION','GGML_HEXAGON_NHMX')

"=== ab_hvx $(Get-Date -Format o) ===" | Set-Content $log
$b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
"power: BatteryStatus=$($b.BatteryStatus) charge=$($b.EstimatedChargeRemaining)% (2 = on AC)" | Add-Content $log

foreach ($r in 1..$rounds) {
    foreach ($a in $arms) {
        foreach ($k in $knobs) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue }
        foreach ($kv in $a.env.GetEnumerator()) { Set-Item -Path "Env:\$($kv.Key)" -Value $kv.Value }

        $tag = "r$r`_$($a.name)"
        $argl = @('-m', $a.model, '-p','128','-n','32','-r','2') + $a.args
        $p = Start-Process -FilePath "$dst\llama-bench.exe" -ArgumentList $argl `
            -WorkingDirectory $dst -PassThru -Wait -NoNewWindow `
            -RedirectStandardOutput "$out\$tag.out" -RedirectStandardError "$out\$tag.err"

        $rows = Get-Content "$out\$tag.out" -ErrorAction SilentlyContinue | Where-Object { $_ -match '\|\s+(pp|tg)\d+' }
        foreach ($row in $rows) {
            # "... |  pp128 |  448.83 +/- 4.25 |"
            $cells = $row -split '\|' | ForEach-Object { $_.Trim() }
            $test  = ($cells | Where-Object { $_ -match '^(pp|tg)\d+$' })
            $ts    = ($cells | Where-Object { $_ -match '^[\d.]+\s*.\s*[\d.]+$' })
            "$tag`t$test`t$ts" | Add-Content $log
        }
        if (-not $rows) { "$tag`tNO-RESULT (exit $($p.ExitCode))" | Add-Content $log }
    }
}

foreach ($k in $knobs) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue }
"=== ab done ===" | Add-Content $log
