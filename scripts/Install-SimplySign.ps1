param(
    [Parameter(Mandatory = $true)]
    [string]$Url
)

$ErrorActionPreference = 'Stop'

$installPath = Join-Path $env:ProgramFiles 'Certum\SimplySign Desktop'
$exePath = Join-Path $installPath 'SimplySignDesktop.exe'

if (Test-Path $exePath) {
    Write-Host "SimplySign Desktop is already installed: $exePath"
    "SS_PATH=$installPath" >> $env:GITHUB_ENV
    exit 0
}

$msi = Join-Path $env:RUNNER_TEMP 'SimplySignDesktop.msi'
$log = Join-Path $env:RUNNER_TEMP 'SimplySignDesktop-install.log'

Write-Host 'Downloading SimplySign Desktop...'
Invoke-WebRequest -Uri $Url -OutFile $msi -UseBasicParsing

if (-not (Test-Path $msi)) {
    throw 'SimplySign installer download failed.'
}

Write-Host 'Installing SimplySign Desktop silently...'
$arguments = @(
    '/i', "`"$msi`"",
    '/quiet',
    '/norestart',
    '/l*v', "`"$log`"",
    'ALLUSERS=1',
    'REBOOT=ReallySuppress'
)

$process = Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru
if ($process.ExitCode -notin @(0, 3010)) {
    if (Test-Path $log) {
        Get-Content $log -Tail 40 | Out-Host
    }
    throw "SimplySign Desktop installation failed with MSI exit code $($process.ExitCode)."
}

Start-Sleep -Seconds 2

if (-not (Test-Path $exePath)) {
    if (Test-Path $log) {
        Get-Content $log -Tail 40 | Out-Host
    }
    throw "SimplySign Desktop executable was not found after installation: $exePath"
}

Write-Host "SimplySign Desktop installed: $exePath"
"SS_PATH=$installPath" >> $env:GITHUB_ENV
