param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [Parameter(Mandatory = $true)][string]$TimestampUrl
)

. "$PSScriptRoot\Signing.Common.ps1"

$dotnet = Resolve-CommandPath @('dotnet.exe', 'dotnet')
if (-not $dotnet) {
    throw 'dotnet was not found. NuGet signing requires .NET SDK 6 or later.'
}

$cert = Get-CodeSigningCertificate $Thumbprint
$sha1 = Normalize-Thumbprint $cert.Thumbprint
$sha256 = Get-CertificateSha256Fingerprint $cert
$version = (& $dotnet --version).Trim()
$major = 0
if ($version -match '^(\d+)\.') { $major = [int]$matches[1] }

# .NET 9+ accepts SHA-2 fingerprints. .NET 10 rejects SHA-1 for package signing.
$fingerprint = if ($major -ge 9) { $sha256 } else { $sha1 }

Write-Host "[nuget] Signing: $File (dotnet $version, fingerprint: $(if ($major -ge 9) { 'SHA-256' } else { 'SHA-1' }))"
Invoke-Checked $dotnet @(
    'nuget', 'sign', $File,
    '--certificate-store-location', 'CurrentUser',
    '--certificate-store-name', 'My',
    '--certificate-fingerprint', $fingerprint,
    '--hash-algorithm', 'SHA256',
    '--timestamp-hash-algorithm', 'SHA256',
    '--timestamper', $TimestampUrl,
    '--overwrite'
) "dotnet nuget sign '$File'"

Write-Host "[nuget] Verifying: $File"
Invoke-Checked $dotnet @(
    'nuget', 'verify', $File,
    '--all',
    '--certificate-fingerprint', $sha256
) "dotnet nuget verify '$File'"
