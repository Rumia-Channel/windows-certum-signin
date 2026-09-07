param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [Parameter(Mandatory = $true)][string]$TimestampUrl,
    [Parameter(Mandatory = $false)][int]$Pkcs11Slot = 0,
    [Parameter(Mandatory = $false)][string]$Pkcs11Pin = '12345678'
)

. "$PSScriptRoot\Signing.Common.ps1"

$jarsigner = Resolve-CommandPath @('jarsigner.exe', 'jarsigner')
$keytool = Resolve-CommandPath @('keytool.exe', 'keytool')
if (-not $jarsigner -or -not $keytool) {
    throw 'jarsigner/keytool were not found. Install a JDK or use actions/setup-java before this action.'
}

$pkcs = 'C:\Windows\System32\SimplySignPKCS.dll'
if (-not (Test-Path -LiteralPath $pkcs)) {
    throw "SimplySign PKCS#11 library was not found at '$pkcs'."
}

$cert = Get-CodeSigningCertificate $Thumbprint
$tempDir = Join-Path $env:RUNNER_TEMP ("certum-java-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$provider = Join-Path $tempDir 'provider.cfg'
$chainPem = Join-Path $tempDir 'bundle.pem'

try {
    @(
        'name=SimplySignPKCS'
        "library=$pkcs"
        "slotListIndex=$Pkcs11Slot"
    ) | Set-Content -LiteralPath $provider -Encoding ascii

    Write-CertificateChainPem -Certificate $cert -Path $chainPem

    $keytoolArgs = @(
        '-J-Duser.language=en',
        '-J-Duser.country=US',
        '-list', '-v',
        '-keystore', 'NONE',
        '-storetype', 'PKCS11',
        '-providerclass', 'sun.security.pkcs11.SunPKCS11',
        '-providerarg', $provider,
        '-storepass', $Pkcs11Pin
    )
    $alias = Get-JavaAliasForFingerprint -KeyTool $keytool -Arguments $keytoolArgs -Thumbprint $cert.Thumbprint

    Write-Host "[java] Signing: $File (alias: $alias, slot: $Pkcs11Slot)"
    Invoke-Checked $jarsigner @(
        '-J-Duser.language=en',
        '-J-Duser.country=US',
        '-keystore', 'NONE',
        '-storetype', 'PKCS11',
        '-providerClass', 'sun.security.pkcs11.SunPKCS11',
        '-providerArg', $provider,
        '-storepass', $Pkcs11Pin,
        '-certchain', $chainPem,
        '-sigalg', 'SHA256withRSA',
        '-digestalg', 'SHA-256',
        '-tsa', $TimestampUrl,
        $File,
        $alias
    ) "jarsigner sign '$File'"

    Write-Host "[java] Verifying: $File"
    Invoke-Checked $jarsigner @('-verify', '-strict', '-verbose', '-certs', $File) "jarsigner verify '$File'"
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
