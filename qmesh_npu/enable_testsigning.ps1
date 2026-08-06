$ErrorActionPreference = 'Continue'
$log = "C:\Users\qc_de\OneDrive\Documents\QMesh_AI\qmesh_npu\testsigning.log"
"=== testsigning $(Get-Date -Format o) ===" | Set-Content $log

"--- secure boot state ---" | Add-Content $log
try { "SecureBootEnabled = $(Confirm-SecureBootUEFI)" | Add-Content $log }
catch { "SecureBoot query failed: $($_.Exception.Message)" | Add-Content $log }

"--- device guard / VBS ---" | Add-Content $log
try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
    "VBS status = $($dg.VirtualizationBasedSecurityStatus)" | Add-Content $log
    "CI policy enforcement = $($dg.CodeIntegrityPolicyEnforcementStatus)" | Add-Content $log
} catch { "DeviceGuard query n/a" | Add-Content $log }

"--- before ---" | Add-Content $log
(bcdedit /enum "{current}" | Out-String) | Add-Content $log

"--- setting TESTSIGNING ON ---" | Add-Content $log
(bcdedit /set "{current}" testsigning on 2>&1 | Out-String) | Add-Content $log
"bcdedit exit: $LASTEXITCODE" | Add-Content $log

"--- after ---" | Add-Content $log
(bcdedit /enum "{current}" | Out-String) | Add-Content $log
"=== done ===" | Add-Content $log
