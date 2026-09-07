$ErrorActionPreference = 'Stop'

$registryPath = 'HKCU:\Software\Certum\SimplySign'
$settings = [ordered]@{
    ShowLoginDialogOnStart              = 1
    ShowLoginDialogOnAppRequest         = 1
    RememberLastUserName                = 1
    Autostart                           = 0
    UnregisterCertificatesOnDisconnect  = 0
    RememberPINinCSP                    = 1
    ForgetPINinCSPonDisconnect          = 1
    LangID                              = 9
}

if (-not (Test-Path 'HKCU:\Software\Certum')) {
    New-Item -Path 'HKCU:\Software\Certum' -Force | Out-Null
}
if (-not (Test-Path $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}

foreach ($entry in $settings.GetEnumerator()) {
    New-ItemProperty `
        -Path $registryPath `
        -Name $entry.Key `
        -PropertyType DWord `
        -Value ([int]$entry.Value) `
        -Force | Out-Null
}

foreach ($entry in $settings.GetEnumerator()) {
    $actual = (Get-ItemProperty -Path $registryPath -Name $entry.Key).($entry.Key)
    if ([int]$actual -ne [int]$entry.Value) {
        throw "Failed to configure SimplySign registry value '$($entry.Key)'."
    }
}

Write-Host 'SimplySign registry configuration applied.'
