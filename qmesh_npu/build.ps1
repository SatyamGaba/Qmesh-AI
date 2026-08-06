$ErrorActionPreference = 'Continue'
$src = "C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\llama.cpp"
$vs  = "C:\Program Files\Microsoft Visual Studio\2022\Community"
$T   = "C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\hexagon-sdk-wos\6.6.0.0"

$env:OPENCL_SDK_ROOT   = "C:\Qualcomm\OpenCL_SDK\2.3.2"
$env:HEXAGON_SDK_ROOT  = $T
$env:HEXAGON_TOOLS_ROOT= "$T\tools\HEXAGON_Tools\19.0.07"
$env:WINDOWS_SDK_BIN   = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0"
$env:PATH = "$vs\VC\Tools\Llvm\x64\bin;C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\tools;$env:PATH"

Set-Location $src
$sw = [Diagnostics.Stopwatch]::StartNew()
cmake --build build-wos2 --parallel 12 2>&1 | Tee-Object -FilePath "C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\build.log"
$code = $LASTEXITCODE
$sw.Stop()
"=== BUILD EXIT $code in $([math]::Round($sw.Elapsed.TotalMinutes,2)) min ===" |
    Tee-Object -FilePath "C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\build.log" -Append

if ($code -eq 0) {
    cmake --install build-wos2 --prefix "C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\pkg-snapdragon" 2>&1 |
        Tee-Object -FilePath "C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\build.log" -Append
    "=== INSTALL EXIT $LASTEXITCODE ===" |
        Tee-Object -FilePath "C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\build.log" -Append
}
