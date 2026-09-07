param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [Parameter(Mandatory = $true)][string]$TimestampUrl
)

. "$PSScriptRoot\Signing.Common.ps1"

$cert = Get-CodeSigningCertificate $Thumbprint
Write-Host "[powershell] Signing: $File"
$result = Set-AuthenticodeSignature `
    -LiteralPath $File `
    -Certificate $cert `
    -TimestampServer $TimestampUrl `
    -HashAlgorithm SHA256

if ($result.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
    throw "PowerShell Authenticode signing failed for '$File': $($result.Status) - $($result.StatusMessage)"
}

$verify = Get-AuthenticodeSignature -LiteralPath $File
if ($verify.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
    throw "PowerShell Authenticode verification failed for '$File': $($verify.Status) - $($verify.StatusMessage)"
}

Write-Host "[powershell] Verified: $File"
