#requires -version 5.1
<#
.SYNOPSIS
    Move the Coopanion desktop pet ("Cortico") window to another display.

.DESCRIPTION
    Coopanion's pet window only ever covers one display, so the pet cannot walk
    onto your other monitors. This script moves that window with SetWindowPos,
    without touching a single byte of Coopanion itself.

    The host window is a borderless, non-resizable Electron window. It moves fine;
    its size cannot be changed from outside. On displays with a different DPI
    scale Windows rescales it to keep its DIP size, so after a move the window can
    end up narrower or wider than the display it is on. The pet still ends up
    standing in the right place - see README for the details.

.PARAMETER To
    Display index, counting from the leftmost display as 1.

.PARAMETER Next
    Step one display to the right. Does nothing on the rightmost display.

.PARAMETER Prev
    Step one display to the left. Does nothing on the leftmost display.

.PARAMETER List
    Print the displays and the pet window, then exit. Nothing is moved.

.PARAMETER DryRun
    Print what would happen, but do not move anything.

.PARAMETER Title
    Window title to look for. Coopanion's pet window is titled "Cortico ...".
    Change it if you renamed or re-skinned the host.

.EXAMPLE
    .\fishway.ps1 -List

.EXAMPLE
    .\fishway.ps1 -Next

.EXAMPLE
    .\fishway.ps1 -To 3

.NOTES
    Windows only. Needs no admin rights. ASCII only on purpose: Windows
    PowerShell 5.1 reads BOM-less files as GBK.
#>
[CmdletBinding(DefaultParameterSetName = 'ByIndex')]
param(
    [Parameter(ParameterSetName = 'ByIndex')]
    [ValidateRange(1, 64)]
    [int]$To,

    [Parameter(ParameterSetName = 'Step')]
    [switch]$Next,

    [Parameter(ParameterSetName = 'Step')]
    [switch]$Prev,

    [Parameter(ParameterSetName = 'Info')]
    [switch]$List,

    [switch]$AlignLeft,

    [switch]$AlignRight,

    [switch]$DryRun,

    [string]$Title = 'Cortico'
)

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public class Fishway {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO {
    public int cbSize; public RECT rcMonitor; public RECT rcWork; public int dwFlags;
  }
  public delegate bool EnumProc(IntPtr h, IntPtr l);

  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfoW(IntPtr mon, ref MONITORINFO mi);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
"@

# per-monitor DPI aware, so every number below is physical pixels
try { [void][Fishway]::SetProcessDpiAwarenessContext([IntPtr](-4)) }
catch { [void][Fishway]::SetProcessDPIAware() }

# ---------------------------------------------------------------- displays
$mons = New-Object System.Collections.ArrayList
$onMonitor = [Fishway+EnumProc]{
    param($hmon, $l)
    $mi = New-Object Fishway+MONITORINFO
    $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
    if ([Fishway]::GetMonitorInfoW($hmon, [ref]$mi)) {
        [void]$mons.Add([pscustomobject]@{
            x  = $mi.rcMonitor.L
            y  = $mi.rcMonitor.T
            w  = $mi.rcMonitor.R - $mi.rcMonitor.L
            h  = $mi.rcMonitor.B - $mi.rcMonitor.T
            wx = $mi.rcWork.L
            wy = $mi.rcWork.T
            ww = $mi.rcWork.R - $mi.rcWork.L
            wh = $mi.rcWork.B - $mi.rcWork.T
        })
    }
    return $true
}
[void][Fishway]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $onMonitor, [IntPtr]::Zero)
$displays = @($mons | Sort-Object x)

if ($displays.Count -eq 0) { Write-Error 'No displays found.'; exit 1 }

# ---------------------------------------------------------------- the pet window
$script:pet = [IntPtr]::Zero
$onWindow = [Fishway+EnumProc]{
    param($h, $l)
    if (-not [Fishway]::IsWindowVisible($h)) { return $true }

    $sb = New-Object System.Text.StringBuilder 512
    [void][Fishway]::GetWindowTextW($h, $sb, 512)
    if ($sb.ToString().IndexOf($script:wantTitle, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $true }

    $cls = New-Object System.Text.StringBuilder 256
    [void][Fishway]::GetClassNameW($h, $cls, 256)
    if (-not $cls.ToString().StartsWith('Chrome_WidgetWin')) { return $true }

    $script:pet = $h
    return $false   # first match wins
}
$script:wantTitle = $Title
[void][Fishway]::EnumWindows($onWindow, [IntPtr]::Zero)

if ($script:pet -eq [IntPtr]::Zero) {
    Write-Error ("No visible window whose title contains '{0}' was found. Is Coopanion running?" -f $Title)
    exit 1
}
$pet = $script:pet

$rect = New-Object Fishway+RECT
[void][Fishway]::GetWindowRect($pet, [ref]$rect)
$ww = $rect.R - $rect.L
$wh = $rect.B - $rect.T

# the display the pet is on now: the one holding the window's centre
$cx = [int](($rect.L + $rect.R) / 2)
$cy = [int](($rect.T + $rect.B) / 2)
$current = -1
for ($i = 0; $i -lt $displays.Count; $i++) {
    $d = $displays[$i]
    if ($cx -ge $d.x -and $cx -lt ($d.x + $d.w) -and $cy -ge $d.y -and $cy -lt ($d.y + $d.h)) {
        $current = $i
        break
    }
}

function Show-State([int]$mark) {
    'displays:'
    for ($i = 0; $i -lt $displays.Count; $i++) {
        $d = $displays[$i]
        $here = if ($i -eq $mark) { '   <== pet is here' } else { '' }
        '  {0}: ({1},{2}) {3}x{4}   work area ({5},{6}) {7}x{8}{9}' -f `
            ($i + 1), $d.x, $d.y, $d.w, $d.h, $d.wx, $d.wy, $d.ww, $d.wh, $here
    }
    'pet window: 0x{0:X}   ({1},{2}) {3}x{4}' -f $pet.ToInt64(), $rect.L, $rect.T, $ww, $wh
}

if ($List) { Show-State $current; exit 0 }

# ---------------------------------------------------------------- pick the target
$target = -1

if ($Next) {
    if ($current -lt $displays.Count - 1) { $target = $current + 1 }
    else { Show-State $current; 'already on the rightmost display.'; exit 0 }
}
elseif ($Prev) {
    if ($current -gt 0) { $target = $current - 1 }
    else { Show-State $current; 'already on the leftmost display.'; exit 0 }
}
elseif ($PSBoundParameters.ContainsKey('To')) {
    if ($To -ge 1 -and $To -le $displays.Count) { $target = $To - 1 }
    else {
        Show-State $current
        Write-Error ("There is no display {0}; this machine has 1..{1}." -f $To, $displays.Count)
        exit 1
    }
}
else {
    Show-State $current
    'nothing to do - use -To <n>, -Next, -Prev or -List'
    exit 0
}

if ($target -eq $current -and -not ($AlignLeft -or $AlignRight)) { Show-State $current; 'already there.'; exit 0 }

$d = $displays[$target]

if ($DryRun) {
    Show-State $current
    'would move the pet window to display {0}: ({1},{2})' -f ($target + 1), $d.x, $d.y
    exit 0
}

# ---------------------------------------------------------------- move it
# SWP_NOACTIVATE = 0x0010, SWP_NOSIZE = 0x0001, HWND_TOPMOST = -1
$TOP = [IntPtr](-1)
$NOACTIVATE = 0x0010
$NOSIZE = 0x0001

# Step 1 - drop the window's origin on the target display at once, tiny in the
# request. This is what makes Windows hand the window its new DPI scale.
[void][Fishway]::SetWindowPos($pet, $TOP, $d.x, $d.y, 1, 1, $NOACTIVATE)
Start-Sleep -Milliseconds 400

# Step 2 - position only, keeping whatever size the window has now. Sent twice:
# a correction that arrives before the DPI change lands gets overwritten by it.
for ($try = 1; $try -le 3; $try++) {
    [void][Fishway]::SetWindowPos($pet, $TOP, $d.x, $d.y, 0, 0, ($NOACTIVATE -bor $NOSIZE))
    Start-Sleep -Milliseconds 250
    [void][Fishway]::GetWindowRect($pet, [ref]$rect)
    if ($rect.L -eq $d.x -and $rect.T -eq $d.y) { break }
}

$ww = $rect.R - $rect.L
$wh = $rect.B - $rect.T

# Step 3 (optional) - line the window up so the pet's own walking limit lands on
# the display edge. The pet can only walk to 5%..95% of its window, and the window is
# not the same width as the display, so without this it stops short of (or runs past)
# the edge and the hop between displays shows a gap.
if ($AlignLeft -or $AlignRight) {
    $nx = $d.x
    if ($AlignLeft) { $nx = $d.x - [int][math]::Round(0.05 * $ww) }
    if ($AlignRight) { $nx = $d.x + $d.w - [int][math]::Round(0.95 * $ww) }
    [void][Fishway]::SetWindowPos($pet, $TOP, $nx, $d.y, 0, 0, ($NOACTIVATE -bor $NOSIZE))
    Start-Sleep -Milliseconds 250
    [void][Fishway]::GetWindowRect($pet, [ref]$rect)
    $ww = $rect.R - $rect.L
    $wh = $rect.B - $rect.T
    $edge = if ($AlignLeft) { 'left' } else { 'right' }
    $limit = if ($AlignLeft) { '5%' } else { '95%' }
    'aligned {0}: window x {1} - the pet''s {2} limit now sits on the {3} edge of display {4}.' -f $edge, $nx, $limit, $edge, ($target + 1)
}

Show-State $target
'moved to display {0}.' -f ($target + 1)

if ($ww -gt $d.w -or $wh -gt $d.h) {
    'note: the window is {0}x{1} on a {2}x{3} display - it cannot be resized from outside,' -f $ww, $wh, $d.w, $d.h
    '      so {0}x{1} px of it hang past the edge. See README ("the seam").' -f ($ww - $d.w), ($wh - $d.h)
}
