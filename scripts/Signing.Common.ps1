$ErrorActionPreference = 'Stop'

function Normalize-Thumbprint {
    param([Parameter(Mandatory = $true)][string]$Thumbprint)
    return ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
}

function Get-CodeSigningCertificate {
    param([Parameter(Mandatory = $true)][string]$Thumbprint)

    $normalized = Normalize-Thumbprint $Thumbprint
    $cert = Get-ChildItem Cert:\CurrentUser\My -ErrorAction Stop |
        Where-Object { (Normalize-Thumbprint $_.Thumbprint) -eq $normalized } |
        Select-Object -First 1

    if (-not $cert) {
        throw "Code-signing certificate '$normalized' was not found in Cert:\CurrentUser\My."
    }

    return $cert
}

function Resolve-CommandPath {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    foreach ($name in $Names) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }

    return $null
}

function Find-SignTool {
    param([ValidateSet('x64', 'x86')][string]$Architecture = 'x64')

    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "$env:ProgramFiles\Windows Kits\10\bin"
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $roots) {
        $tool = Get-ChildItem -Path $root -Filter signtool.exe -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "\\$Architecture\\signtool\.exe$" } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($tool) { return $tool.FullName }
    }

    throw "signtool.exe ($Architecture) was not found. Use a Windows runner with the Windows SDK installed."
}

function Find-Mage {
    $fromPath = Resolve-CommandPath @('mage.exe', 'mage')
    if ($fromPath) { return $fromPath }

    $roots = @(
        "${env:ProgramFiles(x86)}\Microsoft SDKs\Windows",
        "$env:ProgramFiles\Microsoft SDKs\Windows",
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $roots) {
        $tool = Get-ChildItem -Path $root -Filter mage.exe -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($tool) { return $tool.FullName }
    }

    throw 'Mage.exe was not found. Install Visual Studio/Windows SDK components that include ClickOnce Mage.exe.'
}

function Resolve-FileSpecs {
    param([Parameter(Mandatory = $true)][string]$Specs)

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

    return @($targets | Select-Object -Unique)
}

function Get-CertificateSha256Fingerprint {
    param([Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Certificate.RawData)) -replace '-', '')
    } finally {
        $sha.Dispose()
    }
}

function Convert-CertificateToPem {
    param([Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    $base64 = [Convert]::ToBase64String($Certificate.RawData)
    $lines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $base64.Length; $i += 64) {
        $length = [Math]::Min(64, $base64.Length - $i)
        $lines.Add($base64.Substring($i, $length))
    }

    return "-----BEGIN CERTIFICATE-----`n$($lines -join "`n")`n-----END CERTIFICATE-----"
}

function Write-CertificateChainPem {
    param(
        [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
    [void]$chain.Build($Certificate)

    $blocks = New-Object System.Collections.Generic.List[string]
    foreach ($element in $chain.ChainElements) {
        $c = $element.Certificate
        if ($chain.ChainElements.Count -gt 1 -and $c.Subject -eq $c.Issuer) {
            continue
        }
        $blocks.Add((Convert-CertificateToPem $c))
    }

    if ($blocks.Count -eq 0) {
        $blocks.Add((Convert-CertificateToPem $Certificate))
    }

    Set-Content -LiteralPath $Path -Value ($blocks -join "`n") -Encoding ascii
}

function Get-JavaAliasForFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$KeyTool,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Thumbprint
    )

    $normalized = Normalize-Thumbprint $Thumbprint
    $output = & $KeyTool @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "keytool failed while enumerating the keystore:`n$($output -join "`n")"
    }

    $currentAlias = $null
    $aliases = New-Object System.Collections.Generic.List[string]

    foreach ($lineObject in $output) {
        $line = [string]$lineObject
        if ($line -match '^\s*Alias name:\s*(.+?)\s*$') {
            $currentAlias = $matches[1].Trim()
            if ($currentAlias) { $aliases.Add($currentAlias) }
            continue
        }

        if ($line -match '^\s*SHA1:\s*([0-9A-Fa-f: ]+)\s*$') {
            $fingerprint = Normalize-Thumbprint $matches[1]
            if ($currentAlias -and $fingerprint -eq $normalized) {
                return $currentAlias
            }
        }
    }

    # Certum's PKCS#11 listing may use a compact "alias, PrivateKeyEntry" form.
    if ($aliases.Count -eq 0) {
        foreach ($lineObject in $output) {
            $line = [string]$lineObject
            if ($line -match '^\s*([^,]+),\s*PrivateKeyEntry\s*,?') {
                $candidate = $matches[1].Trim()
                if ($candidate) { $aliases.Add($candidate) }
            }
        }
    }

    $unique = @($aliases | Select-Object -Unique)
    if ($unique.Count -eq 1) {
        Write-Warning "Could not correlate SHA-1 fingerprint from keytool output; using the only available alias '$($unique[0])'."
        return $unique[0]
    }

    throw "Could not find a Java keystore alias matching certificate SHA-1 '$normalized'."
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][string[]]$Arguments = @(),
        [Parameter(Mandatory = $false)][string]$Description = $FilePath
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}
