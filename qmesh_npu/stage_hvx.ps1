$ErrorActionPreference = 'Continue'

# Flatten the installed package into one runtime dir.
# ggml-hexagon requests the DSP skel by bare filename
#   file:///libggml-htp-v73.so?htp_iface_skel_handle_invoke
# so the .so + its signed .cat must sit beside the executables, together with
# libcdsprpc.dll (FastRPC) which ships only in the DriverStore, not System32.

$root = $PSScriptRoot   # derive from script location so the tree can be relocated
$pkg  = "$root\pkg-hvx"
$dst  = "$root\hvx"

if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
New-Item -ItemType Directory -Path $dst -Force | Out-Null

Copy-Item "$pkg\bin\*" $dst -Force
Copy-Item "$pkg\lib\libggml-htp-*.so" $dst -Force
if (Test-Path "$pkg\lib\libggml-htp.cat") { Copy-Item "$pkg\lib\libggml-htp.cat" $dst -Force }

# FastRPC user-space shim from the NPU driver package
$fastrpc = "C:\Windows\System32\DriverStore\FileRepository\qcnspmcdm8380.inf_arm64_e663a92a933cab52\libcdsprpc.dll"
if (Test-Path $fastrpc) { Copy-Item $fastrpc $dst -Force } else { Write-Output "WARN: libcdsprpc.dll not found at $fastrpc" }

Write-Output "=== staged to $dst ==="
Get-ChildItem $dst -Include *.so,*.cat,libcdsprpc.dll,ggml-hexagon.dll,ggml-rpc-server.exe,llama-bench.exe,llama-cli.exe,llama-server.exe -Recurse |
    Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize

Write-Output "=== catalog signature ==="
$signtool = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\arm64\signtool.exe"
if (Test-Path "$dst\libggml-htp.cat") {
    & $signtool verify /v /pa "$dst\libggml-htp.cat" 2>&1 | Out-String
} else {
    Write-Output "ERROR: libggml-htp.cat was NOT produced -- HTP ops libs will not load."
}
