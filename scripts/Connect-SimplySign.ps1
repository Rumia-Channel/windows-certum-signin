param(
    [string]$OtpUri = $env:CERTUM_OTP_URI,
    [string]$UserId = $env:CERTUM_USERNAME,
    [string]$KeyId = $env:CERTUM_KEY_ID,
    [string]$InstallPath = $env:SS_PATH
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OtpUri)) { throw 'CERTUM_OTP_URI is required.' }
if ([string]::IsNullOrWhiteSpace($UserId)) { throw 'CERTUM_USERNAME is required.' }
if ([string]::IsNullOrWhiteSpace($KeyId)) { throw 'CERTUM_KEY_ID is required.' }

if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    $InstallPath = Join-Path $env:ProgramFiles 'Certum\SimplySign Desktop'
}
$exePath = Join-Path $InstallPath 'SimplySignDesktop.exe'
if (-not (Test-Path $exePath)) {
    throw "SimplySign Desktop was not found: $exePath"
}

$thumbprint = ($KeyId -replace '\s','').ToUpperInvariant()

function Get-SigningCertificate {
    Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { ($_.Thumbprint -replace '\s','').ToUpperInvariant() -eq $thumbprint } |
        Select-Object -First 1
}

# Parse the otpauth:// URI without ever logging it or its secret.
$uri = [Uri]$OtpUri
if ($uri.Scheme -ne 'otpauth') {
    throw 'CERTUM_OTP_URI must be an otpauth:// URI.'
}

try {
    Add-Type -AssemblyName System.Web -ErrorAction Stop
    $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
} catch {
    $query = @{}
    foreach ($part in $uri.Query.TrimStart('?') -split '&') {
        $kv = $part -split '=', 2
        if ($kv.Count -eq 2) {
            $query[$kv[0]] = [Uri]::UnescapeDataString($kv[1])
        }
    }
}

$base32 = $query['secret']
if ([string]::IsNullOrWhiteSpace($base32)) {
    throw 'The otpauth:// URI does not contain a TOTP secret.'
}

$digits = if ($query['digits']) { [int]$query['digits'] } else { 6 }
$period = if ($query['period']) { [int]$query['period'] } else { 30 }
$algorithm = if ($query['algorithm']) { $query['algorithm'].ToUpperInvariant() } else { 'SHA1' }

if ($algorithm -notin @('SHA1', 'SHA256', 'SHA512')) {
    throw "Unsupported TOTP algorithm: $algorithm"
}

Add-Type -Language CSharp @"
using System;
using System.Security.Cryptography;

public static class CertumTotp
{
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    private static byte[] Base32Decode(string input)
    {
        input = input.Trim().TrimEnd('=').ToUpperInvariant();
        int byteCount = input.Length * 5 / 8;
        byte[] result = new byte[byteCount];

        int buffer = 0;
        int bitsLeft = 0;
        int index = 0;

        foreach (char c in input)
        {
            int value = Alphabet.IndexOf(c);
            if (value < 0) throw new ArgumentException("Invalid Base32 character.");

            buffer = (buffer << 5) | value;
            bitsLeft += 5;

            if (bitsLeft >= 8)
            {
                result[index++] = (byte)(buffer >> (bitsLeft - 8));
                bitsLeft -= 8;
            }
        }
        return result;
    }

    private static HMAC CreateHmac(string algorithm, byte[] key)
    {
        switch (algorithm.ToUpperInvariant())
        {
            case "SHA1": return new HMACSHA1(key);
            case "SHA256": return new HMACSHA256(key);
            case "SHA512": return new HMACSHA512(key);
            default: throw new ArgumentException("Unsupported TOTP algorithm.");
        }
    }

    public static string Generate(string secret, int digits, int period, string algorithm)
    {
        byte[] key = Base32Decode(secret);
        long counter = DateTimeOffset.UtcNow.ToUnixTimeSeconds() / period;
        byte[] counterBytes = BitConverter.GetBytes(counter);
        if (BitConverter.IsLittleEndian) Array.Reverse(counterBytes);

        byte[] hash;
        using (HMAC hmac = CreateHmac(algorithm, key))
        {
            hash = hmac.ComputeHash(counterBytes);
        }

        int offset = hash[hash.Length - 1] & 0x0f;
        int binary =
            ((hash[offset] & 0x7f) << 24) |
            ((hash[offset + 1] & 0xff) << 16) |
            ((hash[offset + 2] & 0xff) << 8) |
            (hash[offset + 3] & 0xff);

        int otp = binary % (int)Math.Pow(10, digits);
        return otp.ToString(new string('0', digits));
    }
}
"@

function Get-TotpPeriod {
    [math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / $period)
}

function Get-FreshTotp {
    param([long]$AfterPeriod = -1)

    while ((Get-TotpPeriod) -le $AfterPeriod) {
        $left = $period - ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % $period)
        Start-Sleep -Seconds ($left + 1)
    }

    $secondsLeft = $period - ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % $period)
    if ($secondsLeft -lt 20) {
        Start-Sleep -Seconds ($secondsLeft + 1)
    }

    [CertumTotp]::Generate($base32, $digits, $period, $algorithm)
}

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class SimplySignWin32
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    public static List<IntPtr> VisibleWindows(uint pid)
    {
        var result = new List<IntPtr>();
        EnumWindows((hWnd, lParam) =>
        {
            uint windowPid;
            GetWindowThreadProcessId(hWnd, out windowPid);
            if (windowPid == pid && IsWindowVisible(hWnd))
            {
                result.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
"@

function Get-VisibleWindows {
    @([SimplySignWin32]::VisibleWindows([uint32]$script:process.Id))
}

function Get-WindowArea {
    param([IntPtr]$Handle)
    $rect = New-Object 'SimplySignWin32+RECT'
    [SimplySignWin32]::GetWindowRect($Handle, [ref]$rect) | Out-Null
    ($rect.Right - $rect.Left) * ($rect.Bottom - $rect.Top)
}

function Get-LargestWindow {
    param([object[]]$Windows)
    $largest = [IntPtr]::Zero
    $area = -1
    foreach ($window in $Windows) {
        $candidate = Get-WindowArea -Handle $window
        if ($candidate -gt $area) {
            $area = $candidate
            $largest = $window
        }
    }
    $largest
}

function Focus-Window {
    param([IntPtr]$Handle)
    for ($i = 0; $i -lt 12; $i++) {
        [SimplySignWin32]::SetForegroundWindow($Handle) | Out-Null
        Start-Sleep -Milliseconds 300
        if ([SimplySignWin32]::GetForegroundWindow() -eq $Handle) {
            return $true
        }
    }
    return $false
}

function Save-DiagnosticScreenshot {
    param([string]$Name)
    if ($env:CAPTURE_DIAGNOSTICS -ne 'true') { return }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $path = Join-Path $env:RUNNER_TEMP "simplysign-$Name.png"
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bitmap.Dispose()
        Write-Host "Diagnostic screenshot saved: $path"
    } catch {
        Write-Warning "Could not capture diagnostic screenshot: $($_.Exception.Message)"
    }
}

function Dismiss-SecondaryWindows {
    param([IntPtr]$LoginWindow)

    $secondary = @(Get-VisibleWindows | Where-Object { $_ -ne $LoginWindow })
    foreach ($window in $secondary) {
        if (-not (Focus-Window -Handle $window)) { continue }

        # Avoid accepting an update. Try "No", then a keyboard fallback, then OK.
        foreach ($keys in @('%n', '{TAB} ', '{ENTER}')) {
            $script:shell.SendKeys($keys)
            Start-Sleep -Milliseconds 700
            if (-not (Get-VisibleWindows | Where-Object { $_ -eq $window })) {
                break
            }
        }
    }
}

function Submit-Credentials {
    param(
        [IntPtr]$LoginWindow,
        [string]$Otp
    )

    if (-not (Focus-Window -Handle $LoginWindow)) {
        throw 'Could not focus the SimplySign login window.'
    }

    Start-Sleep -Milliseconds 400

    Set-Clipboard -Value $UserId
    $script:shell.SendKeys('^a')
    $script:shell.SendKeys('{DEL}')
    $script:shell.SendKeys('^v')
    Start-Sleep -Milliseconds 250

    $script:shell.SendKeys('{TAB}')
    Start-Sleep -Milliseconds 200

    Set-Clipboard -Value $Otp
    $script:shell.SendKeys('^a')
    $script:shell.SendKeys('{DEL}')
    $script:shell.SendKeys('^v')
    Start-Sleep -Milliseconds 250

    $script:shell.SendKeys('{ENTER}')
    Set-Clipboard -Value ' '
}

function Resubmit-Token {
    param([string]$Otp)

    Set-Clipboard -Value $Otp
    $script:shell.SendKeys('^a')
    $script:shell.SendKeys('{DEL}')
    $script:shell.SendKeys('^v')
    Start-Sleep -Milliseconds 250
    $script:shell.SendKeys('{ENTER}')
    Set-Clipboard -Value ' '
}

$existing = Get-SigningCertificate
if ($existing) {
    Write-Host "Signing certificate is already available: $($existing.Subject)"
    exit 0
}

Get-Process -Name 'SimplySignDesktop' -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host 'Starting SimplySign Desktop authentication...'
$script:process = Start-Process -FilePath $exePath -PassThru
$script:shell = New-Object -ComObject WScript.Shell

$windows = @()
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $script:process.Refresh()
    if ($script:process.HasExited) {
        throw "SimplySign Desktop exited during startup with code $($script:process.ExitCode)."
    }

    $windows = @(Get-VisibleWindows)
    if ($windows.Count -gt 0) { break }
}

if ($windows.Count -eq 0) {
    Save-DiagnosticScreenshot -Name 'no-window'
    throw 'SimplySign Desktop did not show its login window within 30 seconds.'
}

$loginWindow = Get-LargestWindow -Windows $windows

# Allow asynchronous version/update dialogs to appear and dismiss them before typing.
for ($i = 0; $i -lt 5; $i++) {
    Dismiss-SecondaryWindows -LoginWindow $loginWindow
    Start-Sleep -Seconds 1
}

$otp = Get-FreshTotp
$lastSubmitPeriod = Get-TotpPeriod
Submit-Credentials -LoginWindow $loginWindow -Otp $otp
Remove-Variable otp -ErrorAction SilentlyContinue

Write-Host 'Waiting for the cloud code-signing certificate...'
$retries = 0
$maxRetries = 3

for ($elapsed = 0; $elapsed -lt 150; $elapsed += 5) {
    Start-Sleep -Seconds 5

    $cert = Get-SigningCertificate
    if ($cert) {
        Write-Host "SimplySign authenticated. Certificate available: $($cert.Subject)"
        exit 0
    }

    $visible = @(Get-VisibleWindows)
    $secondary = @($visible | Where-Object { $_ -ne $loginWindow })

    if ($secondary.Count -gt 0) {
        if ($retries -ge $maxRetries) {
            Save-DiagnosticScreenshot -Name 'authentication-rejected'
            throw "SimplySign rejected authentication $retries times. Check CERTUM_USERNAME, CERTUM_OTP_URI, and system time."
        }

        $retries++
        Dismiss-SecondaryWindows -LoginWindow $loginWindow
        Start-Sleep -Milliseconds 500

        $freshOtp = Get-FreshTotp -AfterPeriod $lastSubmitPeriod
        $lastSubmitPeriod = Get-TotpPeriod
        Resubmit-Token -Otp $freshOtp
        Remove-Variable freshOtp -ErrorAction SilentlyContinue
    }
}

Save-DiagnosticScreenshot -Name 'certificate-timeout'
throw "Certificate '$thumbprint' did not become available within 150 seconds."
