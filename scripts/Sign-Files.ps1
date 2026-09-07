param(
    [Parameter(Mandatory = $true)]
    [string]$FileSpecs,

    [Parameter(Mandatory = $true)]
    [string]$Thumbprint,

    [Parameter(Mandatory = $false)]
    [string]$TimestampUrl = 'http://timestamp.certum.pl'
)

$ErrorActionPreference = 'Stop'

function Find-SignTool {
    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "$env:ProgramFiles\Windows Kits\10\bin"
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $roots) {
        $tool = Get-ChildItem -Path $root -Filter signtool.exe -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($tool) { return $tool.FullName }
    }

    throw 'signtool.exe was not found. Use a GitHub Windows runner with the Windows SDK installed.'
}

function Resolve-SignTargets {
    param([string]$Specs)

    $items = $Specs -split '[;\r\n]+' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }

    $targets = New-Object System.Collections.Generic.List[string]

    foreach ($item in $items) {
        if (Test-Path -LiteralPath $item -PathType Leaf) {
            $targets.Add((Resolve-Path -LiteralPath $item).Path)
            continue
        }

        $matches = Get-ChildItem -Path $item -File -ErrorAction SilentlyContinue
        foreach ($match in $matches) {
            $targets.Add($match.FullName)
        }
    }

    return $targets | Select-Object -Unique
}

$signtool = Find-SignTool
$thumbprint = ($Thumbprint -replace '\s','').ToUpperInvariant()
$targets = @(Resolve-SignTargets -Specs $FileSpecs)

if ($targets.Count -eq 0) {
    throw "No signing targets matched: $FileSpecs"
}

Write-Host "Using SignTool: $signtool"
Write-Host "Signing $($targets.Count) file(s)."

foreach ($file in $targets) {
    Write-Host "Signing: $file"
    & $signtool sign `
        /sha1 $thumbprint `
        /fd SHA256 `
        /tr $TimestampUrl `
        /td SHA256 `
        $file

    if ($LASTEXITCODE -ne 0) {
        throw "SignTool failed while signing '$file' (exit code $LASTEXITCODE)."
    }

    Write-Host "Verifying: $file"
    & $signtool verify /pa /v $file

    if ($LASTEXITCODE -ne 0) {
        throw "Authenticode verification failed for '$file' (exit code $LASTEXITCODE)."
    }
}

Write-Host 'All files were signed and verified successfully.'
