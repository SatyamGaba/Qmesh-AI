$ErrorActionPreference = 'Continue'
$log = "C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\wdk_install.log"
"=== START $(Get-Date -Format o) ===" | Set-Content $log

"--- installing Windows SDK 10.0.26100 ---" | Add-Content $log
winget install --id Microsoft.WindowsSDK.10.0.26100 --exact --silent `
    --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 |
    Out-String | Add-Content $log
"SDK exit: $LASTEXITCODE" | Add-Content $log

"--- installing Windows Driver Kit 10.0.26100 ---" | Add-Content $log
winget install --id Microsoft.WindowsWDK.10.0.26100 --exact --silent `
    --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 |
    Out-String | Add-Content $log
"WDK exit: $LASTEXITCODE" | Add-Content $log

"--- searching for inf2cat.exe ---" | Add-Content $log
$found = Get-ChildItem "C:\Program Files (x86)\Windows Kits" -Recurse -Filter "inf2cat.exe" -ErrorAction SilentlyContinue
if ($found) { $found | ForEach-Object { "FOUND: $($_.FullName)" | Add-Content $log } }
else { "inf2cat.exe STILL NOT FOUND" | Add-Content $log }
"=== DONE $(Get-Date -Format o) ===" | Add-Content $log
