param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [Parameter(Mandatory = $true)][string]$TimestampUrl
)

. "$PSScriptRoot\Signing.Common.ps1"

$ext = [IO.Path]::GetExtension($File).ToLowerInvariant()
if ($ext -eq '.sys') {
    throw 'Driver (.sys) signing is intentionally not supported by this action.'
}

$signtool = Find-SignTool -Architecture x64
$thumbprint = Normalize-Thumbprint $Thumbprint

Write-Host "[authenticode] Signing: $File"
Invoke-Checked $signtool @(
    'sign',
    '/sha1', $thumbprint,
    '/fd', 'SHA256',
    '/tr', $TimestampUrl,
    '/td', 'SHA256',
    $File
) "SignTool sign '$File'"

Write-Host "[authenticode] Verifying: $File"
Invoke-Checked $signtool @('verify', '/pa', '/v', $File) "SignTool verify '$File'"
