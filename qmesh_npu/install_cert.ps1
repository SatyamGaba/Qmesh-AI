$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot   # derive from script location so the tree can be relocated
$cer  = "$root\certs\ggml-htp-v1.cer"
$log  = "$root\install_cert.log"

"=== install_cert $(Get-Date -Format o) ===" | Set-Content $log

# 1. Confirm TESTSIGNING actually took effect after the 12:15 reboot.
"--- bcdedit ---" | Add-Content $log
(& bcdedit /enum "{current}" 2>&1 | Out-String) | Add-Content $log

# 2. Trust the HTP signing cert machine-wide so the signed libggml-htp.cat
#    chains to a trusted root (required for FastRPC to load the DSP ops libs).
#    Public cert only -- the private key stays in the .pfx.
foreach ($store in @('Root','TrustedPublisher')) {
    "--- importing into LocalMachine\$store ---" | Add-Content $log
    try {
        $r = Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\$store" -ErrorAction Stop
        "OK: $($r.Subject) / $($r.Thumbprint)" | Add-Content $log
    } catch {
        "FAILED: $($_.Exception.Message)" | Add-Content $log
    }
}

"--- verify ---" | Add-Content $log
foreach ($store in @('Root','TrustedPublisher')) {
    $c = Get-ChildItem "Cert:\LocalMachine\$store" | Where-Object { $_.Subject -eq 'CN=GGML.HTP.v1' }
    if ($c) { "$store : PRESENT ($($c.Thumbprint))" | Add-Content $log }
    else    { "$store : MISSING" | Add-Content $log }
}
"=== done ===" | Add-Content $log
