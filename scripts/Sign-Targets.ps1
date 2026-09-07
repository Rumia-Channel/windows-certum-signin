param(
    [Parameter(Mandatory = $false)][string]$FileSpecs = '',
    [Parameter(Mandatory = $false)][string]$Signer = 'auto',
    [Parameter(Mandatory = $false)][string]$TargetSpecs = '',
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [Parameter(Mandatory = $false)][string]$TimestampUrl = 'http://time.certum.pl',
    [Parameter(Mandatory = $false)][int]$JavaPkcs11Slot = 0,
    [Parameter(Mandatory = $false)][string]$JavaPkcs11Pin = '12345678',
    [Parameter(Mandatory = $false)][string]$OfficeSipsPath = '',
    [Parameter(Mandatory = $false)][string]$AirAdtPath = ''
)

. "$PSScriptRoot\Signing.Common.ps1"

$authenticodeExtensions = @(
    '.exe', '.dll', '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle',
    '.cab', '.ocx', '.cpl', '.scr', '.com'
)
$powerShellExtensions = @('.ps1', '.psm1', '.psd1', '.ps1xml', '.cdxml', '.xaml')
$javaExtensions = @('.jar', '.war', '.ear')
$officeExtensions = @(
    '.xla', '.xls', '.xlt',
    '.pot', '.ppa', '.pps', '.ppt',
    '.mpp', '.mpt', '.pub',
    '.vdw', '.vdx', '.vsd', '.vss', '.vst', '.vsx', '.vtx',
    '.doc', '.dot', '.wiz',
    '.xlam', '.xlsb', '.xlsm', '.xltm',
    '.potm', '.ppam', '.ppsm', '.pptm',
    '.vsdm', '.vssm', '.vstm',
    '.docm', '.dotm'
)

function Normalize-SignerName {
    param([string]$Name)
    switch ($Name.Trim().ToLowerInvariant()) {
        'auto' { return 'auto' }
        'authenticode' { return 'authenticode' }
        'signtool' { return 'authenticode' }
        'windows' { return 'authenticode' }
        'powershell' { return 'powershell' }
        'ps' { return 'powershell' }
        'java' { return 'java' }
        'jar' { return 'java' }
        'jarsigner' { return 'java' }
        'nuget' { return 'nuget' }
        'nupkg' { return 'nuget' }
        'clickonce' { return 'clickonce' }
        'mage' { return 'clickonce' }
        'office-vba' { return 'office-vba' }
        'office' { return 'office-vba' }
        'vba' { return 'office-vba' }
        'air' { return 'air' }
        'adt' { return 'air' }
        default { throw "Unknown signer '$Name'." }
    }
}

function Get-AutoSigner {
    param([string]$File)
    $ext = [IO.Path]::GetExtension($File).ToLowerInvariant()

    if ($ext -eq '.sys') {
        throw "Driver signing is intentionally unsupported: $File"
    }
    if ($ext -eq '.cat') {
        throw "Catalog files (.cat) are ambiguous and frequently driver-related. Use an explicit 'authenticode::path.cat' target only for a non-driver catalog."
    }
    if ($ext -in $authenticodeExtensions) { return 'authenticode' }
    if ($ext -in $powerShellExtensions) { return 'powershell' }
    if ($ext -in $javaExtensions) { return 'java' }
    if ($ext -eq '.nupkg') { return 'nuget' }
    if ($ext -in @('.manifest', '.application', '.vsto')) { return 'clickonce' }
    if ($ext -in $officeExtensions) { return 'office-vba' }
    if ($ext -in @('.airi', '.ane', '.airn', '.air')) { return 'air' }

    throw "No automatic signer is registered for '$File' ($ext). Use targets with an explicit signer."
}

function Invoke-Signer {
    param(
        [string]$Kind,
        [string]$File,
        [string]$Output = ''
    )

    $kind = Normalize-SignerName $Kind
    if ($kind -eq 'auto') { $kind = Get-AutoSigner $File }

    Write-Host "Dispatch: $kind -> $File"
    switch ($kind) {
        'authenticode' {
            & "$PSScriptRoot\Sign-Authenticode.ps1" -File $File -Thumbprint $Thumbprint -TimestampUrl $TimestampUrl
        }
        'powershell' {
            & "$PSScriptRoot\Sign-PowerShell.ps1" -File $File -Thumbprint $Thumbprint -TimestampUrl $TimestampUrl
        }
        'java' {
            & "$PSScriptRoot\Sign-Java.ps1" -File $File -Thumbprint $Thumbprint -TimestampUrl $TimestampUrl -Pkcs11Slot $JavaPkcs11Slot -Pkcs11Pin $JavaPkcs11Pin
        }
        'nuget' {
            & "$PSScriptRoot\Sign-NuGet.ps1" -File $File -Thumbprint $Thumbprint -TimestampUrl $TimestampUrl
        }
        'clickonce' {
            & "$PSScriptRoot\Sign-ClickOnce.ps1" -File $File -Thumbprint $Thumbprint -TimestampUrl $TimestampUrl
        }
        'office-vba' {
            & "$PSScriptRoot\Sign-OfficeVba.ps1" -File $File -Thumbprint $Thumbprint -TimestampUrl $TimestampUrl -OfficeSipsPath $OfficeSipsPath
        }
        'air' {
            & "$PSScriptRoot\Sign-Air.ps1" -File $File -Thumbprint $Thumbprint -TimestampUrl $TimestampUrl -OutputFile $Output -AdtPath $AirAdtPath
        }
    }
}

$work = New-Object System.Collections.Generic.List[object]

if ($FileSpecs) {
    $globalSigner = Normalize-SignerName $Signer
    foreach ($file in (Resolve-FileSpecs $FileSpecs)) {
        $work.Add([pscustomobject]@{ Signer = $globalSigner; File = $file; Output = '' })
    }
}

if ($TargetSpecs) {
    $lines = $TargetSpecs -split '[\r\n]+' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }

    foreach ($line in $lines) {
        $kind = 'auto'
        $payload = $line
        if ($line -match '^([A-Za-z0-9_-]+)::(.+)$') {
            $kind = Normalize-SignerName $matches[1]
            $payload = $matches[2].Trim()
        }

        $output = ''
        if ($kind -eq 'air' -and $payload -match '^(.*?)=>(.+)$') {
            $payload = $matches[1].Trim()
            $output = $matches[2].Trim()
        }

        $resolved = @(Resolve-FileSpecs $payload)
        if ($resolved.Count -eq 0) {
            throw "No signing targets matched: $payload"
        }
        if ($output -and $resolved.Count -ne 1) {
            throw "AIR output override requires exactly one input file: $line"
        }

        foreach ($file in $resolved) {
            $work.Add([pscustomobject]@{ Signer = $kind; File = $file; Output = $output })
        }
    }
}

if ($work.Count -eq 0) {
    Write-Host 'No signing targets were provided; setup/authentication only.'
    return
}

$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($item in $work) {
    $key = "$($item.Signer)|$($item.File)|$($item.Output)"
    if (-not $seen.Add($key)) { continue }
    Invoke-Signer -Kind $item.Signer -File $item.File -Output $item.Output
}

Write-Host "Completed signing dispatch for $($seen.Count) target(s)."
