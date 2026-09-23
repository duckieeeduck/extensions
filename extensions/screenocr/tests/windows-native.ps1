#requires -Version 5.1
param(
    [switch]$RequireOcr,
    [switch]$RequireDesktop
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    [Console]::Error.WriteLine('Run this test with Windows PowerShell 5.1 (powershell.exe), not pwsh.')
    exit 1
}

$helperPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\ocr.ps1'
$captureMutexName = 'Local\Raycast.ScreenOCR.Capture'
$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:CurrentSkipReason = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if (-not [object]::Equals($Actual, $Expected)) {
        throw "$Message Expected <$Expected>, received <$Actual>."
    }
}

function Skip-CurrentTest {
    param([string]$Reason)
    $script:CurrentSkipReason = $Reason
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    $script:CurrentSkipReason = $null
    try {
        & $Body
        if ($script:CurrentSkipReason) {
            $script:Skipped++
            Write-Host "SKIP $Name - $script:CurrentSkipReason"
        }
        else {
            $script:Passed++
            Write-Host "PASS $Name"
        }
    }
    catch {
        $script:Failed++
        Write-Host "FAIL $Name"
        Write-Host $_.Exception.ToString()
    }
}

function ConvertFrom-CodePoints {
    param([int[]]$CodePoints)
    return -join @($CodePoints | ForEach-Object { [char]$_ })
}

function Invoke-HelperProcess {
    param([string]$ScriptArguments, [string]$ScriptFile = $helperPath, [hashtable]$Environment = @{})

    $powerShellPath = Join-Path $PSHOME 'powershell.exe'
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "' + $ScriptFile + '" ' + $ScriptArguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false
    foreach ($name in $Environment.Keys) { $startInfo.EnvironmentVariables[$name] = [string]$Environment[$name] }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'The helper process did not exit within 30 seconds.'
        }
        return New-Object PSObject -Property @{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.Result
            Stderr = $stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    [Console]::Error.WriteLine("Helper not found: $helperPath")
    exit 1
}

$tokens = $null
$parseErrors = $null
$helperAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $helperPath,
    [ref]$tokens,
    [ref]$parseErrors
)
$functionAsts = @($helperAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true))
$requiredFunctions = @(
    'Write-DebugLine',
    'Initialize-WinRt',
    'Initialize-NativeMethods',
    'Wait-WinRtOperation',
    'Get-FittedSize',
    'New-CompatibleBitmap',
    'Resize-Bitmap',
    'Set-ImageOrientation',
    'New-OcrEngine',
    'Normalize-OcrLine',
    'Invoke-Ocr',
    'Enter-CaptureMutex'
)
# Script-scope state the dot-sourced helper functions expect.
$script:DebugOutput = $false
$script:Clock = [System.Diagnostics.Stopwatch]::StartNew()
$script:AsTaskGeneric = $null

Invoke-Test 'helper parses as Windows PowerShell source' {
    Assert-Equal $parseErrors.Count 0 'The helper has parser errors.'
    $nonAsciiBytes = @([System.IO.File]::ReadAllBytes($helperPath) | Where-Object { $_ -gt 127 })
    Assert-Equal $nonAsciiBytes.Count 0 'The BOM-less helper must remain ASCII-safe for Windows PowerShell 5.1.'
}

Invoke-Test 'required helper functions are defined exactly once' {
    foreach ($name in $requiredFunctions) {
        $matches = @($functionAsts | Where-Object { $_.Name -eq $name })
        Assert-Equal $matches.Count 1 "Unexpected definition count for $name."
    }
}

foreach ($name in $requiredFunctions) {
    $definition = @($functionAsts | Where-Object { $_.Name -eq $name })
    if ($definition.Count -eq 1) {
        . ([scriptblock]::Create($definition[0].Extent.Text))
    }
}

Invoke-Test 'CJK normalization removes only intra-script ASCII spaces' {
    $han = ConvertFrom-CodePoints @(0x4E2D, 0x6587)
    $spacedHan = ([string]$han[0]) + ' ' + ([string]$han[1])
    Assert-Equal (Normalize-OcrLine $spacedHan 'zh-Hans') $han 'Simplified Chinese spaces were not normalized.'
    Assert-Equal (Normalize-OcrLine $spacedHan 'yue-Hant') $han 'Cantonese spaces were not normalized.'

    $japanese = ConvertFrom-CodePoints @(0x65E5, 0x672C, 0x8A9E, 0x30C6, 0x30B9, 0x30C8)
    $spacedJapanese = (($japanese.ToCharArray() | ForEach-Object { [string]$_ }) -join ' ')
    Assert-Equal (Normalize-OcrLine $spacedJapanese 'ja-JP') $japanese 'Japanese spaces were not normalized.'
    Assert-Equal (Normalize-OcrLine $spacedJapanese 'JA-jp') $japanese 'Language tags should be matched case-insensitively.'
}

Invoke-Test 'CJK normalization preserves meaningful boundaries' {
    $han = ConvertFrom-CodePoints @(0x4E2D, 0x6587)
    $spacedHan = ([string]$han[0]) + ' ' + ([string]$han[1])
    Assert-Equal (Normalize-OcrLine $spacedHan 'en-US') $spacedHan 'Non-CJK language spacing changed.'

    $mixed = ([string]$han[0]) + ' A ' + ([string]$han[1])
    Assert-Equal (Normalize-OcrLine $mixed 'zh-Hans') $mixed 'Latin/CJK boundaries changed.'

    $hangul = ConvertFrom-CodePoints @(0xAC00, 0xB098)
    $spacedHangul = ([string]$hangul[0]) + ' ' + ([string]$hangul[1])
    Assert-Equal (Normalize-OcrLine $spacedHangul 'zh-Hans') $spacedHangul 'Hangul spacing changed.'

    $fullwidth = ConvertFrom-CodePoints @(0xFF11, 0xFF12)
    $spacedFullwidth = ([string]$fullwidth[0]) + ' ' + ([string]$fullwidth[1])
    Assert-Equal (Normalize-OcrLine $spacedFullwidth 'zh-Hans') $spacedFullwidth 'Fullwidth spacing changed.'

    $tabbed = ([string]$han[0]) + "`t" + ([string]$han[1])
    Assert-Equal (Normalize-OcrLine $tabbed 'zh-Hans') $tabbed 'Tab boundaries changed.'
    $nonBreaking = ([string]$han[0]) + ([char]0x00A0) + ([string]$han[1])
    Assert-Equal (Normalize-OcrLine $nonBreaking 'zh-Hans') $nonBreaking 'Non-breaking spaces changed.'
}

Invoke-Test 'fitted sizes preserve aspect ratio within the limit' {
    $width, $height = Get-FittedSize 4000 1000 2000
    Assert-Equal $width 2000 'Fitted width was wrong.'
    Assert-Equal $height 500 'Fitted height was wrong.'
    $width, $height = Get-FittedSize 300 200 2000
    Assert-Equal $width 300 'An image within the limit was resized.'
    Assert-Equal $height 200 'An image within the limit was resized.'
    $width, $height = Get-FittedSize 100000 1 2000
    Assert-Equal $height 1 'An extreme aspect ratio produced a zero dimension.'
}

Invoke-Test 'EXIF orientation is applied to copied photo files' {
    Add-Type -AssemblyName System.Drawing
    $photo = New-Object System.Drawing.Bitmap (30, 10)
    try {
        $item = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject([System.Drawing.Imaging.PropertyItem])
        $item.Id = 0x0112
        $item.Type = 3
        $item.Len = 2
        $item.Value = [byte[]](6, 0)
        $photo.SetPropertyItem($item)
        Set-ImageOrientation $photo
        Assert-Equal $photo.Width 10 'Orientation 6 was not rotated.'
        Assert-Equal $photo.Height 30 'Orientation 6 was not rotated.'
    }
    finally { $photo.Dispose() }
}

Invoke-Test 'bitmap resize clamps zero-sized requests' {
    Add-Type -AssemblyName System.Drawing
    $source = New-Object System.Drawing.Bitmap (20, 10)
    $resized = $null
    try {
        $resized = Resize-Bitmap $source 0 0
        Assert-Equal $resized.Width 1 'Resize width was not clamped.'
        Assert-Equal $resized.Height 1 'Resize height was not clamped.'
    }
    finally {
        if ($resized) { $resized.Dispose() }
        $source.Dispose()
    }
}

Invoke-Test 'language inventory uses one strict JSON protocol message' {
    $result = Invoke-HelperProcess '-ListLanguages'
    Assert-Equal $result.ExitCode 0 'Language inventory failed.'
    Assert-True ([string]::IsNullOrWhiteSpace($result.Stderr)) 'Language inventory wrote diagnostics to stderr.'
    $raw = $result.Stdout.Trim()
    Assert-True ($raw.StartsWith('{') -and $raw.EndsWith('}')) 'Language inventory was not one JSON object.'
    $payload = $raw | ConvertFrom-Json
    Assert-Equal $payload.status 'languages' 'Language inventory returned the wrong status.'
    Assert-True ($payload.PSObject.Properties.Name -contains 'languages') 'Language inventory omitted its languages array.'
    foreach ($language in @($payload.languages)) {
        Assert-True ($language.tag -match '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,3}$') 'Language inventory returned an invalid tag.'
        Assert-True (-not [string]::IsNullOrWhiteSpace($language.displayName)) 'Language inventory returned an empty display name.'
    }
}

Invoke-Test 'screen capture contention exits immediately without affecting non-capture modes' {
    $heldMutex = [System.Threading.Mutex]::new($false, $captureMutexName)
    $ownsMutex = $false
    try {
        $ownsMutex = $heldMutex.WaitOne(0, $false)
        Assert-True $ownsMutex 'The test could not acquire the capture mutex.'

        foreach ($mode in @('area', 'fullscreen', 'barcode')) {
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-HelperProcess "-Mode $mode"
            $timer.Stop()
            Assert-Equal $result.ExitCode 6 "$mode contention returned the wrong exit code."
            Assert-True ($timer.Elapsed.TotalSeconds -lt 10) "$mode contention did not exit promptly."
            Assert-True ([string]::IsNullOrWhiteSpace($result.Stderr)) "$mode contention wrote diagnostics to stderr."
            $payload = $result.Stdout.Trim() | ConvertFrom-Json
            Assert-Equal $payload.status 'error' "$mode contention returned the wrong status."
            Assert-Equal $payload.code 'capture-busy' "$mode contention returned the wrong protocol code."
            Assert-Equal @($payload.PSObject.Properties).Count 2 "$mode contention returned unexpected protocol fields."
        }

        $languages = Invoke-HelperProcess '-ListLanguages'
        Assert-Equal $languages.ExitCode 0 'Language inventory was blocked by a screen capture.'
        Assert-Equal (($languages.Stdout.Trim() | ConvertFrom-Json).status) 'languages' 'Language inventory returned the wrong status during capture contention.'

        $clipboard = Invoke-HelperProcess '-Mode clipboard'
        Assert-True ($clipboard.ExitCode -ne 6) 'Clipboard recognition was blocked by a screen capture.'
    }
    finally {
        if ($ownsMutex) { $heldMutex.ReleaseMutex() }
        $heldMutex.Dispose()
    }
}

Invoke-Test 'capture mutex accepts an abandoned owner while its named object remains alive' {
    $keepAlive = [System.Threading.Mutex]::new($false, $captureMutexName)
    $holder = $null
    $recovered = $null
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = Join-Path $PSHOME 'powershell.exe'
        $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -Command "$mutex = [System.Threading.Mutex]::new($false, ''Local\Raycast.ScreenOCR.Capture''); [void]$mutex.WaitOne(); [Console]::Out.Write(''held''); [Console]::Out.Flush(); [System.Diagnostics.Process]::GetCurrentProcess().Kill()"'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $holder = New-Object System.Diagnostics.Process
        $holder.StartInfo = $startInfo
        [void]$holder.Start()
        $stdoutTask = $holder.StandardOutput.ReadToEndAsync()
        $stderrTask = $holder.StandardError.ReadToEndAsync()
        if (-not $holder.WaitForExit(10000)) {
            $holder.Kill()
            $holder.WaitForExit()
            throw 'The abandoned-mutex holder did not exit within 10 seconds.'
        }
        Assert-Equal $holder.ExitCode ([int](-1)) 'The abandoned-mutex holder did not terminate as expected.'
        Assert-Equal $stdoutTask.Result 'held' 'The abandoned-mutex holder did not acquire the mutex.'
        Assert-True ([string]::IsNullOrWhiteSpace($stderrTask.Result)) 'The abandoned-mutex holder wrote diagnostics to stderr.'

        $recovered = Enter-CaptureMutex
        Assert-True ($null -ne $recovered) 'The helper did not recover ownership of an abandoned mutex.'
    }
    finally {
        if ($recovered) {
            try { $recovered.ReleaseMutex() }
            finally { $recovered.Dispose() }
        }
        if ($holder) { $holder.Dispose() }
        $keepAlive.Dispose()
    }
}

Invoke-Test 'debug diagnostics stay on stderr and are off by default' {
    $quiet = Invoke-HelperProcess '-ListLanguages'
    Assert-True ([string]::IsNullOrWhiteSpace($quiet.Stderr)) 'Diagnostics were written without SCREENOCR_DEBUG.'
    $verbose = Invoke-HelperProcess '-ListLanguages' $helperPath @{ SCREENOCR_DEBUG = '1' }
    Assert-Equal $verbose.ExitCode 0 'Language inventory failed with diagnostics enabled.'
    Assert-True ($verbose.Stderr -match 'winrt-ready') 'Diagnostics did not report Windows Runtime initialization.'
    Assert-Equal (($verbose.Stdout.Trim() | ConvertFrom-Json).status) 'languages' 'Diagnostics changed the protocol output.'
}

Invoke-Test 'Constrained Language mode is reported without running the helper' {
    $escapedPath = $helperPath.Replace("'", "''")
    $command = "`$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'; & '$escapedPath' -Mode fullscreen; exit `$LASTEXITCODE"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $PSHOME 'powershell.exe'
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'The constrained helper did not exit within 30 seconds.' }
        Assert-Equal $process.ExitCode 7 "Constrained Language mode returned the wrong exit code: $($stderrTask.Result)"
        $payload = $stdoutTask.Result.Trim() | ConvertFrom-Json
        Assert-Equal $payload.code 'restricted-language' 'Constrained Language mode returned the wrong protocol code.'
    }
    finally { $process.Dispose() }
}

Invoke-Test 'barcode mode returns the selected region as luminance bytes' {
    # Keep the shipped control flow, native compilation and conversion. Replace
    # only desktop capture and selection so no interactive UI is required.
    $replacements = @{
        'Get-VirtualScreenBitmap' = @'
function Get-VirtualScreenBitmap {
    $bitmap = [System.Drawing.Bitmap]::new(40, 10, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.FillRectangle([System.Drawing.Brushes]::Black, 0, 0, 20, 10)
    } finally { $graphics.Dispose() }
    return $bitmap
}
'@
        'Select-ScreenRegion' = @'
function Select-ScreenRegion {
    param([System.Drawing.Bitmap]$Frozen)
    return [System.Drawing.Rectangle]::new(10, 0, 20, 10)
}
'@
    }
    $instrumented = [System.IO.File]::ReadAllText($helperPath)
    foreach ($definition in @($functionAsts | Where-Object { $replacements.ContainsKey($_.Name) } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $instrumented = $instrumented.Remove($definition.Extent.StartOffset, $definition.Extent.EndOffset - $definition.Extent.StartOffset).Insert($definition.Extent.StartOffset, $replacements[$definition.Name])
    }
    $testHelper = Join-Path ([System.IO.Path]::GetTempPath()) ('screenocr-barcode-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    try {
        [System.IO.File]::WriteAllText($testHelper, $instrumented, [System.Text.Encoding]::ASCII)
        $result = Invoke-HelperProcess '-Mode barcode' $testHelper
        Assert-Equal $result.ExitCode 0 "Barcode mode failed: $($result.Stderr)"
        Assert-True ([string]::IsNullOrWhiteSpace($result.Stderr)) 'Barcode mode wrote unexpected diagnostics.'
        $payload = $result.Stdout.Trim() | ConvertFrom-Json
        Assert-Equal $payload.status 'image' 'Barcode mode returned the wrong status.'
        Assert-Equal @($payload.PSObject.Properties).Count 4 'Barcode mode returned unexpected protocol fields.'
        Assert-Equal $payload.width 20 'Barcode mode returned the wrong width.'
        Assert-Equal $payload.height 10 'Barcode mode returned the wrong height.'
        $bytes = [Convert]::FromBase64String($payload.luminance)
        Assert-Equal $bytes.Length 200 'Barcode mode returned the wrong number of pixels.'
        foreach ($row in 0..9) {
            Assert-Equal ([int]$bytes[$row * 20]) 0 "Row $row did not start black."
            Assert-Equal ([int]$bytes[$row * 20 + 9]) 0 "Row $row changed before the edge."
            Assert-Equal ([int]$bytes[$row * 20 + 10]) 255 "Row $row did not turn white at the edge."
            Assert-Equal ([int]$bytes[$row * 20 + 19]) 255 "Row $row did not end white."
        }
    }
    finally { Remove-Item -LiteralPath $testHelper -Force -ErrorAction SilentlyContinue }
}

Invoke-Test 'Escape cancels the selection overlay without keyboard focus and releases the key' {
    Add-Type -AssemblyName System.Windows.Forms
    if (-not ('ScreenOcrTest.Windows' -as [type])) {
        Add-Type -Namespace ScreenOcrTest -Name Windows -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindow(string className, string windowName);
[DllImport("user32.dll")]
public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint virtualKey);
[DllImport("user32.dll")]
public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
'@
    }
    $powerShellPath = Join-Path $PSHOME 'powershell.exe'
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "' + $helperPath + '" -Mode area'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $overlay = [IntPtr]::Zero
        while ($timer.Elapsed.TotalSeconds -lt 20 -and -not $process.HasExited -and $overlay -eq [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 100
            $overlay = [ScreenOcrTest.Windows]::FindWindow($null, 'ScreenOCR selection')
        }
        if ($overlay -eq [IntPtr]::Zero) {
            if (-not $process.HasExited) { $process.Kill() }
            $process.WaitForExit()
            $reason = "The selection overlay did not appear (exit $($process.ExitCode)): $($stderrTask.Result.Trim())"
            if ($RequireDesktop) { throw $reason }
            Skip-CurrentTest "No interactive desktop. $reason"
            return
        }
        # Deliberately send no click and set no focus: the hot key must work without them.
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'Escape did not close the selection overlay.'
        }
        Assert-Equal $process.ExitCode 2 "Escape did not report cancellation: $($stderrTask.Result)"
        Assert-True ([string]::IsNullOrWhiteSpace($stdoutTask.Result)) 'Cancellation wrote a protocol payload.'
        $probeId = 0x5350
        $available = [ScreenOcrTest.Windows]::RegisterHotKey([IntPtr]::Zero, $probeId, 0x4000, 0x1B)
        if ($available) { [void][ScreenOcrTest.Windows]::UnregisterHotKey([IntPtr]::Zero, $probeId) }
        Assert-True $available 'The Escape hot key remained registered after the overlay closed.'
    }
    finally { $process.Dispose() }
}

Invoke-Test 'invalid language arguments are rejected before helper execution' {
    $result = Invoke-HelperProcess '-ListLanguages -Language "ja-JP;Write-Output bad"'
    Assert-True ($result.ExitCode -ne 0) 'An invalid language argument was accepted.'
    Assert-True ([string]::IsNullOrWhiteSpace($result.Stdout)) 'An invalid argument produced a protocol payload.'
}

Invoke-Test 'another process can capture while the first bitmap is being recognized' {
    # Keep the shipped main control flow and real mutex operations. Replace only
    # desktop capture/selection and OCR so this regression needs no interactive UI.
    $replacements = @{
        'Get-VirtualScreenBitmap' = @'
function Get-VirtualScreenBitmap {
    return [System.Drawing.Bitmap]::new(20, 20)
}
'@
        'Select-ScreenRegion' = @'
function Select-ScreenRegion {
    param([System.Drawing.Bitmap]$Frozen)
    return [System.Drawing.Rectangle]::new(0, 0, 10, 10)
}
'@
        'Invoke-Ocr' = @'
function Invoke-Ocr {
    param([System.Drawing.Bitmap]$Bitmap, [string]$LanguageTag, [bool]$JoinLines)
    if ($Bitmap.Width -lt 1) { throw 'The captured bitmap was disposed before recognition.' }
    # A fresh process avoids recursive ownership by the existing mutex-owning thread.
    $probe = '$mutex = [System.Threading.Mutex]::new($false, "Local\Raycast.ScreenOCR.Capture"); try { if (-not $mutex.WaitOne(0, $false)) { exit 6 }; $mutex.ReleaseMutex() } finally { $mutex.Dispose() }'
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($probe))
    & (Join-Path $PSHOME 'powershell.exe') -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded
    if ($LASTEXITCODE -ne 0) { throw 'The capture lock was still held when OCR began.' }
    return 'CAPTURE_RELEASED'
}
'@
    }
    $instrumented = [System.IO.File]::ReadAllText($helperPath)
    foreach ($definition in @($functionAsts | Where-Object { $replacements.ContainsKey($_.Name) } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $instrumented = $instrumented.Remove($definition.Extent.StartOffset, $definition.Extent.EndOffset - $definition.Extent.StartOffset).Insert($definition.Extent.StartOffset, $replacements[$definition.Name])
    }
    $testHelper = Join-Path ([System.IO.Path]::GetTempPath()) ('screenocr-lock-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    try {
        [System.IO.File]::WriteAllText($testHelper, $instrumented, [System.Text.Encoding]::ASCII)
        foreach ($mode in @('area', 'fullscreen')) {
            $result = Invoke-HelperProcess "-Mode $mode" $testHelper
            Assert-Equal $result.ExitCode 0 "$mode retained the capture lock during recognition: $($result.Stderr)"
            Assert-True ([string]::IsNullOrWhiteSpace($result.Stderr)) "$mode wrote unexpected diagnostics."
            $payload = $result.Stdout.Trim() | ConvertFrom-Json
            Assert-Equal $payload.status 'recognized' "$mode did not reach recognition."
            Assert-Equal $payload.text 'CAPTURE_RELEASED' "$mode did not complete the lock probe."
        }
    }
    finally { Remove-Item -LiteralPath $testHelper -Force -ErrorAction SilentlyContinue }
}

$script:WinRtReady = $false
Invoke-Test 'Windows Runtime OCR types initialize' {
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
    $null = [Windows.Globalization.Language,Windows.Foundation,ContentType=WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder,Windows.Foundation,ContentType=WindowsRuntime]
    $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
    Assert-True ($null -ne $script:AsTaskGeneric) 'The WinRT AsTask adapter was not found.'
    $script:MaxClipboardFileBytes = 128MB
    $script:MaxSourceDimension = 32768
    $script:MaxSourcePixels = 100000000L
    $script:WinRtReady = $true
}

Invoke-Test 'explicit OCR engines keep the selected installed language' {
    if (-not $script:WinRtReady) { Skip-CurrentTest 'Windows Runtime initialization failed in the preceding test.'; return }
    $available = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages)
    if ($available.Count -eq 0) {
        if ($RequireOcr) { throw 'No Windows OCR language packs are installed.' }
        Skip-CurrentTest 'No Windows OCR language packs are installed.'
        return
    }
    foreach ($language in $available) {
        $engine = New-OcrEngine $language.LanguageTag
        Assert-True ($null -ne $engine) "Could not create the installed $($language.LanguageTag) engine."
        Assert-True ($engine.RecognizerLanguage.LanguageTag -ieq $language.LanguageTag) "The $($language.LanguageTag) engine resolved to another language."
    }
}

Invoke-Test 'a missing regional pack does not resolve to an installed sibling' {
    if (-not $script:WinRtReady) { Skip-CurrentTest 'Windows Runtime initialization failed in the preceding test.'; return }
    $availableTags = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag })
    $families = @(
        @{ Pattern = '^en-'; Candidates = @('en-US', 'en-GB', 'en-AU') },
        @{ Pattern = '^fr-'; Candidates = @('fr-FR', 'fr-CA', 'fr-BE') },
        @{ Pattern = '^es-'; Candidates = @('es-ES', 'es-MX', 'es-AR') },
        @{ Pattern = '^pt-'; Candidates = @('pt-BR', 'pt-PT') }
    )
    $missingTag = $null
    foreach ($family in $families) {
        if (@($availableTags | Where-Object { $_ -match $family.Pattern }).Count -eq 0) { continue }
        foreach ($candidate in $family.Candidates) {
            if ($availableTags -notcontains $candidate) { $missingTag = $candidate; break }
        }
        if ($missingTag) { break }
    }
    if (-not $missingTag) {
        Skip-CurrentTest 'No installed language has a suitable missing regional sibling.'
        return
    }
    Assert-True ($null -eq (New-OcrEngine $missingTag)) "The missing $missingTag pack resolved to a related installed pack."
}

Invoke-Test 'WinRT recognizes known text from an in-memory bitmap' {
    if (-not $script:WinRtReady) { Skip-CurrentTest 'Windows Runtime initialization failed in the preceding test.'; return }
    $latinLanguage = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | Where-Object {
        $_.Script -eq 'Latn'
    } | Select-Object -First 1)
    if ($latinLanguage.Count -eq 0) {
        if ($RequireOcr) { throw 'A Latin-script Windows OCR language pack is required for the known-text test.' }
        Skip-CurrentTest 'No Latin-script Windows OCR language pack is installed.'
        return
    }

    $bitmap = New-Object System.Drawing.Bitmap (1200, 240, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = $null
    $font = $null
    $brush = $null
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $font = New-Object System.Drawing.Font ('Segoe UI', 72, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Black)
        $graphics.DrawString('SCREENOCR TEST', $font, $brush, 30, 55)
        $graphics.Flush()

        $text = Invoke-Ocr $bitmap $latinLanguage[0].LanguageTag $false
        $canonical = [regex]::Replace($text, '[^A-Za-z]', '').ToUpperInvariant()
        Assert-Equal $canonical 'SCREENOCRTEST' 'WinRT did not recognize the rendered fixture.'
    }
    finally {
        if ($brush) { $brush.Dispose() }
        if ($font) { $font.Dispose() }
        if ($graphics) { $graphics.Dispose() }
        $bitmap.Dispose()
    }
}

Invoke-Test 'clipboard recognition prefers the PNG format that keeps transparency' {
    if (-not $script:WinRtReady) { Skip-CurrentTest 'Windows Runtime initialization failed in the preceding test.'; return }
    $latinLanguage = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | Where-Object { $_.Script -eq 'Latn' } | Select-Object -First 1)
    if ($latinLanguage.Count -eq 0) {
        if ($RequireOcr) { throw 'A Latin-script Windows OCR language pack is required for the clipboard test.' }
        Skip-CurrentTest 'No Latin-script Windows OCR language pack is installed.'
        return
    }
    Add-Type -AssemblyName System.Windows.Forms
    # Black text on a transparent background. The standard bitmap format is given
    # a blank image, so recognizing the text proves the PNG format was used.
    $transparent = New-Object System.Drawing.Bitmap (1200, 240, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $blank = New-Object System.Drawing.Bitmap (1200, 240)
    $png = New-Object System.IO.MemoryStream
    $graphics = $null
    $font = $null
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($transparent)
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $font = New-Object System.Drawing.Font ('Segoe UI', 72, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $graphics.DrawString('SCREENOCR TEST', $font, [System.Drawing.Brushes]::Black, 30, 55)
        $transparent.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        $blankGraphics = [System.Drawing.Graphics]::FromImage($blank)
        try { $blankGraphics.Clear([System.Drawing.Color]::White) } finally { $blankGraphics.Dispose() }
        $data = New-Object System.Windows.Forms.DataObject
        $data.SetData('PNG', $false, $png)
        $data.SetData([System.Windows.Forms.DataFormats]::Bitmap, $true, $blank)
        [System.Windows.Forms.Clipboard]::SetDataObject($data, $true)
        $result = Invoke-HelperProcess ('-Mode clipboard -Language ' + $latinLanguage[0].LanguageTag)
        Assert-Equal $result.ExitCode 0 "Clipboard recognition failed: $($result.Stderr) $($result.Stdout)"
        $payload = $result.Stdout.Trim() | ConvertFrom-Json
        Assert-Equal $payload.status 'recognized' 'Clipboard recognition found no text in the PNG format.'
        Assert-Equal ([regex]::Replace($payload.text, '[^A-Za-z]', '').ToUpperInvariant()) 'SCREENOCRTEST' 'Clipboard recognition misread the PNG format.'
    }
    finally {
        try { [System.Windows.Forms.Clipboard]::Clear() } catch {}
        if ($font) { $font.Dispose() }
        if ($graphics) { $graphics.Dispose() }
        $png.Dispose()
        $blank.Dispose()
        $transparent.Dispose()
    }
}

Write-Host "RESULT pass=$script:Passed fail=$script:Failed skip=$script:Skipped"
if ($script:Failed -gt 0) { exit 1 }
exit 0
