# Backward-compatible wrapper. New code should use Sign-Targets.ps1 or the composite action inputs.
param(
    [Parameter(Mandatory = $true)][string]$FileSpecs,
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [Parameter(Mandatory = $false)][string]$TimestampUrl = 'http://time.certum.pl',
    [Parameter(Mandatory = $false)][string]$Signer = 'auto'
)

& "$PSScriptRoot\Sign-Targets.ps1" `
    -FileSpecs $FileSpecs `
    -Signer $Signer `
    -Thumbprint $Thumbprint `
    -TimestampUrl $TimestampUrl
