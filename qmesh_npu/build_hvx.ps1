$ErrorActionPreference = 'Continue'

# Track B -- native HVX build of llama.cpp for Snapdragon X Elite (HTP v73)
# Adds two things build2 lacked:
#   1. HEXAGON_HTP_CERT -> generates + signs libggml-htp.cat (without it the DSP
#      ops libs cannot be loaded by FastRPC on Windows)
#   2. GGML_RPC=ON      -> builds ggml-rpc-server.exe, the Track B split worker

$root = $PSScriptRoot   # derive from script location so the tree can be relocated
$src  = "$root\llama.cpp"
$vs   = "C:\Program Files\Microsoft Visual Studio\2022\Community"
$T    = "$root\hexagon-sdk-wos\6.6.0.0"
$bld  = "build-hvx"
$pkg  = "$root\pkg-hvx"
$log  = "$root\build_hvx.log"

$env:OPENCL_SDK_ROOT    = "C:\Qualcomm\OpenCL_SDK\2.3.2"
$env:HEXAGON_SDK_ROOT   = $T
$env:HEXAGON_TOOLS_ROOT = "$T\tools\HEXAGON_Tools\19.0.07"
$env:HEXAGON_HTP_CERT   = "$root\certs\ggml-htp-v1.pfx"
# 26100 carries signtool (arm64) and Inf2Cat (x86); 22621 has no Inf2Cat.
$env:WINDOWS_SDK_BIN    = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0"
$env:PATH = "$vs\VC\Tools\Llvm\x64\bin;$root\tools;$env:PATH"

Set-Location $src

# A CMake build tree hardcodes absolute paths (CMAKE_HOME_DIRECTORY,
# CMAKE_CACHEFILE_DIR, ggml_SOURCE_DIR, and every path in build.ninja). If this
# whole tree has been relocated, reconfiguring in place fails. Detect a cache
# that points somewhere else and wipe it rather than half-building against
# stale paths.
$cache = "$src\$bld\CMakeCache.txt"
if (Test-Path $cache) {
    $home_dir = (Select-String -Path $cache -Pattern '^CMAKE_HOME_DIRECTORY:INTERNAL=(.*)$').Matches.Groups[1].Value
    $want = $src -replace '\\','/'
    if ($home_dir -and ($home_dir.TrimEnd('/') -ne $want.TrimEnd('/'))) {
        Write-Output "stale build tree: cache points at '$home_dir', source is '$want' -- wiping $bld"
        Remove-Item "$src\$bld" -Recurse -Force
    }
}

"=== ENV ===" | Set-Content $log
"SRC                = $src"                    | Add-Content $log
"HEXAGON_SDK_ROOT   = $env:HEXAGON_SDK_ROOT"   | Add-Content $log
"HEXAGON_TOOLS_ROOT = $env:HEXAGON_TOOLS_ROOT" | Add-Content $log
"HEXAGON_HTP_CERT   = $env:HEXAGON_HTP_CERT"   | Add-Content $log
"WINDOWS_SDK_BIN    = $env:WINDOWS_SDK_BIN"    | Add-Content $log

"=== CONFIGURE ===" | Add-Content $log
cmake --preset arm64-windows-snapdragon-release -B $bld `
    -DGGML_RPC=ON `
    -DGGML_HEXAGON_HTP_CERT="$env:HEXAGON_HTP_CERT" 2>&1 | Out-String | Add-Content $log
$cfg = $LASTEXITCODE
"=== CONFIGURE EXIT $cfg ===" | Add-Content $log
if ($cfg -ne 0) { exit $cfg }

$sw = [Diagnostics.Stopwatch]::StartNew()
cmake --build $bld --parallel 12 2>&1 | Out-String | Add-Content $log
$code = $LASTEXITCODE
$sw.Stop()
"=== BUILD EXIT $code in $([math]::Round($sw.Elapsed.TotalMinutes,2)) min ===" | Add-Content $log
if ($code -ne 0) { exit $code }

cmake --install $bld --prefix $pkg 2>&1 | Out-String | Add-Content $log
"=== INSTALL EXIT $LASTEXITCODE ===" | Add-Content $log
exit $LASTEXITCODE
