# ScreenControl 모의 백엔드. Bootstrap.ps1 이 모듈 내부 스코프에서 실행한다.
# Win32/GDI 를 대체해 창 확정 -> 검증 -> 클릭 순서 로직을 Windows 없이 검증한다.

if (-not ('ScreenControl.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;

namespace ScreenControl
{
    public struct RECT {
        public int Left; public int Top; public int Right; public int Bottom;
        public int Width { get { return Right - Left; } }
        public int Height { get { return Bottom - Top; } }
    }
    public struct POINT { public int X; public int Y; }

    public class DiffResult {
        public bool SizeMismatch; public long TotalPixels; public long ChangedPixels;
        public double ChangedRatio; public int Left; public int Top; public int Right; public int Bottom;
    }

    public class MockWindow {
        public long Handle; public string Title = ""; public string ClassName = "MockClass";
        public int Pid; public RECT Bounds; public RECT Client;
        public bool Visible = true; public bool Iconic = false; public int Dpi = 96;
    }

    public static class Native
    {
        public static List<MockWindow> Windows = new List<MockWindow>();
        public static long ForegroundHandle = 0;
        public static int CursorX = 0;
        public static int CursorY = 0;
        public static int CursorDrift = 0;
        public static bool ActivateFails = false;
        public static bool SendInputFails = false;
        public static string EventLogPath = "";
        public static long BlockerHandle = 0;
        public static RECT BlockerRect;

        public const uint MOUSEEVENTF_MOVE = 0x0001;
        public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        public const uint MOUSEEVENTF_LEFTUP = 0x0004;
        public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
        public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
        public const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
        public const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
        public const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
        public const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;

        private static MockWindow Find(IntPtr h) {
            long v = h.ToInt64();
            foreach (MockWindow w in Windows) { if (w.Handle == v) { return w; } }
            return null;
        }
        private static bool Hit(MockWindow w, int x, int y) {
            return w.Visible && !w.Iconic && x >= w.Bounds.Left && x < w.Bounds.Right && y >= w.Bounds.Top && y < w.Bounds.Bottom;
        }
        public static void Log(string s) {
            if (EventLogPath != "") { try { File.AppendAllText(EventLogPath, s + "\n"); } catch { } }
        }
        public static int ClickCount() {
            if (EventLogPath == "" || !File.Exists(EventLogPath)) { return 0; }
            int n = 0;
            foreach (string line in File.ReadAllLines(EventLogPath)) { if (line.StartsWith("down")) { n++; } }
            return n;
        }
        public static string[] EventLines() {
            if (EventLogPath == "" || !File.Exists(EventLogPath)) { return new string[0]; }
            return File.ReadAllLines(EventLogPath);
        }

        public static IntPtr[] ListTopLevel() {
            List<IntPtr> list = new List<IntPtr>();
            foreach (MockWindow w in Windows) { list.Add(new IntPtr(w.Handle)); }
            return list.ToArray();
        }
        public static bool IsWindow(IntPtr h) { return Find(h) != null; }
        public static bool IsWindowVisible(IntPtr h) { MockWindow w = Find(h); return w != null && w.Visible; }
        public static bool IsIconic(IntPtr h) { MockWindow w = Find(h); return w != null && w.Iconic; }
        public static bool IsZoomed(IntPtr h) { return false; }
        public static IntPtr GetForegroundWindow() { return new IntPtr(ForegroundHandle); }
        public static string GetTitle(IntPtr h) { MockWindow w = Find(h); return w == null ? "" : w.Title; }
        public static string GetClassName(IntPtr h) { MockWindow w = Find(h); return w == null ? "" : w.ClassName; }
        public static int GetPid(IntPtr h) { MockWindow w = Find(h); return w == null ? 0 : w.Pid; }
        public static RECT GetWindowBounds(IntPtr h) { MockWindow w = Find(h); return w == null ? new RECT() : w.Bounds; }
        public static RECT GetVisibleBounds(IntPtr h) { return GetWindowBounds(h); }
        public static RECT GetClientBounds(IntPtr h) { MockWindow w = Find(h); return w == null ? new RECT() : w.Client; }
        public static int GetDpi(IntPtr h) { MockWindow w = Find(h); return w == null ? 96 : w.Dpi; }
        public static string InitDpiAwareness() { return "Mock"; }
        public static int InputStructSize() { return 40; }
        public static bool RestoreWindow(IntPtr h) { MockWindow w = Find(h); if (w == null) { return false; } w.Iconic = false; return true; }

        public static bool Activate(IntPtr h, int timeoutMs) {
            MockWindow w = Find(h);
            if (w == null || ActivateFails) { return false; }
            w.Iconic = false;
            ForegroundHandle = w.Handle;
            Log("activate " + w.Handle);
            return true;
        }
        public static POINT GetCursor() { POINT p = new POINT(); p.X = CursorX; p.Y = CursorY; return p; }
        public static bool SetCursorPos(int x, int y) {
            CursorX = x + CursorDrift; CursorY = y;
            Log("move " + CursorX + "," + CursorY);
            return true;
        }
        public static uint SendMouse(uint flags, int dx, int dy) {
            if (SendInputFails) { return 0; }
            string kind = "other";
            if ((flags & MOUSEEVENTF_LEFTDOWN) != 0 || (flags & MOUSEEVENTF_RIGHTDOWN) != 0 || (flags & MOUSEEVENTF_MIDDLEDOWN) != 0) { kind = "down"; }
            else if ((flags & MOUSEEVENTF_LEFTUP) != 0 || (flags & MOUSEEVENTF_RIGHTUP) != 0 || (flags & MOUSEEVENTF_MIDDLEUP) != 0) { kind = "up"; }
            else if ((flags & MOUSEEVENTF_MOVE) != 0) { kind = "absmove"; }
            Log(kind + " flags=" + flags + " at " + CursorX + "," + CursorY);
            return 1;
        }
        public static IntPtr WindowAtPoint(int x, int y) {
            if (BlockerHandle != 0 && x >= BlockerRect.Left && x < BlockerRect.Right && y >= BlockerRect.Top && y < BlockerRect.Bottom) {
                return new IntPtr(BlockerHandle);
            }
            MockWindow fg = Find(new IntPtr(ForegroundHandle));
            if (fg != null && Hit(fg, x, y)) { return new IntPtr(fg.Handle); }
            foreach (MockWindow w in Windows) { if (Hit(w, x, y)) { return new IntPtr(w.Handle); } }
            return IntPtr.Zero;
        }
        public static IntPtr RootWindowOf(IntPtr h) { return h; }
        public static bool PrintWindowTo(IntPtr h, IntPtr hdc, uint flags) { return true; }
    }

    public static class Imaging
    {
        public static DiffResult Diff(string pathA, string pathB, int tolerance) {
            DiffResult r = new DiffResult();
            string a = File.ReadAllText(pathA);
            string b = File.ReadAllText(pathB);
            r.TotalPixels = 1000;
            if (a == b) {
                r.ChangedPixels = 0; r.ChangedRatio = 0.0;
                r.Left = -1; r.Top = -1; r.Right = -1; r.Bottom = -1;
            } else {
                r.ChangedPixels = 250; r.ChangedRatio = 0.25;
                r.Left = 10; r.Top = 10; r.Right = 100; r.Bottom = 100;
            }
            return r;
        }
    }
}
'@
}

# --- 상태 파일에서 모의 창 구성 ------------------------------------------------
$script:MockState = Get-Content -LiteralPath $env:SCREEN_CONTROL_MOCK_STATE -Raw | ConvertFrom-Json
$mockState = $script:MockState
[ScreenControl.Native]::Windows.Clear()
foreach ($w in $mockState.windows) {
    $mw = New-Object ScreenControl.MockWindow
    $mw.Handle = [int64]$w.handle
    $mw.Title = [string]$w.title
    $mw.ClassName = [string]$w.className
    $mw.Pid = [int]$w.pid
    $mw.Visible = [bool]$w.visible
    $mw.Iconic = [bool]$w.iconic
    $mw.Dpi = [int]$w.dpi
    $b = New-Object ScreenControl.RECT
    $b.Left = [int]$w.bounds.left; $b.Top = [int]$w.bounds.top; $b.Right = [int]$w.bounds.right; $b.Bottom = [int]$w.bounds.bottom
    $mw.Bounds = $b
    $c = New-Object ScreenControl.RECT
    $c.Left = [int]$w.client.left; $c.Top = [int]$w.client.top; $c.Right = [int]$w.client.right; $c.Bottom = [int]$w.client.bottom
    $mw.Client = $c
    [ScreenControl.Native]::Windows.Add($mw)
}
[ScreenControl.Native]::ForegroundHandle = [int64]$mockState.foreground
[ScreenControl.Native]::EventLogPath = [string]$mockState.eventLog
[ScreenControl.Native]::CursorDrift = [int]$mockState.cursorDrift
[ScreenControl.Native]::ActivateFails = [bool]$mockState.activateFails
[ScreenControl.Native]::SendInputFails = [bool]$mockState.sendInputFails
if ($mockState.PSObject.Properties['blocker'] -and $mockState.blocker) {
    [ScreenControl.Native]::BlockerHandle = [int64]$mockState.blocker.handle
    $br = New-Object ScreenControl.RECT
    $br.Left = [int]$mockState.blocker.left; $br.Top = [int]$mockState.blocker.top
    $br.Right = [int]$mockState.blocker.right; $br.Bottom = [int]$mockState.blocker.bottom
    [ScreenControl.Native]::BlockerRect = $br
}

# --- GDI 의존 함수만 대체 -------------------------------------------------------
function script:Initialize-ScNative { $script:NativeReady = $true; $script:DpiMode = 'Mock'; return 'Mock' }

function script:Get-ScVirtualScreen {
    $vs = $script:MockState.virtualScreen
    return New-ScRect -Left ([int]$vs.left) -Top ([int]$vs.top) -Right ([int]$vs.right) -Bottom ([int]$vs.bottom)
}

function script:Save-ScCaptureImage {
    [CmdletBinding()]
    param([string]$Method, $CaptureRect, [int64]$WindowHandle = 0, [string]$OutFile, [int]$MaxWidth = 1600)
    $w = $CaptureRect.Width
    $h = $CaptureRect.Height
    $scale = 1.0
    if ($MaxWidth -gt 0 -and $w -gt $MaxWidth) {
        $scale = [double]$MaxWidth / [double]$w
        $w = [int][Math]::Round($CaptureRect.Width * $scale)
        $h = [int][Math]::Round($CaptureRect.Height * $scale)
        $scale = [double]$w / [double]$CaptureRect.Width
    }
    # 모의 "화면 픽셀": 클릭 수가 바뀌면 내용이 달라져 diff 가 변화를 감지한다.
    $content = "MOCK-SCREEN method=$Method rect=$($CaptureRect.Left),$($CaptureRect.Top),$($CaptureRect.Right),$($CaptureRect.Bottom) clicks=$([ScreenControl.Native]::ClickCount())"
    Set-Content -LiteralPath $OutFile -Value $content -Encoding UTF8 -WhatIf:$false -Confirm:$false
    return [pscustomobject]@{ Width = $w; Height = $h; Scale = $scale }
}

function script:Add-ScGridOverlay {
    [CmdletBinding()]
    param([string]$SourcePath, [string]$OutPath, [int]$Step = 100, [double]$Scale = 1.0, [int]$OriginX = 0, [int]$OriginY = 0)
    Set-Content -WhatIf:$false -Confirm:$false -LiteralPath $OutPath -Value "MOCK-GRID step=$Step scale=$Scale origin=$OriginX,$OriginY of $SourcePath" -Encoding UTF8
    return $OutPath
}

function script:Add-ScMarker {
    [CmdletBinding()]
    param([string]$SourcePath, [string]$OutPath, [int]$X, [int]$Y, [string]$Label = '')
    Set-Content -WhatIf:$false -Confirm:$false -LiteralPath $OutPath -Value "MOCK-MARKER at $X,$Y '$Label' of $SourcePath" -Encoding UTF8
    return $OutPath
}

# 모듈 안에서 정의한 대체 함수를 호출자(스크립트) 쪽에서도 보이게 덮어쓴다.
# (스크립트는 Import-Module 로 내보내진 원본을 참조하므로 이 단계가 필요하다)
foreach ($fn in @('Initialize-ScNative', 'Get-ScVirtualScreen', 'Save-ScCaptureImage', 'Add-ScGridOverlay', 'Add-ScMarker')) {
    $sb = (Get-Item -LiteralPath "function:$fn").ScriptBlock
    Set-Item -Path "function:global:$fn" -Value $sb -WhatIf:$false -Confirm:$false
}
