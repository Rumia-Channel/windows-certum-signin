param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [Parameter(Mandatory = $true)][string]$TimestampUrl,
    [Parameter(Mandatory = $true)][string]$OfficeSipsPath
)

. "$PSScriptRoot\Signing.Common.ps1"

$accessExtensions = @('.accdb', '.accde', '.mdb', '.mde')
$ext = [IO.Path]::GetExtension($File).ToLowerInvariant()
if ($ext -in $accessExtensions) {
    throw 'Microsoft SignTool + Office SIP does not support Microsoft Access VBA projects.'
}

if (-not $OfficeSipsPath) {
    throw 'Office VBA signing requires office-sips-path pointing to the extracted x86 Microsoft Office Subject Interface Package.'
}

$resolvedSips = (Resolve-Path -LiteralPath $OfficeSipsPath -ErrorAction Stop).Path
$msosip = Join-Path $resolvedSips 'msosip.dll'
$msosipx = Join-Path $resolvedSips 'msosipx.dll'
$vbe = Join-Path $resolvedSips 'vbe7.dll'
$offsign = Join-Path $resolvedSips 'offsign.bat'
$offclear = Join-Path $resolvedSips 'offclearsig.exe'

foreach ($required in @($msosip, $msosipx, $vbe, $offsign, $offclear)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required Office SIP component was not found: $required"
    }
}

# Register the x86 SIPs because Microsoft's Offsign workflow requires x86 SignTool.
$regsvr32 = "$env:windir\SysWOW64\regsvr32.exe"
if (-not (Test-Path -LiteralPath $regsvr32)) {
    throw "x86 regsvr32.exe was not found at '$regsvr32'."
}

# Offsign uses x86 SignTool, so write the VBA discovery value into the 32-bit
# HKLM registry view explicitly rather than relying on PowerShell process bitness.
$baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
    [Microsoft.Win32.RegistryHive]::LocalMachine,
    [Microsoft.Win32.RegistryView]::Registry32
)
try {
    $vbaKey = $baseKey.CreateSubKey('SOFTWARE\Microsoft\VBA')
    try {
        $vbaKey.SetValue('Vbe71DllPath', $vbe, [Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        if ($vbaKey) { $vbaKey.Dispose() }
    }
} finally {
    $baseKey.Dispose()
}

Invoke-Checked $regsvr32 @('/s', $msosip) "Register msosip.dll"
Invoke-Checked $regsvr32 @('/s', $msosipx) "Register msosipx.dll"

$signtool = Find-SignTool -Architecture x86
$signtoolDir = (Split-Path -Parent $signtool).TrimEnd('\') + '\'
$thumbprint = Normalize-Thumbprint $Thumbprint
$signArgs = "sign /sha1 $thumbprint /fd SHA256 /tr `"$TimestampUrl`" /td SHA256"
$verifyArgs = 'verify /pa /v'

Write-Host "[office-vba] Signing VBA project: $File"
& $offsign $signtoolDir $signArgs $verifyArgs $File
if ($LASTEXITCODE -ne 0) {
    throw "Office Offsign.bat failed for '$File' with exit code $LASTEXITCODE."
}

Write-Host "[office-vba] Verifying: $File"
Invoke-Checked $signtool @('verify', '/pa', '/v', $File) "Office VBA SignTool verify '$File'"
