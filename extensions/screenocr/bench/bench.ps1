# Fork-only timing benchmark: published helper vs PR helper. Not for upstream.
param([int]$Runs = 7)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$bmp = New-Object System.Drawing.Bitmap 900, 160
$g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::White)
$g.DrawString('ScreenOCR benchmark text 12345', (New-Object System.Drawing.Font 'Arial', 32), [System.Drawing.Brushes]::Black, 10, 50)
[System.Windows.Forms.Clipboard]::SetDataObject($bmp, $true)
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$base = @('-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass')
$cases = [ordered]@{
  'powershell start only'           = @('-Command','exit')
  'Add-Type tiny C# class'          = @('-Command',"Add-Type -TypeDefinition 'public class BenchX { }'")
  'published: clipboard OCR'        = @('-File',"$PSScriptRoot\ocr-published.ps1",'-Mode','clipboard','-Language','auto')
  'PR: clipboard OCR'               = @('-File',"$PSScriptRoot\..\assets\ocr.ps1",'-Mode','clipboard','-Language','auto')
  'published: list languages'       = @('-File',"$PSScriptRoot\ocr-published.ps1",'-ListLanguages')
  'PR: list languages'              = @('-File',"$PSScriptRoot\..\assets\ocr.ps1",'-ListLanguages')
}
$ErrorActionPreference = 'Continue'
foreach ($name in $cases.Keys) {
  $ms = @(); $out = ''
  for ($i = 0; $i -lt $Runs; $i++) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & $ps @base @($cases[$name]) 2>$null
    $sw.Stop(); $ms += [int]$sw.ElapsedMilliseconds
  }
  $sorted = $ms | Sort-Object
  "{0,-30} median {1,5} ms  min {2,5}  max {3,5}  runs: {4}" -f $name, $sorted[[int][Math]::Floor($Runs/2)], $sorted[0], $sorted[-1], ($ms -join ',')
  "    output: " + (("$out") -replace '\s+',' ').Substring(0, [Math]::Min(110, ("$out").Length))
}
$env:SCREENOCR_DEBUG = '1'
"--- PR helper phase timings (SCREENOCR_DEBUG=1, clipboard) ---"
& $ps @base -File "$PSScriptRoot\..\assets\ocr.ps1" -Mode clipboard -Language auto 2>&1 | ForEach-Object { "    $_" }
