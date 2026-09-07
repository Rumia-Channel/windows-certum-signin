param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [Parameter(Mandatory = $true)][string]$TimestampUrl,
    [Parameter(Mandatory = $false)][string]$OutputFile = '',
    [Parameter(Mandatory = $false)][string]$AdtPath = ''
)

. "$PSScriptRoot\Signing.Common.ps1"

function Resolve-Adt {
    param([string]$Requested)

    if ($Requested) {
        if (Test-Path -LiteralPath $Requested -PathType Leaf) {
            return (Resolve-Path -LiteralPath $Requested).Path
        }
        throw "AIR ADT executable was not found: $Requested"
    }

    $fromPath = Resolve-CommandPath @('adt.bat', 'adt.cmd', 'adt')
    if ($fromPath) { return $fromPath }

    if ($env:AIR_HOME) {
        foreach ($candidate in @(
            (Join-Path $env:AIR_HOME 'bin\adt.bat'),
            (Join-Path $env:AIR_HOME 'bin\adt')
        )) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }

    throw 'AIR ADT was not found. Put AIR SDK bin on PATH, set AIR_HOME, or pass air-adt-path.'
}

$adt = Resolve-Adt $AdtPath
$keytool = Resolve-CommandPath @('keytool.exe', 'keytool')
if (-not $keytool) {
    throw 'keytool was not found. AIR signing via Windows-MY requires a JDK.'
}

$cert = Get-CodeSigningCertificate $Thumbprint
$alias = Get-JavaAliasForFingerprint `
    -KeyTool $keytool `
    -Arguments @('-J-Duser.language=en', '-J-Duser.country=US', '-list', '-v', '-storetype', 'Windows-MY') `
    -Thumbprint $cert.Thumbprint

$ext = [IO.Path]::GetExtension($File).ToLowerInvariant()
if ($ext -eq '.air') {
    throw 'An existing .air package cannot be re-signed with ADT -sign. Sign an .airi input, or use ADT migration when rotating certificates.'
}

$target = $null
$replaceInput = $false
switch ($ext) {
    '.airi' { $target = 'air' }
    '.ane'  { $target = 'ane'; $replaceInput = -not $OutputFile }
    '.airn' { $target = 'airn'; $replaceInput = -not $OutputFile }
    default { throw "AIR signer expects .airi, .ane, or .airn, got '$File'." }
}

if (-not $OutputFile) {
    if ($ext -eq '.airi') {
        $OutputFile = [IO.Path]::ChangeExtension($File, '.air')
    } else {
        $OutputFile = Join-Path ([IO.Path]::GetDirectoryName($File)) (([IO.Path]::GetFileNameWithoutExtension($File)) + '.signed' + $ext)
    }
}

$OutputFile = [IO.Path]::GetFullPath($OutputFile)
Write-Host "[air] Signing: $File -> $OutputFile (target: $target, alias: $alias)"
Invoke-Checked $adt @(
    '-sign',
    '-storetype', 'Windows-MY',
    '-alias', $alias,
    '-tsa', $TimestampUrl,
    '-target', $target,
    $File,
    $OutputFile
) "ADT sign '$File'"

if (-not (Test-Path -LiteralPath $OutputFile -PathType Leaf)) {
    throw "ADT reported success but output was not created: $OutputFile"
}

if ($replaceInput) {
    Move-Item -LiteralPath $OutputFile -Destination $File -Force
    Write-Host "[air] Replaced signed package in place: $File"
} else {
    Write-Host "[air] Signed output: $OutputFile"
}
