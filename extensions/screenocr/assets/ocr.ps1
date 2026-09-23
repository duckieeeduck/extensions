# ScreenOCR Windows helper. Runs on demand under Windows PowerShell 5.1.
# Stdout is reserved for one JSON protocol message; diagnostics use stderr.
#
# Exit codes (mirrored by HELPER_EXIT in src/ocr/windows.ts):
#   0  success: recognized, no-text, languages or image payload
#   2  the user cancelled the screen selection
#   3  the requested OCR language is not installed
#   4  clipboard input error; the payload carries the specific code
#   5  unexpected failure; details are written to stderr
#   6  another ScreenOCR screen capture is already in progress
#   7  PowerShell runs in Constrained Language mode (organization policy)
param(
    [ValidateSet('area', 'fullscreen', 'clipboard', 'barcode')]
    [string]$Mode,
    [ValidatePattern('^(auto|[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,3})$')]
    [string]$Language = 'auto',
    [switch]$IgnoreLineBreaks,
    [switch]$ListLanguages
)

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    # App Control or AppLocker policies run unapproved scripts in Constrained Language
    # mode, which blocks the .NET and Win32 calls this helper needs. Report the policy
    # instead of attempting to work around it.
    Write-Output '{"status":"error","code":"restricted-language"}'
    exit 7
}

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}

$script:MaxClipboardFileBytes = 128MB
$script:MaxSourceDimension = 32768
$script:MaxSourcePixels = 100000000L
$script:MaxBarcodeDimension = 2048
$script:AsTaskGeneric = $null
$script:DebugOutput = $env:SCREENOCR_DEBUG -eq '1'
$script:Clock = [System.Diagnostics.Stopwatch]::StartNew()

function Write-DebugLine {
    param([string]$Message)
    if ($script:DebugOutput) {
        [Console]::Error.WriteLine("screenocr $($script:Clock.ElapsedMilliseconds)ms $Message")
    }
}

function Write-ProtocolJson {
    param([object]$Value)
    $json = ConvertTo-Json -InputObject $Value -Compress -Depth 5
    Write-ProtocolText $json
}

function Write-ProtocolText {
    param([string]$Json)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

function Initialize-WinRt {
    # Loaded only when OCR or the language list needs it, so the selection overlay
    # appears without waiting for the Windows Runtime projections.
    if ($script:AsTaskGeneric) { return }
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
    $null = [Windows.Globalization.Language,Windows.Foundation,ContentType=WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder,Windows.Foundation,ContentType=WindowsRuntime]
    $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
    if (-not $script:AsTaskGeneric) { throw 'Windows Runtime initialization failed.' }
    Write-DebugLine 'winrt-ready'
}

function Initialize-NativeMethods {
    # Compiled once per helper run, only for screen capture modes.
    if ('ScreenOcrNative.EscapeHotKey' -as [type]) { return }
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ScreenOcrNative
{
    public static class Dpi
    {
        [DllImport("user32.dll")]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();
    }

    // Registers Escape as a hot key for the lifetime of this object and cancels the
    // target form when it is pressed. Windows does not always give a newly shown
    // overlay keyboard focus; the hot key works without focus and keeps Escape from
    // reaching the application underneath while the overlay is open.
    public sealed class EscapeHotKey : NativeWindow, IDisposable
    {
        private const int WmHotKey = 0x0312;
        private const int HotKeyId = 0x534F;
        private const uint ModNoRepeat = 0x4000;
        private const uint VkEscape = 0x1B;
        private static readonly IntPtr MessageOnlyParent = new IntPtr(-3);
        private readonly Form target;
        private bool registered;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint virtualKey);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        public EscapeHotKey(Form target)
        {
            if (target == null) throw new ArgumentNullException("target");
            this.target = target;
            CreateParams parameters = new CreateParams();
            parameters.Parent = MessageOnlyParent;
            CreateHandle(parameters);
            registered = RegisterHotKey(Handle, HotKeyId, ModNoRepeat, VkEscape);
            if (!registered) LastError = Marshal.GetLastWin32Error();
        }

        public bool IsRegistered { get { return registered; } }

        public int LastError { get; private set; }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == WmHotKey && message.WParam.ToInt64() == HotKeyId)
            {
                if (!target.IsDisposed && target.Visible)
                {
                    target.DialogResult = DialogResult.Cancel;
                    target.Close();
                }
                return;
            }
            base.WndProc(ref message);
        }

        public void Dispose()
        {
            if (registered)
            {
                UnregisterHotKey(Handle, HotKeyId);
                registered = false;
            }
            if (Handle != IntPtr.Zero) DestroyHandle();
        }
    }

    public static class Imaging
    {
        // One luminance byte per pixel, row-major, composited over white.
        public static byte[] ToLuminance(Bitmap source)
        {
            if (source == null) throw new ArgumentNullException("source");
            int width = source.Width;
            int height = source.Height;
            BitmapData data = source.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                int rowBytes = checked(width * 4);
                byte[] row = new byte[rowBytes];
                byte[] luminance = new byte[checked(width * height)];
                for (int y = 0; y < height; y++)
                {
                    Marshal.Copy(new IntPtr(data.Scan0.ToInt64() + (long)y * data.Stride), row, 0, rowBytes);
                    int offset = y * width;
                    for (int x = 0; x < width; x++)
                    {
                        int i = x * 4;
                        int alpha = row[i + 3];
                        int gray = (114 * row[i] + 587 * row[i + 1] + 299 * row[i + 2]) / 1000;
                        luminance[offset + x] = (byte)((gray * alpha + 255 * (255 - alpha)) / 255);
                    }
                }
                return luminance;
            }
            finally
            {
                source.UnlockBits(data);
            }
        }
    }
}
'@
    Write-DebugLine 'native-ready'
}

function Enable-DpiAwareness {
    # Per-monitor v2 keeps screen coordinates and captured pixels in physical units.
    try {
        if ([ScreenOcrNative.Dpi]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))) {
            Write-DebugLine 'dpi per-monitor-v2'
            return
        }
    } catch {}
    [void][ScreenOcrNative.Dpi]::SetProcessDPIAware()
    Write-DebugLine 'dpi system-aware fallback'
}

function Wait-WinRtOperation {
    param($Operation, [Type]$ResultType)
    $task = $script:AsTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

function Get-FittedSize {
    param([int]$Width, [int]$Height, [int]$MaxDimension)
    if ($Width -le $MaxDimension -and $Height -le $MaxDimension) { return @($Width, $Height) }
    $ratio = [Math]::Min($MaxDimension / [double]$Width, $MaxDimension / [double]$Height)
    $fittedWidth = [Math]::Max(1, [Math]::Min($MaxDimension, [int][Math]::Floor($Width * $ratio)))
    $fittedHeight = [Math]::Max(1, [Math]::Min($MaxDimension, [int][Math]::Floor($Height * $ratio)))
    return @($fittedWidth, $fittedHeight)
}

function Resize-Bitmap {
    # Draws the source onto a new opaque 32bpp bitmap with a white background.
    param([System.Drawing.Image]$Source, [int]$Width, [int]$Height)
    $width = [Math]::Max(1, $Width)
    $height = [Math]::Max(1, $Height)
    $dest = New-Object System.Drawing.Bitmap ($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = $null
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($dest)
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($Source, 0, 0, $width, $height)
        return $dest
    }
    catch {
        $dest.Dispose()
        throw
    }
    finally {
        if ($graphics) { $graphics.Dispose() }
    }
}

function New-CompatibleBitmap {
    # Validates an untrusted clipboard image and converts it to an opaque bitmap
    # no larger than the OCR engine accepts.
    param([System.Drawing.Image]$Source)
    if ($Source.Width -lt 1 -or $Source.Height -lt 1) { throw 'The image has invalid dimensions.' }
    if ($Source.Width -gt $script:MaxSourceDimension -or $Source.Height -gt $script:MaxSourceDimension -or
        ([long]$Source.Width * [long]$Source.Height) -gt $script:MaxSourcePixels) {
        throw 'SCREENOCR_IMAGE_TOO_LARGE'
    }
    $width, $height = Get-FittedSize $Source.Width $Source.Height ([Windows.Media.Ocr.OcrEngine]::MaxImageDimension)
    return Resize-Bitmap $Source $width $height
}

function Set-ImageOrientation {
    # Applies the EXIF orientation of a decoded file so photos are recognized upright.
    param([System.Drawing.Image]$Image)
    if (@($Image.PropertyIdList) -notcontains 0x0112) { return }
    $value = $Image.GetPropertyItem(0x0112).Value
    if (-not $value -or $value.Length -lt 2) { return }
    $rotation = switch ([BitConverter]::ToUInt16($value, 0)) {
        2 { [System.Drawing.RotateFlipType]::RotateNoneFlipX }
        3 { [System.Drawing.RotateFlipType]::Rotate180FlipNone }
        4 { [System.Drawing.RotateFlipType]::Rotate180FlipX }
        5 { [System.Drawing.RotateFlipType]::Rotate90FlipX }
        6 { [System.Drawing.RotateFlipType]::Rotate90FlipNone }
        7 { [System.Drawing.RotateFlipType]::Rotate270FlipX }
        8 { [System.Drawing.RotateFlipType]::Rotate270FlipNone }
        default { $null }
    }
    if ($null -ne $rotation) { $Image.RotateFlip($rotation) }
}

function New-OcrEngine {
    param([string]$LanguageTag)
    Initialize-WinRt
    if ($LanguageTag -eq 'auto') {
        return [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    }

    $requested = New-Object Windows.Globalization.Language ($LanguageTag)
    $available = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | Where-Object {
        $_.LanguageTag -ieq $requested.LanguageTag
    })
    if ($available.Count -eq 0) { return $null }

    # TryCreateFromLanguage uses Windows language matching and may otherwise
    # resolve a removed regional pack to a related installed language.
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($available[0])
    if (-not $engine -or $engine.RecognizerLanguage.LanguageTag -ine $available[0].LanguageTag) { return $null }
    return $engine
}

function Normalize-OcrLine {
    param([string]$Text, [string]$LanguageTag)
    if ($LanguageTag -notmatch '^(zh|yue|ja)(-|$)') { return $Text }
    # Remove only the common intra-CJK OCR artifact. Fullwidth forms and Hangul
    # are deliberately excluded so their token boundaries remain intact.
    $han = '\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF'
    $kana = '\u3040-\u30FF'
    $value = [regex]::Replace($Text, "(?<=[$han])\x20(?=[$han])", '')
    return [regex]::Replace($value, "(?<=[$kana])\x20(?=[$han$kana])|(?<=[$han])\x20(?=[$kana])", '')
}

function Invoke-Ocr {
    param([System.Drawing.Bitmap]$Bitmap, [string]$LanguageTag, [bool]$JoinLines)
    $engine = New-OcrEngine $LanguageTag
    if (-not $engine) { throw [System.InvalidOperationException]::new('OCR_LANGUAGE_UNAVAILABLE') }

    $work = $Bitmap
    $ownsWork = $false
    $stream = $null
    $randomAccessStream = $null
    $softwareBitmap = $null
    try {
        $maxDimension = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
        if ($Bitmap.Width -gt $maxDimension -or $Bitmap.Height -gt $maxDimension) {
            $width, $height = Get-FittedSize $Bitmap.Width $Bitmap.Height $maxDimension
            $work = Resize-Bitmap $Bitmap $width $height
            $ownsWork = $true
        }
        elseif ($Bitmap.Height -lt 300 -and $Bitmap.Width -le [Math]::Floor($maxDimension / 2) -and $Bitmap.Height -le [Math]::Floor($maxDimension / 2)) {
            $work = Resize-Bitmap $Bitmap ([Math]::Max(1, $Bitmap.Width * 2)) ([Math]::Max(1, $Bitmap.Height * 2))
            $ownsWork = $true
        }

        # BMP avoids compressing and decompressing the image just to hand it to the decoder.
        $stream = New-Object System.IO.MemoryStream
        $work.Save($stream, [System.Drawing.Imaging.ImageFormat]::Bmp)
        $stream.Position = 0
        $randomAccessStream = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($stream)
        $decoder = Wait-WinRtOperation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($randomAccessStream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $softwareBitmap = Wait-WinRtOperation ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $result = Wait-WinRtOperation ($engine.RecognizeAsync($softwareBitmap)) ([Windows.Media.Ocr.OcrResult])
        $lines = @($result.Lines | ForEach-Object { Normalize-OcrLine $_.Text $engine.RecognizerLanguage.LanguageTag })
        $separator = if ($JoinLines) { ' ' } else { "`n" }
        Write-DebugLine 'ocr-done'
        return $lines -join $separator
    }
    finally {
        if ($softwareBitmap) { $softwareBitmap.Dispose() }
        if ($randomAccessStream) { $randomAccessStream.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($ownsWork -and $work) { $work.Dispose() }
    }
}

function Write-BarcodeImage {
    # Barcode decoding runs in the extension; send the selection as luminance bytes.
    param([System.Drawing.Bitmap]$Bitmap)
    $work = $Bitmap
    $ownsWork = $false
    try {
        $width, $height = Get-FittedSize $Bitmap.Width $Bitmap.Height $script:MaxBarcodeDimension
        if ($width -ne $Bitmap.Width -or $height -ne $Bitmap.Height) {
            $work = Resize-Bitmap $Bitmap $width $height
            $ownsWork = $true
        }
        $luminance = [Convert]::ToBase64String([ScreenOcrNative.Imaging]::ToLuminance($work))
        # Base64 contains no characters that need JSON escaping.
        Write-ProtocolText ('{"status":"image","width":' + $work.Width + ',"height":' + $work.Height + ',"luminance":"' + $luminance + '"}')
        Write-DebugLine 'barcode-image-written'
    }
    finally {
        if ($ownsWork -and $work) { $work.Dispose() }
    }
}

function Get-VirtualScreenBitmap {
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($bounds.Width -lt 1 -or $bounds.Height -lt 1) { throw 'The virtual desktop has invalid dimensions.' }
    $bitmap = New-Object System.Drawing.Bitmap ($bounds.Width, $bounds.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = $null
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bitmap.Size)
        Write-DebugLine "captured $($bounds.Width)x$($bounds.Height) at $($bounds.X),$($bounds.Y)"
        return $bitmap
    }
    catch {
        $bitmap.Dispose()
        throw
    }
    finally {
        if ($graphics) { $graphics.Dispose() }
    }
}

function Enter-CaptureMutex {
    # The Local namespace coordinates ScreenOCR processes in this interactive session.
    $mutex = [System.Threading.Mutex]::new($false, 'Local\Raycast.ScreenOCR.Capture')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0, $false) }
        # The mutex protects only the capture lifetime, so there is no shared state to recover.
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'SCREENOCR_CAPTURE_BUSY' }
        return $mutex
    }
    catch {
        if (-not $acquired) { $mutex.Dispose() }
        throw
    }
}

function Select-ScreenRegion {
    param([System.Drawing.Bitmap]$Frozen)
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $form = New-Object System.Windows.Forms.Form
    $dimBrush = $null
    $borderPen = $null
    $escapeHotKey = $null
    try {
        $form.Text = 'ScreenOCR selection'
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Bounds = $bounds
        $form.TopMost = $true
        $form.ShowInTaskbar = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::Cross
        $form.KeyPreview = $true
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
        $form.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($form, $true, $null)
        $state = @{ Dragging = $false; Start = [System.Drawing.Point]::Empty; Current = [System.Drawing.Point]::Empty; Selection = [System.Drawing.Rectangle]::Empty; Done = $false }
        $getRectangle = {
            $x = [Math]::Max(0, [Math]::Min($Frozen.Width, [Math]::Min($state.Start.X, $state.Current.X)))
            $y = [Math]::Max(0, [Math]::Min($Frozen.Height, [Math]::Min($state.Start.Y, $state.Current.Y)))
            $right = [Math]::Max(0, [Math]::Min($Frozen.Width, [Math]::Max($state.Start.X, $state.Current.X)))
            $bottom = [Math]::Max(0, [Math]::Min($Frozen.Height, [Math]::Max($state.Start.Y, $state.Current.Y)))
            New-Object System.Drawing.Rectangle ($x, $y, [Math]::Max(0, $right - $x), [Math]::Max(0, $bottom - $y))
        }
        $dimBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(120, 0, 0, 0))
        $borderPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White, 1)
        $borderPen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
        $form.Add_Paint({
            param($sender, $event)
            $event.Graphics.DrawImageUnscaled($Frozen, 0, 0)
            if ($state.Dragging) {
                $rectangle = & $getRectangle
                $outside = New-Object System.Drawing.Region ($sender.ClientRectangle)
                try { $outside.Exclude($rectangle); $event.Graphics.FillRegion($dimBrush, $outside) } finally { $outside.Dispose() }
                if ($rectangle.Width -gt 0 -and $rectangle.Height -gt 0) {
                    $event.Graphics.DrawRectangle($borderPen, $rectangle.X, $rectangle.Y, [Math]::Max(1, $rectangle.Width - 1), [Math]::Max(1, $rectangle.Height - 1))
                }
            } else { $event.Graphics.FillRectangle($dimBrush, $sender.ClientRectangle) }
        })
        $form.Add_MouseDown({
            param($sender, $event)
            if ($event.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                $state.Dragging = $true; $state.Start = $event.Location; $state.Current = $event.Location; $sender.Invalidate()
            } elseif ($event.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
                $sender.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $sender.Close()
            }
        })
        $form.Add_MouseMove({ param($sender, $event) if ($state.Dragging) { $state.Current = $event.Location; $sender.Invalidate() } })
        $form.Add_MouseUp({
            param($sender, $event)
            if ($event.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $state.Dragging) {
                $state.Dragging = $false; $state.Current = $event.Location; $state.Selection = & $getRectangle; $state.Done = $true
                $sender.DialogResult = [System.Windows.Forms.DialogResult]::OK; $sender.Close()
            }
        })
        # Fallback when the Escape hot key is unavailable and the overlay has focus.
        $form.Add_KeyDown({ param($sender, $event) if ($event.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $sender.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $sender.Close() } })
        $form.Add_Shown({
            param($sender, $event)
            $overlay = $sender
            $requestFocus = {
                if (-not $overlay.IsDisposed -and $overlay.Visible) {
                    $overlay.BringToFront()
                    $overlay.Activate()
                    [void]$overlay.Focus()
                }
            }.GetNewClosure()
            [void]$overlay.BeginInvoke([System.Action]$requestFocus)
            Write-DebugLine 'overlay-shown'
        })
        $escapeHotKey = [ScreenOcrNative.EscapeHotKey]::new($form)
        if (-not $escapeHotKey.IsRegistered) {
            Write-DebugLine "escape-hotkey unavailable (Win32 error $($escapeHotKey.LastError)); Escape works after clicking the overlay"
        }
        $dialogResult = $form.ShowDialog()
        if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK -or -not $state.Done) { return $null }
        if ($state.Selection.Width -lt 3 -or $state.Selection.Height -lt 3) { return $null }
        return $state.Selection
    }
    finally {
        if ($escapeHotKey) { $escapeHotKey.Dispose() }
        if ($dimBrush) { $dimBrush.Dispose() }
        if ($borderPen) { $borderPen.Dispose() }
        $form.Dispose()
    }
}

function Read-ClipboardPngOnce {
    # Browsers and Office also publish a PNG clipboard format that keeps transparency.
    # The standard bitmap format drops alpha, which can turn dark text on a transparent
    # background into black on black.
    if (-not [System.Windows.Forms.Clipboard]::ContainsData('PNG')) { return $null }
    $data = [System.Windows.Forms.Clipboard]::GetData('PNG')
    if ($data -isnot [System.IO.Stream]) { return $null }
    $image = $null
    try {
        if ($data.Length -gt $script:MaxClipboardFileBytes) { return @{ Kind = 'too-large' } }
        $data.Position = 0
        $image = [System.Drawing.Image]::FromStream($data, $true, $true)
        return @{ Kind = 'image'; Bitmap = (New-CompatibleBitmap $image) }
    }
    catch {
        if ($_.Exception.Message -eq 'SCREENOCR_IMAGE_TOO_LARGE') { return @{ Kind = 'too-large' } }
        # Fall back to the standard bitmap format.
        return $null
    }
    finally {
        if ($image) { $image.Dispose() }
        $data.Dispose()
    }
}

function Read-ClipboardBitmapOnce {
    $png = Read-ClipboardPngOnce
    if ($png) { return $png }
    if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
        $image = [System.Windows.Forms.Clipboard]::GetImage()
        if ($image) {
            try {
                try { return @{ Kind = 'image'; Bitmap = (New-CompatibleBitmap $image) } }
                catch {
                    if ($_.Exception.Message -eq 'SCREENOCR_IMAGE_TOO_LARGE') { return @{ Kind = 'too-large' } }
                    return @{ Kind = 'corrupt' }
                }
            }
            finally { $image.Dispose() }
        }
    }
    if (-not [System.Windows.Forms.Clipboard]::ContainsFileDropList()) { return @{ Kind = 'empty' } }
    $files = [System.Windows.Forms.Clipboard]::GetFileDropList()
    $supported = @('.bmp', '.gif', '.jpe', '.jfif', '.jpg', '.jpeg', '.png', '.tif', '.tiff')
    $foundUnsupported = $false
    $foundTooLarge = $false
    $foundUnreadable = $false
    $foundCorrupt = $false
    foreach ($file in $files) {
        $extension = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
        if ($supported -notcontains $extension) { $foundUnsupported = $true; continue }
        $stream = $null
        $image = $null
        try {
            try {
                $stream = New-Object System.IO.FileStream ($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
                if ($stream.Length -gt $script:MaxClipboardFileBytes) { $foundTooLarge = $true; continue }
            }
            catch {
                $foundUnreadable = $true
                continue
            }
            try {
                $image = [System.Drawing.Image]::FromStream($stream, $true, $true)
                Set-ImageOrientation $image
                return @{ Kind = 'image'; Bitmap = (New-CompatibleBitmap $image) }
            }
            catch {
                if ($_.Exception.Message -eq 'SCREENOCR_IMAGE_TOO_LARGE') { $foundTooLarge = $true }
                else { $foundCorrupt = $true }
            }
        }
        finally { if ($image) { $image.Dispose() }; if ($stream) { $stream.Dispose() } }
    }
    if ($foundTooLarge) { return @{ Kind = 'too-large' } }
    if ($foundUnreadable) { return @{ Kind = 'unreadable' } }
    if ($foundCorrupt) { return @{ Kind = 'corrupt' } }
    if ($foundUnsupported) { return @{ Kind = 'unsupported' } }
    return @{ Kind = 'empty' }
}

function Get-ClipboardBitmap {
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        try { return Read-ClipboardBitmapOnce }
        catch [System.Runtime.InteropServices.ExternalException] {
            if ($attempt -eq 5) { throw 'SCREENOCR_CLIPBOARD_BUSY' }
            Start-Sleep -Milliseconds 50
        }
    }
}

$exitCode = 0
try {
    if (-not $ListLanguages -and -not $Mode) { throw 'Mode is required.' }

    if ($ListLanguages) {
        Initialize-WinRt
        $available = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object {
            @{ tag = $_.LanguageTag; displayName = $_.DisplayName }
        })
        Write-ProtocolJson @{ status = 'languages'; languages = $available }
        exit 0
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Write-DebugLine 'forms-ready'
    $capturesScreen = $Mode -ne 'clipboard'
    if ($capturesScreen) {
        Initialize-NativeMethods
        Enable-DpiAwareness
    }
    else {
        Initialize-WinRt
    }

    $bitmap = $null
    try {
        $captureMutex = $null
        try {
            if ($capturesScreen) {
                $captureMutex = Enter-CaptureMutex
            }
            if ($Mode -eq 'area' -or $Mode -eq 'barcode') {
                $frozen = Get-VirtualScreenBitmap
                try {
                    $selection = Select-ScreenRegion $frozen
                    if (-not $selection) { throw 'SCREENOCR_CANCELLED' }
                    $bitmap = $frozen.Clone($selection, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                    Write-DebugLine "selected $($selection.Width)x$($selection.Height)"
                } finally { $frozen.Dispose() }
            } elseif ($Mode -eq 'fullscreen') {
                $bitmap = Get-VirtualScreenBitmap
            } else {
                $clipboard = Get-ClipboardBitmap
                if ($clipboard.Kind -ne 'image') {
                    throw "SCREENOCR_CLIPBOARD_$($clipboard.Kind.ToUpperInvariant())"
                }
                $bitmap = $clipboard.Bitmap
            }
        }
        finally {
            # The overlay is closed and the captured pixels are independent of the screen.
            # Allow the next capture while this bitmap is processed.
            if ($captureMutex) {
                try { $captureMutex.ReleaseMutex() }
                finally { $captureMutex.Dispose() }
            }
        }
        if ($Mode -eq 'barcode') {
            Write-BarcodeImage $bitmap
        }
        else {
            $text = Invoke-Ocr $bitmap $Language $IgnoreLineBreaks.IsPresent
            if ([string]::IsNullOrWhiteSpace($text)) { Write-ProtocolJson @{ status = 'no-text' } }
            else { Write-ProtocolJson @{ status = 'recognized'; text = $text } }
        }
    }
    finally {
        if ($bitmap) { $bitmap.Dispose() }
    }
}
catch {
    $clipboardCodes = @{
        'SCREENOCR_CLIPBOARD_EMPTY' = 'clipboard-empty'
        'SCREENOCR_CLIPBOARD_UNSUPPORTED' = 'clipboard-unsupported'
        'SCREENOCR_CLIPBOARD_CORRUPT' = 'clipboard-corrupt'
        'SCREENOCR_CLIPBOARD_BUSY' = 'clipboard-busy'
        'SCREENOCR_CLIPBOARD_TOO-LARGE' = 'clipboard-too-large'
        'SCREENOCR_CLIPBOARD_UNREADABLE' = 'clipboard-unreadable'
    }
    $message = $_.Exception.Message
    if ($message -eq 'SCREENOCR_CANCELLED') { $exitCode = 2 }
    elseif ($message -eq 'OCR_LANGUAGE_UNAVAILABLE') { $exitCode = 3 }
    elseif ($clipboardCodes.ContainsKey($message)) {
        Write-ProtocolJson @{ status = 'error'; code = $clipboardCodes[$message] }; $exitCode = 4
    }
    elseif ($message -eq 'SCREENOCR_CAPTURE_BUSY') {
        Write-ProtocolJson @{ status = 'error'; code = 'capture-busy' }; $exitCode = 6
    }
    else { $exitCode = 5; [Console]::Error.WriteLine($_.Exception.ToString()) }
}
exit $exitCode
