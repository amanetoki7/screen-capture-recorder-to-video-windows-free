<#
.SYNOPSIS
  Visual monitor selector for screen-capture-recorder.
.DESCRIPTION
  Shows, on every monitor, the number that capture_particular_display_number_starting_at_zero expects: the order
  EnumDisplayMonitors returns the monitors in, which is what the capture filter uses (PushSourceDesktop.cpp,
  Monitorenumproc) and not necessarily the number windows' display settings show.
  Click the monitor you want to capture (or pick it in the list) and the settings get written the same way the
  filter reads them: to %APPDATA%\ScreenCaptureRecorder.ini when that file exists, otherwise to
  HKEY_CURRENT_USER\Software\screen-capture-recorder.
  It can also set up letterboxing/pillarboxing (stretch_to_width/height +
  stretch_keep_aspect_ratio_with_black_bars_if_1), so a 16:10 monitor ends up as a 16:9 recording with black bars
  instead of a squished picture.
  Sizes: the monitor's real resolution is what DPI aware capture programs (most current ones, ffmpeg and vlc included)
  see, and that is what gets written. A DPI unaware program sees a monitor that windows scales as a smaller one
  (ex: 2560x1600 at 150% looks like 1707x1067 to it, and the filter inside it captures that), so for those tick
  "sizes for DPI unaware programs" / pass -LogicalSizes.
.EXAMPLE
  select_monitor.bat                           the GUI
  select_monitor.bat -List                     just print the monitors and the current settings
  select_monitor.bat -Use 1                    capture monitor 1 at its native size, no GUI
  select_monitor.bat -Use 1 -FitTo 2560x1440   ...fitted into 2560x1440 with black bars
  select_monitor.bat -Use 1 -LogicalSizes      ...with the sizes a DPI unaware program sees
  select_monitor.bat -Reset                    remove the settings this tool writes (back to capturing the whole desktop)
#>
param(
  [switch] $List,
  [int] $Use = -1,
  [string] $FitTo = '',
  [switch] $LogicalSizes,
  [switch] $Reset,
  [switch] $SelfTest   # builds the GUI and closes it again right away (smoke test)
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class ScrMonitor {
  public int Index;
  public string Device;
  public bool Primary;
  public int Left, Top, Right, Bottom;  // as EnumDisplayMonitors reports them to this (DPI unaware) process
  public int PhysWidth, PhysHeight;     // the monitor's real resolution (EnumDisplaySettings): what DPI aware programs see
  public int Width  { get { return Right - Left; } }  // what DPI unaware programs see (smaller when windows scales this monitor)
  public int Height { get { return Bottom - Top; } }
  public bool Scaled { get { return PhysWidth != Width || PhysHeight != Height; } }
  public int ScalePercent { get { return Width == 0 ? 100 : (int) Math.Round(100.0 * PhysWidth / Width); } }
}

public static class ScrNative {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int left, top, right, bottom; }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct MONITORINFOEX {
    public int cbSize;
    public RECT rcMonitor;
    public RECT rcWork;
    public uint dwFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
  }

  public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);

  [DllImport("user32.dll")]
  static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public uint dmFields;
    public int dmPositionX, dmPositionY;
    public uint dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public ushort dmLogPixels;
    public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern bool EnumDisplaySettingsW(string deviceName, int modeNum, ref DEVMODE devMode);
  [DllImport("user32.dll")]
  static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool WritePrivateProfileString(string section, string key, string value, string file);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetPrivateProfileInt(string section, string key, int def, string file);

  // see the sizes the way the (DPI unaware) capturing programs, and so the filter, see them. Best effort: it fails
  // when the host process already declared an awareness in its manifest.
  public static void TryMakeDpiUnaware() {
    try { SetProcessDpiAwarenessContext(new IntPtr(-1)); } catch (Exception) { } // DPI_AWARENESS_CONTEXT_UNAWARE
  }

  // same order as the capture filter's EnumDisplayMonitors callback, so Index is what
  // capture_particular_display_number_starting_at_zero expects
  public static List<ScrMonitor> ListMonitors() {
    List<ScrMonitor> result = new List<ScrMonitor>();
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr h, IntPtr hdc, ref RECT r, IntPtr d) {
      MONITORINFOEX mi = new MONITORINFOEX();
      mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
      GetMonitorInfo(h, ref mi);
      ScrMonitor m = new ScrMonitor();
      m.Index = result.Count;
      m.Device = mi.szDevice;
      m.Primary = (mi.dwFlags & 1) != 0;
      m.Left = mi.rcMonitor.left; m.Top = mi.rcMonitor.top; m.Right = mi.rcMonitor.right; m.Bottom = mi.rcMonitor.bottom;
      DEVMODE dm = new DEVMODE();
      dm.dmSize = (ushort) Marshal.SizeOf(typeof(DEVMODE));
      if (EnumDisplaySettingsW(mi.szDevice, -1, ref dm)) { m.PhysWidth = (int) dm.dmPelsWidth; m.PhysHeight = (int) dm.dmPelsHeight; } // -1: ENUM_CURRENT_SETTINGS
      else { m.PhysWidth = m.Width; m.PhysHeight = m.Height; }
      result.Add(m);
      return true;
    }, IntPtr.Zero);
    return result;
  }
}
"@
[ScrNative]::TryMakeDpiUnaware()
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# --- settings, read/written the way DibHelper.cpp read_config_setting does ---------------------------------------

$script:IniPath = Join-Path $env:APPDATA 'ScreenCaptureRecorder.ini'
$script:IniSection = 'all_settings'
$script:RegPath = 'HKCU:\Software\screen-capture-recorder'
$script:DisplaySetting = 'capture_particular_display_number_starting_at_zero'
$script:BarsSetting = 'stretch_keep_aspect_ratio_with_black_bars_if_1'
# everything this tool may write (so -Reset knows what to remove)
$script:ToolSettings = @($script:DisplaySetting, 'capture_width', 'capture_height', 'stretch_to_width', 'stretch_to_height', $script:BarsSetting)

function Test-IniStore { Test-Path -LiteralPath $script:IniPath }

function Get-StoreDescription {
  if (Test-IniStore) { "$script:IniPath (while this file exists the filter ignores the registry)" }
  else { "registry $script:RegPath (no $script:IniPath present)" }
}

function Get-Setting([string] $name) {
  if (Test-IniStore) {
    $v = [ScrNative]::GetPrivateProfileInt($script:IniSection, $name, -777, $script:IniPath)
    if ($v -eq -777) { return $null }
    return $v
  }
  $p = Get-ItemProperty -Path $script:RegPath -Name $name -ErrorAction SilentlyContinue
  if ($null -eq $p) { return $null }
  $v = [int64] $p.$name
  if ($v -gt 2147483647) { $v -= 4294967296 } # DWORD holding a negative
  return [int] $v
}

function Set-Setting([string] $name, [int] $value) {
  if (Test-IniStore) {
    if (-not [ScrNative]::WritePrivateProfileString($script:IniSection, $name, [string] $value, $script:IniPath)) {
      throw "could not write $name to $script:IniPath"
    }
  } else {
    if (-not (Test-Path $script:RegPath)) { New-Item -Path $script:RegPath -Force | Out-Null }
    New-ItemProperty -Path $script:RegPath -Name $name -Value $value -PropertyType DWord -Force | Out-Null
  }
}

function Remove-Setting([string] $name) {
  if (Test-IniStore) {
    # a NULL value deletes the key. Powershell would turn $null into "" (which leaves a "name=" line the filter reads as 0), hence NullString
    [ScrNative]::WritePrivateProfileString($script:IniSection, $name, [NullString]::Value, $script:IniPath) | Out-Null
  } elseif (Test-Path $script:RegPath) {
    Remove-ItemProperty -Path $script:RegPath -Name $name -ErrorAction SilentlyContinue
  }
}

function Get-CurrentSummary {
  $parts = @()
  foreach ($n in $script:ToolSettings) { $v = Get-Setting $n; if ($null -ne $v) { $parts += "$n=$v" } }
  if ($parts.Count -eq 0) { return 'nothing set: the whole desktop (primary monitor size) gets captured' }
  return ($parts -join '  ')
}

# the capture size to write for monitor $m: its real resolution, or what DPI unaware programs see of it
function Get-CaptureSize([object] $m, [bool] $logicalSizes) {
  if ($logicalSizes) { return @($m.Width, $m.Height) }
  return @($m.PhysWidth, $m.PhysHeight)
}

# writes the settings for capturing monitor $m. $outputMode: 'native' (no stretching), 'fit' (into $fitW x $fitH with
# black bars) or 'keep' (leave any stretch_to_* settings alone)
function Use-Monitor([object] $m, [string] $outputMode, [int] $fitW, [int] $fitH, [bool] $logicalSizes) {
  $size = Get-CaptureSize $m $logicalSizes
  Set-Setting $script:DisplaySetting $m.Index
  Set-Setting 'capture_width' $size[0]
  Set-Setting 'capture_height' $size[1]
  $removed = @()
  # start_x/start_y get overridden by the monitor's position anyway, and would fight it with track_new_x_y_coords_each_frame_if_1
  foreach ($n in 'start_x', 'start_y') { if ($null -ne (Get-Setting $n)) { Remove-Setting $n; $removed += $n } }
  switch ($outputMode) {
    'native' {
      foreach ($n in 'stretch_to_width', 'stretch_to_height', $script:BarsSetting) {
        if ($null -ne (Get-Setting $n)) { Remove-Setting $n; $removed += $n }
      }
    }
    'fit' {
      Set-Setting 'stretch_to_width' $fitW
      Set-Setting 'stretch_to_height' $fitH
      Set-Setting $script:BarsSetting 1
    }
  }
  $msg = "monitor $($m.Index) ($($m.Device), $($size[0])x$($size[1])) will be captured"
  if ($outputMode -eq 'fit') { $msg += ", fitted into ${fitW}x${fitH} with black bars" }
  if ($removed.Count -gt 0) { $msg += "; removed " + ($removed -join ', ') }
  return $msg
}

function Reset-MonitorSelection {
  $removed = @()
  foreach ($n in $script:ToolSettings) { if ($null -ne (Get-Setting $n)) { Remove-Setting $n; $removed += $n } }
  if ($removed.Count -gt 0) { return "removed " + ($removed -join ', ') + ": the whole desktop gets captured again" }
  return 'nothing to remove, the whole desktop gets captured'
}

# 16:9 output sizes that make sense for a $width x $height capture (the combo box is editable, any WxH works)
function Get-FitCandidates([int] $width, [int] $height) {
  $even = { param($n) $n = [int] [math]::Round($n); if ($n % 2 -ne 0) { $n-- }; $n }
  $h = & $even ($width * 9 / 16)
  $w = & $even ($height * 16 / 9)
  return @(
    ("{0}x{1}  (same width, 16:9)" -f $width, $h),
    ("{0}x{1}  (same height, 16:9, picture not scaled)" -f $w, $height),
    '1920x1080  (16:9)',
    '1280x720  (16:9)'
  )
}

function ConvertTo-Size([string] $text) {
  if ($text -match '^\s*(\d+)\s*[xX]\s*(\d+)') { return @([int] $matches[1], [int] $matches[2]) }
  return $null
}

function Find-Ffmpeg {
  $vendored = Join-Path $PSScriptRoot 'vendor\ffmpeg\bin\ffmpeg.exe'
  if (Test-Path $vendored) { return $vendored }
  $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

# grabs one frame through the filter, so you can see what the settings do
function Invoke-TestCapture {
  $ffmpeg = Find-Ffmpeg
  if (-not $ffmpeg) { throw 'ffmpeg.exe not found (neither in vendor\ffmpeg\bin nor on the PATH)' }
  $png = Join-Path $env:TEMP 'screen-capture-recorder-test.png'
  $log = Join-Path $env:TEMP 'screen-capture-recorder-test.log'
  if (Test-Path $png) { Remove-Item $png }
  $p = Start-Process -FilePath $ffmpeg -ArgumentList @('-y', '-loglevel', 'error', '-f', 'dshow', '-i', 'video=screen-capture-recorder', '-vframes', '1', "`"$png`"") `
    -WindowStyle Hidden -Wait -PassThru -RedirectStandardError $log
  if ($p.ExitCode -ne 0 -or -not (Test-Path $png)) { throw ("ffmpeg failed:`n" + (Get-Content $log -Raw)) }
  Start-Process $png
  return "test frame saved to $png (opened in your image viewer)"
}

# --- GUI --------------------------------------------------------------------------------------------------------

function New-Overlay([object] $m) {
  $o = New-Object System.Windows.Forms.Form
  $o.FormBorderStyle = 'None'
  $o.ShowInTaskbar = $false
  $o.TopMost = $true
  $o.StartPosition = 'Manual'
  $o.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)
  $o.Opacity = 0.9
  $o.Cursor = [System.Windows.Forms.Cursors]::Hand
  $w = [int] ($m.Width * 0.4)
  $h = [int] ($m.Height * 0.4)
  $o.Location = New-Object System.Drawing.Point([int] ($m.Left + ($m.Width - $w) / 2), [int] ($m.Top + ($m.Height - $h) / 2))
  $o.Size = New-Object System.Drawing.Size($w, $h)

  $big = New-Object System.Windows.Forms.Label
  $big.Bounds = New-Object System.Drawing.Rectangle(0, 0, $w, ($h - 70))
  $big.TextAlign = 'MiddleCenter'
  $big.ForeColor = [System.Drawing.Color]::White
  $big.Font = New-Object System.Drawing.Font('Segoe UI', [float] ($h * 0.5), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $big.Text = "$($m.Index)"
  $big.Cursor = $o.Cursor

  $small = New-Object System.Windows.Forms.Label
  $small.Bounds = New-Object System.Drawing.Rectangle(0, ($h - 70), $w, 70)
  $small.TextAlign = 'MiddleCenter'
  $small.ForeColor = [System.Drawing.Color]::Gainsboro
  $small.Font = New-Object System.Drawing.Font('Segoe UI', 14)
  $small.Text = (Get-OverlayCaption $m) + "`nclick to capture this monitor"
  $small.Cursor = $o.Cursor

  $o.Controls.Add($big)
  $o.Controls.Add($small)
  $o.Tag = $m
  $onClick = { Select-MonitorInList $m.Index }.GetNewClosure()
  $o.Add_Click($onClick)
  $big.Add_Click($onClick)
  $small.Add_Click($onClick)
  return $o
}

function Get-OverlayCaption([object] $m) {
  $caption = "$($m.Device)   $($m.PhysWidth)x$($m.PhysHeight)"
  if ($m.Scaled) { $caption += "  (scaled $($m.ScalePercent)%: $($m.Width)x$($m.Height) for DPI unaware programs)" }
  return $caption
}

function Select-MonitorInList([int] $index) {
  foreach ($item in $script:lv.Items) { $item.Selected = ($item.Tag.Index -eq $index) }
  if ($script:lv.SelectedItems.Count -gt 0) { $script:lv.SelectedItems[0].Focused = $true }
  $script:lv.Select()
  $script:form.Activate()
}

function Get-SelectedMonitor {
  if ($script:lv.SelectedItems.Count -eq 0) { return $null }
  return $script:lv.SelectedItems[0].Tag
}

function Update-CurrentDisplay {
  $current = Get-Setting $script:DisplaySetting
  foreach ($item in $script:lv.Items) {
    $item.SubItems[6].Text = if ($null -ne $current -and $item.Tag.Index -eq $current) { 'capturing this one' } else { '' }
  }
  foreach ($o in $script:overlays) {
    $m = $o.Tag
    $suffix = if ($null -ne $current -and $m.Index -eq $current) { 'currently captured' } else { 'click to capture this monitor' }
    $o.Controls[1].Text = (Get-OverlayCaption $m) + "`n$suffix"
  }
  $script:currentLabel.Text = 'current settings: ' + (Get-CurrentSummary)
}

function Update-FitCandidates {
  $m = Get-SelectedMonitor
  if ($null -eq $m) { return }
  $keep = $script:fitCombo.Text
  $size = Get-CaptureSize $m $script:logicalCheck.Checked
  $script:fitCombo.Items.Clear()
  foreach ($c in Get-FitCandidates $size[0] $size[1]) { [void] $script:fitCombo.Items.Add($c) }
  if ($keep -and (ConvertTo-Size $keep)) { $script:fitCombo.Text = $keep } else { $script:fitCombo.SelectedIndex = 0 }
}

function Show-Status([string] $text, [bool] $isError) {
  $script:status.Text = $text
  $script:status.ForeColor = if ($isError) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::DarkGreen }
}

function Show-Gui([object[]] $monitors, [bool] $selfTest) {
  [System.Windows.Forms.Application]::EnableVisualStyles()

  $form = New-Object System.Windows.Forms.Form
  $script:form = $form
  $form.Text = 'screen-capture-recorder: select the monitor to capture'
  $form.StartPosition = 'CenterScreen'
  $form.ClientSize = New-Object System.Drawing.Size(760, 566)
  $form.MinimumSize = New-Object System.Drawing.Size(640, 500)
  $form.TopMost = $true
  $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

  $intro = New-Object System.Windows.Forms.Label
  $intro.Bounds = New-Object System.Drawing.Rectangle(12, 10, 736, 40)
  $intro.Text = "Every monitor is showing its number right now: the order the capture filter numbers them in (EnumDisplayMonitors), which is not necessarily what windows' display settings call it.`nClick the number on the monitor you want to capture, or pick it below."
  $form.Controls.Add($intro)

  $lv = New-Object System.Windows.Forms.ListView
  $script:lv = $lv
  $lv.Bounds = New-Object System.Drawing.Rectangle(12, 56, 736, 150)
  $lv.Anchor = 'Top, Left, Right'
  $lv.View = 'Details'
  $lv.FullRowSelect = $true
  $lv.MultiSelect = $false
  $lv.HideSelection = $false
  [void] $lv.Columns.Add('#', 36)
  [void] $lv.Columns.Add('device', 100)
  [void] $lv.Columns.Add('size', 90)
  [void] $lv.Columns.Add('DPI unaware programs see', 160)
  [void] $lv.Columns.Add('position (left, top)', 120)
  [void] $lv.Columns.Add('primary', 60)
  [void] $lv.Columns.Add('', 150)
  foreach ($m in $monitors) {
    $item = New-Object System.Windows.Forms.ListViewItem("$($m.Index)")
    [void] $item.SubItems.Add($m.Device)
    [void] $item.SubItems.Add("$($m.PhysWidth)x$($m.PhysHeight)")
    [void] $item.SubItems.Add($(if ($m.Scaled) { "$($m.Width)x$($m.Height)  (scaled $($m.ScalePercent)%)" } else { 'the same' }))
    [void] $item.SubItems.Add("$($m.Left), $($m.Top)")
    [void] $item.SubItems.Add($(if ($m.Primary) { 'primary' } else { '' }))
    [void] $item.SubItems.Add('')
    $item.Tag = $m
    [void] $lv.Items.Add($item)
  }
  $form.Controls.Add($lv)

  $group = New-Object System.Windows.Forms.GroupBox
  $group.Bounds = New-Object System.Drawing.Rectangle(12, 216, 736, 156)
  $group.Anchor = 'Top, Left, Right'
  $group.Text = 'output size'
  $form.Controls.Add($group)

  $radioNative = New-Object System.Windows.Forms.RadioButton
  $radioNative.Bounds = New-Object System.Drawing.Rectangle(14, 24, 700, 22)
  $radioNative.Text = "the monitor's own size (no stretching; removes any stretch_to_width/height)"
  $group.Controls.Add($radioNative)

  $radioFit = New-Object System.Windows.Forms.RadioButton
  $script:radioFit = $radioFit
  $radioFit.Bounds = New-Object System.Drawing.Rectangle(14, 50, 240, 22)
  $radioFit.Text = 'fit into 16:9 with black bars:'
  $group.Controls.Add($radioFit)

  $fitCombo = New-Object System.Windows.Forms.ComboBox
  $script:fitCombo = $fitCombo
  $fitCombo.Bounds = New-Object System.Drawing.Rectangle(260, 49, 380, 24)
  $fitCombo.DropDownStyle = 'DropDown'
  $group.Controls.Add($fitCombo)

  $fitHint = New-Object System.Windows.Forms.Label
  $fitHint.Bounds = New-Object System.Drawing.Rectangle(32, 76, 700, 20)
  $fitHint.Text = '(any WxH works: the picture is scaled to fit, centered, the rest is black. Needs the dll from 0.14.0 or newer)'
  $fitHint.ForeColor = [System.Drawing.Color]::DimGray
  $group.Controls.Add($fitHint)

  $radioKeep = New-Object System.Windows.Forms.RadioButton
  $script:radioKeep = $radioKeep
  $radioKeep.Bounds = New-Object System.Drawing.Rectangle(14, 100, 700, 22)
  $radioKeep.Text = 'leave the stretch_to_* settings as they are'
  $group.Controls.Add($radioKeep)

  $logicalCheck = New-Object System.Windows.Forms.CheckBox
  $script:logicalCheck = $logicalCheck
  $logicalCheck.Bounds = New-Object System.Drawing.Rectangle(14, 126, 700, 22)
  $anyScaled = @($monitors | Where-Object { $_.Scaled }).Count -gt 0
  if ($anyScaled) {
    $logicalCheck.Text = 'write the sizes DPI unaware programs see (only if your capturing program is one; ffmpeg, vlc, obs are not)'
  } else {
    $logicalCheck.Text = 'write the sizes DPI unaware programs see (no monitor is scaled, so it makes no difference)'
    $logicalCheck.Enabled = $false
  }
  $group.Controls.Add($logicalCheck)

  $storeLabel = New-Object System.Windows.Forms.Label
  $storeLabel.Bounds = New-Object System.Drawing.Rectangle(12, 380, 736, 20)
  $storeLabel.Anchor = 'Top, Left, Right'
  $storeLabel.Text = 'settings go to: ' + (Get-StoreDescription)
  $form.Controls.Add($storeLabel)

  $currentLabel = New-Object System.Windows.Forms.Label
  $script:currentLabel = $currentLabel
  $currentLabel.Bounds = New-Object System.Drawing.Rectangle(12, 402, 736, 40)
  $currentLabel.Anchor = 'Top, Left, Right'
  $form.Controls.Add($currentLabel)

  $useButton = New-Object System.Windows.Forms.Button
  $useButton.Bounds = New-Object System.Drawing.Rectangle(12, 450, 200, 32)
  $useButton.Text = 'capture the selected monitor'
  $form.Controls.Add($useButton)

  $resetButton = New-Object System.Windows.Forms.Button
  $resetButton.Bounds = New-Object System.Drawing.Rectangle(220, 450, 190, 32)
  $resetButton.Text = 'reset (whole desktop again)'
  $form.Controls.Add($resetButton)

  $testButton = New-Object System.Windows.Forms.Button
  $testButton.Bounds = New-Object System.Drawing.Rectangle(418, 450, 200, 32)
  $testButton.Text = 'test: grab one frame (ffmpeg)'
  $testButton.Enabled = ($null -ne (Find-Ffmpeg))
  $form.Controls.Add($testButton)

  $closeButton = New-Object System.Windows.Forms.Button
  $closeButton.Bounds = New-Object System.Drawing.Rectangle(658, 450, 90, 32)
  $closeButton.Anchor = 'Top, Right'
  $closeButton.Text = 'close'
  $form.Controls.Add($closeButton)
  $form.CancelButton = $closeButton

  $status = New-Object System.Windows.Forms.Label
  $script:status = $status
  $status.Bounds = New-Object System.Drawing.Rectangle(12, 492, 736, 60)
  $status.Anchor = 'Top, Left, Right'
  $form.Controls.Add($status)

  # initial state from the current settings
  $current = Get-Setting $script:DisplaySetting
  $selectIndex = 0
  if ($null -ne $current -and $current -ge 0 -and $current -lt $monitors.Count) { $selectIndex = $current }
  $lv.Items[$selectIndex].Selected = $true
  if ($null -ne (Get-Setting $script:BarsSetting)) {
    $radioFit.Checked = $true
    $sw = Get-Setting 'stretch_to_width'; $sh = Get-Setting 'stretch_to_height'
    if ($sw -and $sh) { $fitCombo.Text = "${sw}x${sh}" }
  } elseif ($null -ne (Get-Setting 'stretch_to_width') -or $null -ne (Get-Setting 'stretch_to_height')) {
    $radioKeep.Checked = $true
  } else {
    $radioNative.Checked = $true
  }
  Update-FitCandidates

  $lv.Add_SelectedIndexChanged({ Update-FitCandidates })
  $logicalCheck.Add_CheckedChanged({ Update-FitCandidates })
  $fitCombo.Add_Enter({ $script:radioFit.Checked = $true })

  $useButton.Add_Click({
    try {
      $m = Get-SelectedMonitor
      if ($null -eq $m) { throw 'pick a monitor first' }
      $mode = 'native'
      $fitW = 0; $fitH = 0
      if ($script:radioFit.Checked) {
        $size = ConvertTo-Size $script:fitCombo.Text
        if ($null -eq $size) { throw "enter the output size as WIDTHxHEIGHT, ex: 1920x1080 (got '$($script:fitCombo.Text)')" }
        $mode = 'fit'; $fitW = $size[0]; $fitH = $size[1]
      } elseif ($script:radioKeep.Checked) { $mode = 'keep' }
      Show-Status (Use-Monitor $m $mode $fitW $fitH $script:logicalCheck.Checked) $false
      Update-CurrentDisplay
    } catch { Show-Status $_.Exception.Message $true }
  })

  $resetButton.Add_Click({
    try { Show-Status (Reset-MonitorSelection) $false; Update-CurrentDisplay }
    catch { Show-Status $_.Exception.Message $true }
  })

  $testButton.Add_Click({
    try {
      Show-Status 'grabbing a frame...' $false
      $script:form.Refresh()
      Show-Status (Invoke-TestCapture) $false
    } catch { Show-Status $_.Exception.Message $true }
  })

  $closeButton.Add_Click({ $script:form.Close() })

  $script:overlays = @()
  foreach ($m in $monitors) { $script:overlays += New-Overlay $m }
  $form.Add_FormClosed({ foreach ($o in $script:overlays) { $o.Close() } })
  Update-CurrentDisplay
  foreach ($o in $script:overlays) { $o.Show() }

  if ($selfTest) {
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1500
    $timer.Add_Tick({ $script:form.Close() })
    $timer.Start()
  }
  [System.Windows.Forms.Application]::Run($form)
}

# --- main -------------------------------------------------------------------------------------------------------

$monitors = @([ScrNative]::ListMonitors())
if ($monitors.Count -eq 0) { throw 'EnumDisplayMonitors returned no monitors?' }

if ($List) {
  "idx  device          size        DPI unaware programs see  position (left,top)  primary"
  foreach ($m in $monitors) {
    $logical = if ($m.Scaled) { "$($m.Width)x$($m.Height) ($($m.ScalePercent)%)" } else { 'the same' }
    "{0,-4} {1,-15} {2,-11} {3,-25} {4,-20} {5}" -f $m.Index, $m.Device, "$($m.PhysWidth)x$($m.PhysHeight)", $logical, "$($m.Left),$($m.Top)", $(if ($m.Primary) { 'primary' } else { '' })
  }
  ""
  "settings store: " + (Get-StoreDescription)
  "current: " + (Get-CurrentSummary)
  exit 0
}

if ($Reset) { Reset-MonitorSelection; exit 0 }

if ($Use -ge 0) {
  if ($Use -ge $monitors.Count) { throw "there is no monitor $Use, only 0..$($monitors.Count - 1) (see -List)" }
  $mode = 'native'; $fitW = 0; $fitH = 0
  if ($FitTo) {
    $size = ConvertTo-Size $FitTo
    if ($null -eq $size) { throw "-FitTo wants WIDTHxHEIGHT, ex: -FitTo 2560x1440" }
    $mode = 'fit'; $fitW = $size[0]; $fitH = $size[1]
  }
  Use-Monitor $monitors[$Use] $mode $fitW $fitH $LogicalSizes.IsPresent
  exit 0
}

Show-Gui $monitors $SelfTest.IsPresent
