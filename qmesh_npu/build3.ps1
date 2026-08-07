$ErrorActionPreference = 'Continue'
$src = "C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\llama.cpp"
$vs  = "C:\Program Files\Microsoft Visual Studio\2022\Community"
$T   = "C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\hexagon-sdk-wos\6.6.0.0"
$log = "C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\build3.log"

$env:OPENCL_SDK_ROOT    = "C:\Qualcomm\OpenCL_SDK\2.3.2"
$env:HEXAGON_SDK_ROOT   = $T
$env:HEXAGON_TOOLS_ROOT = "$T\tools\HEXAGON_Tools\19.0.07"
$env:WINDOWS_SDK_BIN    = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0"
$env:HEXAGON_HTP_CERT   = "C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\certs\ggml-htp-v1.pfx"
$env:PATH = "$vs\VC\Tools\Llvm\x64\bin;C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\tools;$env:PATH"

Set-Location $src
"=== CONFIGURE (with HTP signing enabled) ===" | Set-Content $log
cmake --preset arm64-windows-snapdragon-release -B build-sign 2>&1 | Out-String | Add-Content $log
$cfg = $LASTEXITCODE
"=== CONFIGURE EXIT $cfg ===" | Add-Content $log
if ($cfg -ne 0) { exit $cfg }

$sw = [Diagnostics.Stopwatch]::StartNew()
cmake --build build-sign --parallel 12 2>&1 | Out-String | Add-Content $log
$code = $LASTEXITCODE
$sw.Stop()
"=== BUILD EXIT $code in $([math]::Round($sw.Elapsed.TotalMinutes,2)) min ===" | Add-Content $log
if ($code -ne 0) { exit $code }

cmake --install build-sign --prefix "C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\pkg-signed" 2>&1 | Out-String | Add-Content $log
"=== INSTALL EXIT $LASTEXITCODE ===" | Add-Content $log
exit $LASTEXITCODE
