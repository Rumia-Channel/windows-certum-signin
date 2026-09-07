param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [Parameter(Mandatory = $true)][string]$TimestampUrl
)

. "$PSScriptRoot\Signing.Common.ps1"

$mage = Find-Mage
$thumbprint = Normalize-Thumbprint $Thumbprint

function Sign-Manifest {
    param([Parameter(Mandatory = $true)][string]$Manifest)
    Write-Host "[clickonce] Signing: $Manifest"
    Invoke-Checked $mage @('-Sign', $Manifest, '-CertHash', $thumbprint, '-TimestampUri', $TimestampUrl) "Mage sign '$Manifest'"
    Invoke-Checked $mage @('-Verify', $Manifest) "Mage verify '$Manifest'"
}

$ext = [IO.Path]::GetExtension($File).ToLowerInvariant()
if ($ext -eq '.manifest') {
    Sign-Manifest $File
    return
}

if ($ext -notin @('.application', '.vsto')) {
    throw "ClickOnce signer expects .manifest, .application, or .vsto, got '$File'."
}

# For a deployment manifest, locate its referenced application manifest when it is local.
# Signing the application manifest changes its hash, so the deployment manifest must then be
# updated with -AppManifest before the deployment manifest itself is signed.
$appManifest = $null
try {
    [xml]$xml = Get-Content -LiteralPath $File -Raw
    $node = $xml.SelectSingleNode("//*[local-name()='dependentAssembly' and @codebase]")
    if ($node -and $node.codebase) {
        $codebase = [Uri]::UnescapeDataString([string]$node.codebase)
        if (-not [Uri]::IsWellFormedUriString($codebase, [UriKind]::Absolute)) {
            $candidate = Join-Path (Split-Path -Parent $File) ($codebase -replace '/', '\')
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $appManifest = (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }
} catch {
    Write-Warning "Could not inspect ClickOnce deployment manifest '$File': $($_.Exception.Message)"
}

if ($appManifest) {
    Sign-Manifest $appManifest
    Write-Host "[clickonce] Updating deployment manifest reference/hash from: $appManifest"
    Invoke-Checked $mage @('-Update', $File, '-AppManifest', $appManifest) "Mage update '$File'"
} else {
    Write-Warning 'Referenced application manifest was not found locally. Signing only the deployment manifest.'
}

Sign-Manifest $File
