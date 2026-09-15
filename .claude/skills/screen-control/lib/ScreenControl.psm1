<#
.SYNOPSIS
    ScreenControl - Windows 화면 캡처 + 방어적 마우스 클릭 코어 라이브러리.

.DESCRIPTION
    Add-Type 으로 Win32 API(user32/dwmapi) 와 System.Drawing 을 직접 호출한다.
    MCP 서버나 외부 실행 파일이 필요 없다.

    설계 원칙
      1) 클릭은 항상 "대상 창"을 기준으로 한다. 창을 못 찾으면 클릭하지 않는다.
      2) 클릭 직전 캡처(증거 이미지)가 없으면 클릭하지 않는다. (블라인드 클릭 금지)
      3) 위험해 보이는 의도(삭제/저장/전송...)는 사용자 승인 플래그 없이는 거부한다.
      4) 커서 이동 후 즉시 클릭하지 않는다. 지연 후 커서 위치를 재확인하고 누른다.

    Windows PowerShell 5.1 및 PowerShell 7(Windows) 에서 동작.
#>

Set-StrictMode -Version Latest

$script:ScreenControlVersion = '1.0.0'
$script:NativeReady = $false
$script:DpiMode = 'NotInitialized'

# 기본 위험 키워드. ASCII 는 단어 경계로, 한글은 부분 문자열로 매칭한다.
$script:DangerKeywords = @(
    'delete', 'remove', 'erase', 'purge', 'format', 'uninstall', 'drop', 'clear all',
    'save', 'save as', 'overwrite', 'replace all', 'export', 'import',
    'send', 'submit', 'upload', 'publish', 'post', 'share', 'email',
    'ok', 'yes', 'confirm', 'apply', 'accept', 'agree', 'allow', 'approve', 'grant',
    'pay', 'purchase', 'order', 'buy', 'checkout', 'subscribe',
    'shutdown', 'restart', 'reboot', 'reset', 'kill', 'terminate', 'quit', 'exit',
    'discard', 'revert', 'rollback', 'commit', 'push', 'merge', 'deploy', 'install',
    'plot', 'print',
    '삭제', '지우', '제거', '포맷', '초기화',
    '저장', '다른 이름으로', '덮어쓰', '내보내기', '가져오기',
    '전송', '보내기', '제출', '업로드', '게시', '공유',
    '확인', '예(', '동의', '승인', '허용', '적용',
    '결제', '구매', '주문',
    '종료', '재시작', '다시 시작', '되돌리기', '플롯', '인쇄', '출력'
)

$script:NativeSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

namespace ScreenControl
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
        public int Width { get { return Right - Left; } }
        public int Height { get { return Bottom - Top; } }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    // 마우스 전용 INPUT. 크기가 실제 INPUT 공용체와 같다(x86:28, x64:40).
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public MOUSEINPUT mi;
    }

    public class DiffResult
    {
        public bool SizeMismatch;
        public long TotalPixels;
        public long ChangedPixels;
        public double ChangedRatio;
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public static class Native
    {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] private static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr hWnd, StringBuilder text, int count);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
        [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(POINT p);
        [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
        [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
        [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
        [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
        [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
        [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out RECT value, int size);

        public const uint MOUSEEVENTF_MOVE = 0x0001;
        public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        public const uint MOUSEEVENTF_LEFTUP = 0x0004;
        public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
        public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
        public const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
        public const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
        public const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
        public const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;

        private const int SW_RESTORE = 9;
        private const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
        private const uint GA_ROOT = 2;

        public static IntPtr[] ListTopLevel()
        {
            List<IntPtr> found = new List<IntPtr>();
            EnumWindows(delegate(IntPtr h, IntPtr l) { found.Add(h); return true; }, IntPtr.Zero);
            return found.ToArray();
        }

        public static string GetTitle(IntPtr hWnd)
        {
            StringBuilder sb = new StringBuilder(1024);
            GetWindowTextW(hWnd, sb, sb.Capacity);
            return sb.ToString();
        }

        public static string GetClassName(IntPtr hWnd)
        {
            StringBuilder sb = new StringBuilder(512);
            GetClassNameW(hWnd, sb, sb.Capacity);
            return sb.ToString();
        }

        public static int GetPid(IntPtr hWnd)
        {
            uint pid = 0;
            GetWindowThreadProcessId(hWnd, out pid);
            return (int)pid;
        }

        public static RECT GetWindowBounds(IntPtr hWnd)
        {
            RECT r = new RECT();
            GetWindowRect(hWnd, out r);
            return r;
        }

        // DWM 확장 프레임 기준(그림자 여백 제외) = 사람 눈에 보이는 창 영역
        public static RECT GetVisibleBounds(IntPtr hWnd)
        {
            RECT r = new RECT();
            try
            {
                int hr = DwmGetWindowAttribute(hWnd, DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf(typeof(RECT)));
                if (hr == 0 && r.Right > r.Left && r.Bottom > r.Top) { return r; }
            }
            catch { }
            GetWindowRect(hWnd, out r);
            return r;
        }

        // 클라이언트 영역을 화면 좌표로 환산
        public static RECT GetClientBounds(IntPtr hWnd)
        {
            RECT c = new RECT();
            GetClientRect(hWnd, out c);
            POINT p = new POINT();
            p.X = 0; p.Y = 0;
            ClientToScreen(hWnd, ref p);
            RECT r = new RECT();
            r.Left = p.X;
            r.Top = p.Y;
            r.Right = p.X + c.Width;
            r.Bottom = p.Y + c.Height;
            return r;
        }

        public static int GetDpi(IntPtr hWnd)
        {
            try
            {
                uint dpi = GetDpiForWindow(hWnd);
                return dpi == 0 ? 96 : (int)dpi;
            }
            catch { return 96; }
        }

        public static string InitDpiAwareness()
        {
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) { return "PerMonitorV2"; } }
            catch { }
            try { if (SetProcessDPIAware()) { return "System"; } }
            catch { }
            return "AlreadySetOrUnsupported";
        }

        public static bool RestoreWindow(IntPtr hWnd)
        {
            return ShowWindow(hWnd, SW_RESTORE);
        }

        public static bool Activate(IntPtr hWnd, int timeoutMs)
        {
            if (GetForegroundWindow() == hWnd) { return true; }
            if (IsIconic(hWnd))
            {
                ShowWindow(hWnd, SW_RESTORE);
                System.Threading.Thread.Sleep(250);
            }

            uint ignored = 0;
            uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), out ignored);
            uint targetThread = GetWindowThreadProcessId(hWnd, out ignored);
            uint thisThread = GetCurrentThreadId();
            bool a1 = false, a2 = false;
            try
            {
                if (fgThread != 0 && fgThread != thisThread) { a1 = AttachThreadInput(thisThread, fgThread, true); }
                if (targetThread != 0 && targetThread != thisThread) { a2 = AttachThreadInput(thisThread, targetThread, true); }
                BringWindowToTop(hWnd);
                SetForegroundWindow(hWnd);
            }
            finally
            {
                if (a1) { AttachThreadInput(thisThread, fgThread, false); }
                if (a2) { AttachThreadInput(thisThread, targetThread, false); }
            }

            int waited = 0;
            while (waited < timeoutMs)
            {
                if (GetForegroundWindow() == hWnd) { return true; }
                System.Threading.Thread.Sleep(50);
                waited += 50;
            }
            return GetForegroundWindow() == hWnd;
        }

        public static POINT GetCursor()
        {
            POINT p = new POINT();
            GetCursorPos(out p);
            return p;
        }

        public static uint SendMouse(uint flags, int dx, int dy)
        {
            INPUT[] inputs = new INPUT[1];
            inputs[0].type = 0; // INPUT_MOUSE
            inputs[0].mi.dx = dx;
            inputs[0].mi.dy = dy;
            inputs[0].mi.mouseData = 0;
            inputs[0].mi.dwFlags = flags;
            inputs[0].mi.time = 0;
            inputs[0].mi.dwExtraInfo = IntPtr.Zero;
            return SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT)));
        }

        public static int InputStructSize()
        {
            return Marshal.SizeOf(typeof(INPUT));
        }

        // 지정한 화면 좌표에 실제로 어떤 창이 있는지(클릭 대상 검증용)
        public static IntPtr WindowAtPoint(int x, int y)
        {
            POINT p = new POINT();
            p.X = x; p.Y = y;
            return WindowFromPoint(p);
        }

        public static IntPtr RootWindowOf(IntPtr hWnd)
        {
            IntPtr root = GetAncestor(hWnd, GA_ROOT);
            return root == IntPtr.Zero ? hWnd : root;
        }

        public static bool PrintWindowTo(IntPtr hWnd, IntPtr hdc, uint flags)
        {
            return PrintWindow(hWnd, hdc, flags);
        }
    }

    public static class Imaging
    {
        public static DiffResult Diff(string pathA, string pathB, int tolerance)
        {
            DiffResult result = new DiffResult();
            using (Bitmap a = new Bitmap(pathA))
            using (Bitmap b = new Bitmap(pathB))
            {
                if (a.Width != b.Width || a.Height != b.Height)
                {
                    result.SizeMismatch = true;
                    result.ChangedRatio = 1.0;
                    result.Left = -1; result.Top = -1; result.Right = -1; result.Bottom = -1;
                    return result;
                }

                Rectangle rect = new Rectangle(0, 0, a.Width, a.Height);
                BitmapData da = a.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                BitmapData db = b.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                int stride = da.Stride;
                int bytes = Math.Abs(stride) * a.Height;
                byte[] ba = new byte[bytes];
                byte[] bb = new byte[bytes];
                Marshal.Copy(da.Scan0, ba, 0, bytes);
                Marshal.Copy(db.Scan0, bb, 0, bytes);
                a.UnlockBits(da);
                b.UnlockBits(db);

                long changed = 0;
                int minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
                for (int y = 0; y < a.Height; y++)
                {
                    int row = y * stride;
                    for (int x = 0; x < a.Width; x++)
                    {
                        int i = row + (x * 4);
                        if (Math.Abs(ba[i] - bb[i]) > tolerance ||
                            Math.Abs(ba[i + 1] - bb[i + 1]) > tolerance ||
                            Math.Abs(ba[i + 2] - bb[i + 2]) > tolerance)
                        {
                            changed++;
                            if (x < minX) { minX = x; }
                            if (y < minY) { minY = y; }
                            if (x > maxX) { maxX = x; }
                            if (y > maxY) { maxY = y; }
                        }
                    }
                }

                result.TotalPixels = (long)a.Width * (long)a.Height;
                result.ChangedPixels = changed;
                result.ChangedRatio = result.TotalPixels == 0 ? 0.0 : (double)changed / (double)result.TotalPixels;
                if (maxX >= 0)
                {
                    result.Left = minX; result.Top = minY; result.Right = maxX; result.Bottom = maxY;
                }
                else
                {
                    result.Left = -1; result.Top = -1; result.Right = -1; result.Bottom = -1;
                }
                return result;
            }
        }
    }
}
'@

# ---------------------------------------------------------------------------
# 종료 코드 (스크립트들이 공통으로 사용)
# ---------------------------------------------------------------------------
$script:ExitCodes = @{
    Ok                  = 0
    GeneralError        = 1
    WindowNotFound      = 2
    ActivationFailed    = 3
    OutOfBounds         = 4
    EvidenceProblem     = 5
    ApprovalRequired    = 6
    PlatformError       = 7
    CursorVerifyFailed  = 8
    InvalidArguments    = 9
}

function Get-ScExitCode {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:ExitCodes.ContainsKey($Name)) { return 1 }
    return $script:ExitCodes[$Name]
}

function Get-ScVersion { return $script:ScreenControlVersion }

# ---------------------------------------------------------------------------
# 플랫폼 / 네이티브 초기화
# ---------------------------------------------------------------------------
function Test-ScWindowsPlatform {
    [CmdletBinding()]
    param()
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Assert-ScPlatform {
    [CmdletBinding()]
    param()
    if (-not (Test-ScWindowsPlatform)) {
        throw "ScreenControl 은 Windows 전용입니다 (현재: $([System.Environment]::OSVersion.Platform)). [exit=$(Get-ScExitCode PlatformError)]"
    }
}

function Initialize-ScNative {
    [CmdletBinding()]
    param()
    if ($script:NativeReady) { return $script:DpiMode }
    Assert-ScPlatform

    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

    if (-not ('ScreenControl.Native' -as [type])) {
        $refPath = [System.Drawing.Bitmap].Assembly.Location
        if ($refPath) {
            Add-Type -TypeDefinition $script:NativeSource -ReferencedAssemblies $refPath -ErrorAction Stop
        }
        else {
            Add-Type -TypeDefinition $script:NativeSource -ErrorAction Stop
        }
    }

    # 좌표가 실제 픽셀과 어긋나지 않도록 DPI 인식을 먼저 켠다.
    $script:DpiMode = [ScreenControl.Native]::InitDpiAwareness()
    $script:NativeReady = $true
    return $script:DpiMode
}

function Get-ScDpiMode { return $script:DpiMode }

# ---------------------------------------------------------------------------
# 출력 폴더 / 로깅
# ---------------------------------------------------------------------------
function Resolve-ScOutDir {
    [CmdletBinding()]
    param([string]$OutDir)

    if (-not $OutDir) { $OutDir = $env:SCREEN_CONTROL_OUT }
    if (-not $OutDir) {
        if (Test-Path -LiteralPath 'D:\ai') { $OutDir = 'D:\ai\.screen-control' }
        else { $OutDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'screen-control' }
    }
    if (-not (Test-Path -LiteralPath $OutDir)) {
        # -WhatIf 실행 중에도 폴더는 실제로 만들어야 한다 (안 그러면 경로 확인이 실패한다)
        New-Item -ItemType Directory -Path $OutDir -Force -WhatIf:$false -Confirm:$false | Out-Null
    }
    return (Resolve-Path -LiteralPath $OutDir).Path
}

function Write-ScLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][hashtable]$Data,
        [string]$OutDir
    )
    try {
        $dir = Resolve-ScOutDir -OutDir $OutDir
        $entry = [ordered]@{
            timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            action       = $Action
            user         = $env:USERNAME
            version      = $script:ScreenControlVersion
        }
        foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }
        $line = ($entry | ConvertTo-Json -Depth 8 -Compress)
        Add-Content -LiteralPath (Join-Path $dir 'screen-control.log.jsonl') -Value $line -Encoding UTF8 -WhatIf:$false -Confirm:$false
    }
    catch {
        Write-Warning "감사 로그 기록 실패: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 순수 계산 헬퍼 (Windows 가 아니어도 동작 → 단위 테스트 가능)
# ---------------------------------------------------------------------------
function New-ScRect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Left,
        [Parameter(Mandatory)][int]$Top,
        [Parameter(Mandatory)][int]$Right,
        [Parameter(Mandatory)][int]$Bottom
    )
    return [pscustomobject]@{
        Left   = $Left
        Top    = $Top
        Right  = $Right
        Bottom = $Bottom
        Width  = $Right - $Left
        Height = $Bottom - $Top
    }
}

function ConvertFrom-ScNativeRect {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rect)
    return New-ScRect -Left $Rect.Left -Top $Rect.Top -Right $Rect.Right -Bottom $Rect.Bottom
}

function Test-ScPointInRect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [Parameter(Mandatory)]$Rect,
        [int]$Margin = 0
    )
    return ($X -ge ($Rect.Left - $Margin) -and $X -lt ($Rect.Right + $Margin) -and
            $Y -ge ($Rect.Top - $Margin) -and $Y -lt ($Rect.Bottom + $Margin))
}

function ConvertTo-ScAbsoluteMousePoint {
    <#
        SendInput(MOUSEEVENTF_ABSOLUTE|VIRTUALDESK) 용 0..65535 정규화 좌표.
        기본 클릭 경로에서는 SetCursorPos 를 쓰지만, -UseAbsoluteMove 경로에서 사용한다.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [Parameter(Mandatory)]$VirtualScreen
    )
    $w = [Math]::Max(1, $VirtualScreen.Width - 1)
    $h = [Math]::Max(1, $VirtualScreen.Height - 1)
    $dx = [int][Math]::Round((($X - $VirtualScreen.Left) * 65535.0) / $w)
    $dy = [int][Math]::Round((($Y - $VirtualScreen.Top) * 65535.0) / $h)
    return [pscustomobject]@{
        Dx = [Math]::Max(0, [Math]::Min(65535, $dx))
        Dy = [Math]::Max(0, [Math]::Min(65535, $dy))
    }
}

function Get-ScDangerMatch {
    <#
        의도 문자열이 위험 동작으로 보이는지 판정.
        ASCII 키워드는 단어 경계, 한글 키워드는 부분 문자열로 매칭한다.
    #>
    [CmdletBinding()]
    param(
        [string]$Intent,
        [string[]]$ExtraKeywords = @()
    )
    $hits = New-Object System.Collections.Generic.List[string]
    if ($Intent) {
        foreach ($kw in ($script:DangerKeywords + $ExtraKeywords)) {
            if (-not $kw) { continue }
            if ($kw -match '^[\x20-\x7E]+$') {
                $pattern = '(?i)(^|[^A-Za-z0-9])' + [regex]::Escape($kw) + '($|[^A-Za-z0-9])'
            }
            else {
                $pattern = [regex]::Escape($kw)
            }
            if ($Intent -match $pattern) { [void]$hits.Add($kw) }
        }
    }
    return [pscustomobject]@{
        IsDangerous = ($hits.Count -gt 0)
        Matches     = $hits.ToArray()
    }
}

function ConvertTo-ScScreenPointFromImage {
    <#
        캡처 이미지 픽셀 좌표 -> 화면 좌표. (축소 캡처 보정 포함)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$ImageX,
        [Parameter(Mandatory)][double]$ImageY,
        [Parameter(Mandatory)]$Meta
    )
    $scale = [double]$Meta.scale
    if ($scale -le 0) { $scale = 1.0 }
    return [pscustomobject]@{
        X = [int][Math]::Round($Meta.origin.x + ($ImageX / $scale))
        Y = [int][Math]::Round($Meta.origin.y + ($ImageY / $scale))
    }
}

function ConvertTo-ScImagePointFromScreen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ScreenX,
        [Parameter(Mandatory)][int]$ScreenY,
        [Parameter(Mandatory)]$Meta
    )
    $scale = [double]$Meta.scale
    if ($scale -le 0) { $scale = 1.0 }
    return [pscustomobject]@{
        X = [int][Math]::Round(($ScreenX - $Meta.origin.x) * $scale)
        Y = [int][Math]::Round(($ScreenY - $Meta.origin.y) * $scale)
    }
}

# ---------------------------------------------------------------------------
# 창 찾기
# ---------------------------------------------------------------------------
function Get-ScVirtualScreen {
    [CmdletBinding()]
    param()
    Initialize-ScNative | Out-Null
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    return New-ScRect -Left $vs.Left -Top $vs.Top -Right $vs.Right -Bottom $vs.Bottom
}

function New-ScWindowInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][IntPtr]$Handle)

    Initialize-ScNative | Out-Null
    if (-not [ScreenControl.Native]::IsWindow($Handle)) { return $null }

    $pid_ = [ScreenControl.Native]::GetPid($Handle)
    $procName = ''
    try { $procName = (Get-Process -Id $pid_ -ErrorAction Stop).ProcessName } catch { $procName = '?' }

    $visibleRect = ConvertFrom-ScNativeRect ([ScreenControl.Native]::GetVisibleBounds($Handle))
    $windowRect  = ConvertFrom-ScNativeRect ([ScreenControl.Native]::GetWindowBounds($Handle))
    $clientRect  = ConvertFrom-ScNativeRect ([ScreenControl.Native]::GetClientBounds($Handle))

    return [pscustomobject]@{
        Handle      = $Handle
        HandleValue = [int64]$Handle
        HandleHex   = ('0x{0:X}' -f [int64]$Handle)
        ProcessId   = $pid_
        ProcessName = $procName
        Title       = [ScreenControl.Native]::GetTitle($Handle)
        ClassName   = [ScreenControl.Native]::GetClassName($Handle)
        Visible     = [ScreenControl.Native]::IsWindowVisible($Handle)
        Minimized   = [ScreenControl.Native]::IsIconic($Handle)
        Maximized   = [ScreenControl.Native]::IsZoomed($Handle)
        Foreground  = ([ScreenControl.Native]::GetForegroundWindow() -eq $Handle)
        Dpi         = [ScreenControl.Native]::GetDpi($Handle)
        Bounds      = $visibleRect
        WindowRect  = $windowRect
        ClientRect  = $clientRect
    }
}

function Get-ScWindow {
    <#
    .SYNOPSIS
        조건에 맞는 최상위 창 목록을 돌려준다.
    #>
    [CmdletBinding()]
    param(
        [string]$ProcessName,
        [string]$TitleLike,
        [int]$ProcessId = 0,
        [int64]$Handle = 0,
        [switch]$IncludeInvisible
    )

    Initialize-ScNative | Out-Null

    if ($Handle -ne 0) {
        $info = New-ScWindowInfo -Handle ([IntPtr]$Handle)
        if ($null -eq $info) { return @() }
        return @($info)
    }

    $results = New-Object System.Collections.Generic.List[object]
    # 메서드 호출 결과를 foreach 에 바로 넣으면 PowerShell 바인더가 IntPtr[] 열거에서
    # "Argument types do not match" 로 실패하는 경우가 있어 변수로 받아서 순회한다.
    $handles = @([ScreenControl.Native]::ListTopLevel())
    foreach ($h in $handles) {
        if (-not $IncludeInvisible) {
            if (-not [ScreenControl.Native]::IsWindowVisible($h)) { continue }
            if ([string]::IsNullOrWhiteSpace([ScreenControl.Native]::GetTitle($h))) { continue }
        }
        $info = New-ScWindowInfo -Handle $h
        if ($null -eq $info) { continue }
        if (-not $IncludeInvisible -and $info.Bounds.Width -le 0) { continue }

        if ($ProcessId -ne 0 -and $info.ProcessId -ne $ProcessId) { continue }
        if ($ProcessName) {
            $needle = $ProcessName -replace '\.exe$', ''
            $pattern = $needle
            if ($pattern -notmatch '[\*\?]') { $pattern = "*$pattern*" }
            if ($info.ProcessName -notlike $pattern) { continue }
        }
        if ($TitleLike) {
            $pattern = $TitleLike
            if ($pattern -notmatch '[\*\?]') { $pattern = "*$pattern*" }
            if ($info.Title -notlike $pattern) { continue }
        }
        [void]$results.Add($info)
    }
    # @(List[object]) 는 일부 PowerShell 런타임에서 바인더 오류를 낸다. ToArray() 가 안전하다.
    return $results.ToArray()
}

function Resolve-ScTargetWindow {
    <#
    .SYNOPSIS
        대상 창을 "정확히 하나"로 확정한다. 0개/2개 이상이면 예외.
    #>
    [CmdletBinding()]
    param(
        [string]$ProcessName,
        [string]$TitleLike,
        [int]$ProcessId = 0,
        [int64]$Handle = 0,
        [switch]$AllowMinimized
    )

    if (-not $ProcessName -and -not $TitleLike -and $ProcessId -eq 0 -and $Handle -eq 0) {
        throw "대상 창을 지정해야 합니다: -ProcessName / -TitleLike / -ProcessId / -Handle 중 하나. [exit=$(Get-ScExitCode InvalidArguments)]"
    }

    $matches_ = @(Get-ScWindow -ProcessName $ProcessName -TitleLike $TitleLike -ProcessId $ProcessId -Handle $Handle)

    if ($matches_.Count -eq 0) {
        throw "대상 창을 찾을 수 없습니다 (ProcessName='$ProcessName', TitleLike='$TitleLike', ProcessId=$ProcessId, Handle=$Handle). Get-Window.ps1 로 목록을 먼저 확인하세요. [exit=$(Get-ScExitCode WindowNotFound)]"
    }
    if ($matches_.Count -gt 1) {
        $list = ($matches_ | ForEach-Object { "  - $($_.HandleHex) [$($_.ProcessName)] $($_.Title)" }) -join "`n"
        throw "대상 창이 $($matches_.Count) 개로 모호합니다. -Handle 로 하나를 지정하세요:`n$list`n[exit=$(Get-ScExitCode WindowNotFound)]"
    }

    $win = $matches_[0]
    if ($win.Minimized -and -not $AllowMinimized) {
        throw "대상 창이 최소화 상태입니다: $($win.HandleHex) [$($win.ProcessName)] $($win.Title). -Restore 옵션을 쓰거나 창을 복원하세요. [exit=$(Get-ScExitCode ActivationFailed)]"
    }
    return $win
}

function Set-ScWindowActive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Window,
        [int]$TimeoutMs = 2500,
        [switch]$Restore
    )
    Initialize-ScNative | Out-Null
    $h = [IntPtr]$Window.HandleValue

    if (-not [ScreenControl.Native]::IsWindow($h)) {
        throw "창 핸들이 더 이상 유효하지 않습니다: $($Window.HandleHex). [exit=$(Get-ScExitCode WindowNotFound)]"
    }
    if ([ScreenControl.Native]::IsIconic($h)) {
        if (-not $Restore) {
            throw "창이 최소화되어 있습니다: $($Window.HandleHex). -Restore 를 지정하면 복원 후 진행합니다. [exit=$(Get-ScExitCode ActivationFailed)]"
        }
        [void][ScreenControl.Native]::RestoreWindow($h)
        Start-Sleep -Milliseconds 300
    }

    $ok = [ScreenControl.Native]::Activate($h, $TimeoutMs)
    if (-not $ok) {
        $fg = [ScreenControl.Native]::GetForegroundWindow()
        $fgTitle = ''
        try { $fgTitle = [ScreenControl.Native]::GetTitle($fg) } catch { $fgTitle = '?' }
        throw "대상 창을 활성화하지 못했습니다. 현재 활성창: 0x$('{0:X}' -f [int64]$fg) '$fgTitle'. (UAC/관리자 권한 창 또는 전체화면 앱이 포커스를 잡고 있을 수 있음) [exit=$(Get-ScExitCode ActivationFailed)]"
    }
    return (New-ScWindowInfo -Handle $h)
}

# ---------------------------------------------------------------------------
# 캡처
# ---------------------------------------------------------------------------
function Get-ScRectIntersection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$A, [Parameter(Mandatory)]$B)
    $l = [Math]::Max($A.Left, $B.Left)
    $t = [Math]::Max($A.Top, $B.Top)
    $r = [Math]::Min($A.Right, $B.Right)
    $b = [Math]::Min($A.Bottom, $B.Bottom)
    if ($r -le $l -or $b -le $t) { return $null }
    return New-ScRect -Left $l -Top $t -Right $r -Bottom $b
}

function Add-ScGridOverlay {
    <#
    .SYNOPSIS
        좌표 격자를 덧그린 사본 이미지를 만든다. 라벨은 "원본 좌표계" 값이다.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$OutPath,
        [int]$Step = 100,
        [double]$Scale = 1.0,
        [int]$OriginX = 0,
        [int]$OriginY = 0
    )
    Initialize-ScNative | Out-Null

    $src = [System.Drawing.Image]::FromFile($SourcePath)
    try {
        $bmp = New-Object System.Drawing.Bitmap($src.Width, $src.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.DrawImage($src, 0, 0, $src.Width, $src.Height)
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

            $minorPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(70, 255, 0, 0)), 1
            $majorPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(170, 255, 0, 0)), 1
            $backBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(190, 0, 0, 0))
            $textBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 240, 0))
            try { $font = New-Object System.Drawing.Font('Consolas', 9, [System.Drawing.FontStyle]::Bold) }
            catch { $font = [System.Drawing.SystemFonts]::DefaultFont }

            $pxStep = [Math]::Max(8.0, $Step * $Scale)
            $majorEvery = 5

            $i = 0
            for ($x = 0.0; $x -lt $src.Width; $x += $pxStep) {
                $isMajor = (($i % $majorEvery) -eq 0)
                $pen = if ($isMajor) { $majorPen } else { $minorPen }
                $g.DrawLine($pen, [float]$x, 0.0, [float]$x, [float]$src.Height)
                if ($isMajor) {
                    $label = [string]($OriginX + ($i * $Step))
                    $size = $g.MeasureString($label, $font)
                    $g.FillRectangle($backBrush, [float]($x + 1), 0.0, $size.Width, $size.Height)
                    $g.DrawString($label, $font, $textBrush, [float]($x + 1), 0.0)
                }
                $i++
            }

            $j = 0
            for ($y = 0.0; $y -lt $src.Height; $y += $pxStep) {
                $isMajor = (($j % $majorEvery) -eq 0)
                $pen = if ($isMajor) { $majorPen } else { $minorPen }
                $g.DrawLine($pen, 0.0, [float]$y, [float]$src.Width, [float]$y)
                if ($isMajor -and $j -gt 0) {
                    $label = [string]($OriginY + ($j * $Step))
                    $size = $g.MeasureString($label, $font)
                    $g.FillRectangle($backBrush, 0.0, [float]($y + 1), $size.Width, $size.Height)
                    $g.DrawString($label, $font, $textBrush, 0.0, [float]($y + 1))
                }
                $j++
            }

            $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $g.Dispose()
            $bmp.Dispose()
        }
    }
    finally {
        $src.Dispose()
    }
    return $OutPath
}

function Add-ScMarker {
    <#
    .SYNOPSIS
        이미지 위 특정 픽셀에 조준 표식을 그린 사본을 만든다 (클릭 지점 사전/사후 확인용).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [string]$Label = ''
    )
    Initialize-ScNative | Out-Null

    $src = [System.Drawing.Image]::FromFile($SourcePath)
    try {
        $bmp = New-Object System.Drawing.Bitmap($src.Width, $src.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.DrawImage($src, 0, 0, $src.Width, $src.Height)
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 255, 0, 0)), 2
            $g.DrawEllipse($pen, $X - 18, $Y - 18, 36, 36)
            $g.DrawLine($pen, $X - 28, $Y, $X - 6, $Y)
            $g.DrawLine($pen, $X + 6, $Y, $X + 28, $Y)
            $g.DrawLine($pen, $X, $Y - 28, $X, $Y - 6)
            $g.DrawLine($pen, $X, $Y + 6, $X, $Y + 28)
            if ($Label) {
                try { $font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold) }
                catch { $font = [System.Drawing.SystemFonts]::DefaultFont }
                $backBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(200, 0, 0, 0))
                $textBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 255, 0))
                $size = $g.MeasureString($Label, $font)
                $tx = [float]([Math]::Max(0, [Math]::Min($src.Width - $size.Width, $X + 22)))
                $ty = [float]([Math]::Max(0, [Math]::Min($src.Height - $size.Height, $Y + 22)))
                $g.FillRectangle($backBrush, $tx, $ty, $size.Width, $size.Height)
                $g.DrawString($Label, $font, $textBrush, $tx, $ty)
            }
            $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $g.Dispose()
            $bmp.Dispose()
        }
    }
    finally {
        $src.Dispose()
    }
    return $OutPath
}

function Save-ScCaptureImage {
    <#
    .SYNOPSIS
        화면/창의 실제 픽셀을 읽어 PNG 로 저장하고 최종 크기와 축소 배율을 돌려준다.
    .DESCRIPTION
        GDI 에 의존하는 유일한 지점이라 테스트에서는 이 함수만 대체하면
        New-ScCapture 의 나머지 로직(활성화, 영역 계산, 메타데이터)을 그대로 검증할 수 있다.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Screen', 'PrintWindow')][string]$Method,
        [Parameter(Mandatory)]$CaptureRect,
        [int64]$WindowHandle = 0,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$MaxWidth = 1600
    )

    Initialize-ScNative | Out-Null

    $bmp = New-Object System.Drawing.Bitmap($CaptureRect.Width, $CaptureRect.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            if ($Method -eq 'PrintWindow') {
                $g.Clear([System.Drawing.Color]::Black)
                $hdc = $g.GetHdc()
                try {
                    # PW_RENDERFULLCONTENT(0x2): 최신(DWM) 창도 내용까지 렌더링
                    $ok = [ScreenControl.Native]::PrintWindowTo([IntPtr]$WindowHandle, $hdc, 2)
                }
                finally { $g.ReleaseHdc($hdc) }
                if (-not $ok) { Write-Warning "PrintWindow 가 실패를 보고했습니다. 이미지가 비어 있을 수 있습니다." }
            }
            else {
                $g.CopyFromScreen($CaptureRect.Left, $CaptureRect.Top, 0, 0,
                    (New-Object System.Drawing.Size($CaptureRect.Width, $CaptureRect.Height)),
                    [System.Drawing.CopyPixelOperation]::SourceCopy)
            }
        }
        finally { $g.Dispose() }

        $scale = 1.0
        $finalBmp = $bmp
        if ($MaxWidth -gt 0 -and $bmp.Width -gt $MaxWidth) {
            $scale = [double]$MaxWidth / [double]$bmp.Width
            $newW = [int][Math]::Round($bmp.Width * $scale)
            $newH = [int][Math]::Round($bmp.Height * $scale)
            $resized = New-Object System.Drawing.Bitmap($newW, $newH)
            $rg = [System.Drawing.Graphics]::FromImage($resized)
            try {
                $rg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $rg.DrawImage($bmp, 0, 0, $newW, $newH)
            }
            finally { $rg.Dispose() }
            $finalBmp = $resized
            $scale = [double]$newW / [double]$CaptureRect.Width
        }

        try {
            $finalBmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
            return [pscustomobject]@{ Width = $finalBmp.Width; Height = $finalBmp.Height; Scale = $scale }
        }
        finally {
            if (-not [object]::ReferenceEquals($finalBmp, $bmp)) { $finalBmp.Dispose() }
        }
    }
    finally {
        $bmp.Dispose()
    }
}

function New-ScCapture {
    <#
    .SYNOPSIS
        대상 창(기본) 또는 전체 화면을 PNG 로 저장하고 메타데이터(JSON)를 남긴다.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Window', 'Screen')][string]$Mode = 'Window',
        $Window,
        [ValidateSet('Auto', 'Screen', 'PrintWindow')][string]$Method = 'Auto',
        [string]$OutDir,
        [string]$Name,
        [switch]$NoGrid,
        [int]$GridStep = 100,
        [int]$MaxWidth = 1600,
        [switch]$NoActivate,
        [switch]$Restore,
        [int]$SettleMs = 350,
        [string]$Note = ''
    )

    Initialize-ScNative | Out-Null
    $dir = Resolve-ScOutDir -OutDir $OutDir
    if (-not $Name) { $Name = 'capture-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') }
    $imagePath = Join-Path $dir ($Name + '.png')
    $metaPath = Join-Path $dir ($Name + '.json')

    $vs = Get-ScVirtualScreen
    $target = $null
    $captureRect = $null
    $labelOriginX = 0
    $labelOriginY = 0
    $labelSpace = 'screen'

    if ($Mode -eq 'Window') {
        if (-not $Window) { throw "Mode=Window 에는 -Window 가 필요합니다. [exit=$(Get-ScExitCode InvalidArguments)]" }

        if (-not $NoActivate) {
            $target = Set-ScWindowActive -Window $Window -Restore:$Restore
        }
        else {
            $target = New-ScWindowInfo -Handle ([IntPtr]$Window.HandleValue)
            if ($null -eq $target) { throw "창 핸들이 유효하지 않습니다: $($Window.HandleHex). [exit=$(Get-ScExitCode WindowNotFound)]" }
        }

        if ($Method -eq 'Auto') {
            $Method = if ($target.Foreground -or (-not $NoActivate)) { 'Screen' } else { 'PrintWindow' }
        }

        Start-Sleep -Milliseconds $SettleMs
        $target = New-ScWindowInfo -Handle ([IntPtr]$target.HandleValue)

        $captureRect = if ($Method -eq 'PrintWindow') { $target.WindowRect } else { $target.Bounds }
        $labelSpace = 'window'
        $labelOriginX = 0
        $labelOriginY = 0

        if ($captureRect.Width -le 0 -or $captureRect.Height -le 0) {
            throw "대상 창의 크기가 0 입니다 (최소화/숨김?): $($target.HandleHex). [exit=$(Get-ScExitCode WindowNotFound)]"
        }
        if ($Method -eq 'Screen') {
            $clipped = Get-ScRectIntersection -A $captureRect -B $vs
            if ($null -eq $clipped) {
                throw "대상 창이 화면 밖에 있습니다: $($captureRect.Left),$($captureRect.Top) $($captureRect.Width)x$($captureRect.Height). [exit=$(Get-ScExitCode OutOfBounds)]"
            }
            if ($clipped.Width -ne $captureRect.Width -or $clipped.Height -ne $captureRect.Height) {
                Write-Warning "창 일부가 화면 밖이라 잘라서 캡처합니다."
                $labelOriginX = $clipped.Left - $captureRect.Left
                $labelOriginY = $clipped.Top - $captureRect.Top
                $captureRect = $clipped
            }
        }
    }
    else {
        $Method = 'Screen'
        $captureRect = $vs
        $labelSpace = 'screen'
        $labelOriginX = $vs.Left
        $labelOriginY = $vs.Top
        Start-Sleep -Milliseconds $SettleMs
    }

    $saved = Save-ScCaptureImage -Method $Method -CaptureRect $captureRect `
        -WindowHandle $(if ($target) { $target.HandleValue } else { 0 }) -OutFile $imagePath -MaxWidth $MaxWidth
    $imgW = $saved.Width
    $imgH = $saved.Height
    $scale = $saved.Scale

    $gridPath = $null
    if (-not $NoGrid) {
        $gridPath = Join-Path $dir ($Name + '.grid.png')
        [void](Add-ScGridOverlay -SourcePath $imagePath -OutPath $gridPath -Step $GridStep -Scale $scale -OriginX $labelOriginX -OriginY $labelOriginY)
    }

    $meta = [ordered]@{
        version         = $script:ScreenControlVersion
        timestampUtc    = (Get-Date).ToUniversalTime().ToString('o')
        timestampLocal  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        mode            = $Mode
        method          = $Method
        note            = $Note
        imagePath       = $imagePath
        gridImagePath   = $gridPath
        imageWidth      = $imgW
        imageHeight     = $imgH
        scale           = $scale
        dpiMode         = $script:DpiMode
        labelSpace      = $labelSpace
        labelOrigin     = @{ x = $labelOriginX; y = $labelOriginY }
        origin          = @{ x = $captureRect.Left; y = $captureRect.Top }
        captureRect     = @{ left = $captureRect.Left; top = $captureRect.Top; right = $captureRect.Right; bottom = $captureRect.Bottom; width = $captureRect.Width; height = $captureRect.Height }
        virtualScreen   = @{ left = $vs.Left; top = $vs.Top; right = $vs.Right; bottom = $vs.Bottom; width = $vs.Width; height = $vs.Height }
        window          = $null
    }

    if ($Mode -eq 'Window') {
        $meta.window = [ordered]@{
            handle       = $target.HandleValue
            handleHex    = $target.HandleHex
            processId    = $target.ProcessId
            processName  = $target.ProcessName
            title        = $target.Title
            className    = $target.ClassName
            dpi          = $target.Dpi
            foreground   = $target.Foreground
            bounds       = @{ left = $target.Bounds.Left; top = $target.Bounds.Top; right = $target.Bounds.Right; bottom = $target.Bounds.Bottom; width = $target.Bounds.Width; height = $target.Bounds.Height }
            windowRect   = @{ left = $target.WindowRect.Left; top = $target.WindowRect.Top; right = $target.WindowRect.Right; bottom = $target.WindowRect.Bottom }
            clientRect   = @{ left = $target.ClientRect.Left; top = $target.ClientRect.Top; right = $target.ClientRect.Right; bottom = $target.ClientRect.Bottom; width = $target.ClientRect.Width; height = $target.ClientRect.Height }
        }
    }

    ($meta | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $metaPath -Encoding UTF8 -WhatIf:$false -Confirm:$false

    Write-ScLog -Action 'capture' -OutDir $dir -Data @{
        mode      = $Mode
        method    = $Method
        image     = $imagePath
        window    = if ($Mode -eq 'Window') { "$($target.HandleHex) $($target.ProcessName) :: $($target.Title)" } else { '(screen)' }
        note      = $Note
    }

    return [pscustomobject]@{
        ImagePath     = $imagePath
        GridImagePath = $gridPath
        MetaPath      = $metaPath
        Meta          = ($meta | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
        Window        = $target
    }
}

# ---------------------------------------------------------------------------
# 증거(캡처) 검증 + 클릭
# ---------------------------------------------------------------------------
function Get-ScProp {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Import-ScCaptureMeta {
    <#
    .SYNOPSIS
        캡처 PNG 또는 JSON 경로를 받아 메타데이터를 읽는다.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "증거 캡처 파일이 없습니다: $Path [exit=$(Get-ScExitCode EvidenceProblem)]"
    }
    $metaPath = $Path
    if ($Path -notmatch '\.json$') {
        $metaPath = [System.IO.Path]::ChangeExtension(($Path -replace '\.grid\.png$', '.png'), '.json')
    }
    if (-not (Test-Path -LiteralPath $metaPath)) {
        throw "캡처 메타데이터(JSON)가 없습니다: $metaPath (Capture-Screen.ps1 로 캡처하면 함께 생성됩니다) [exit=$(Get-ScExitCode EvidenceProblem)]"
    }
    $metaText = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8
    # Windows PowerShell 5.1 이 쓴 파일에는 BOM 이 붙어 있어 ConvertFrom-Json 이 실패할 수 있다
    $metaText = $metaText.TrimStart([char]0xFEFF)
    return ($metaText | ConvertFrom-Json)
}

function Test-ScEvidence {
    <#
    .SYNOPSIS
        "이 클릭은 최근에 본 화면에 근거하는가?" 를 검사한다. (블라인드 클릭 방지)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Meta,
        $Window,
        [int]$MaxAgeSeconds = 180,
        [switch]$AllowWindowMoved
    )

    $reasons = New-Object System.Collections.Generic.List[string]

    $imagePath = Get-ScProp $Meta 'imagePath'
    if (-not $imagePath -or -not (Test-Path -LiteralPath $imagePath)) {
        [void]$reasons.Add("캡처 이미지 파일이 존재하지 않습니다: $imagePath")
    }

    $age = $null
    $ts = Get-ScProp $Meta 'timestampUtc'
    if ($ts) {
        $age = ((Get-Date).ToUniversalTime() - ([datetime]::Parse($ts)).ToUniversalTime()).TotalSeconds
        if ($age -gt $MaxAgeSeconds) {
            [void]$reasons.Add(("캡처가 너무 오래되었습니다: {0:N0}초 전 (허용 {1}초). 다시 캡처하세요." -f $age, $MaxAgeSeconds))
        }
        if ($age -lt -5) {
            [void]$reasons.Add("캡처 시각이 미래입니다. 시스템 시계를 확인하세요.")
        }
    }
    else {
        [void]$reasons.Add("캡처 메타데이터에 timestampUtc 가 없습니다.")
    }

    if ($Window) {
        $metaWindow = Get-ScProp $Meta 'window'
        if ($null -eq $metaWindow) {
            [void]$reasons.Add("이 캡처는 전체 화면 캡처입니다. 창 대상 클릭에는 창 캡처(-ProcessName/-TitleLike)를 쓰세요.")
        }
        else {
            $metaHandle = [int64](Get-ScProp $metaWindow 'handle')
            if ($metaHandle -ne [int64]$Window.HandleValue) {
                [void]$reasons.Add("캡처된 창($('0x{0:X}' -f $metaHandle))과 클릭 대상 창($($Window.HandleHex))이 다릅니다.")
            }
            else {
                $b = Get-ScProp $metaWindow 'bounds'
                if ($b) {
                    $moved = ($b.left -ne $Window.Bounds.Left -or $b.top -ne $Window.Bounds.Top -or
                              $b.right -ne $Window.Bounds.Right -or $b.bottom -ne $Window.Bounds.Bottom)
                    if ($moved -and -not $AllowWindowMoved) {
                        [void]$reasons.Add(("캡처 이후 창이 움직이거나 크기가 바뀌었습니다. 캡처 당시 [{0},{1},{2},{3}] -> 현재 [{4},{5},{6},{7}]. 다시 캡처하세요." -f `
                            $b.left, $b.top, $b.right, $b.bottom,
                            $Window.Bounds.Left, $Window.Bounds.Top, $Window.Bounds.Right, $Window.Bounds.Bottom))
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        Ok         = ($reasons.Count -eq 0)
        Reasons    = $reasons.ToArray()
        AgeSeconds = $age
    }
}

function Invoke-ScClick {
    <#
    .SYNOPSIS
        검증을 모두 통과한 경우에만 실제 마우스 클릭을 보낸다.
    .DESCRIPTION
        검사 순서:
          1) 창 유효/표시 상태  2) 활성화 후 포그라운드 확인  3) 화면 경계
          4) 창 경계            5) 그 좌표의 실제 창 = 대상 창
          6) 증거 캡처 신선도   7) 위험 의도 승인
          8) 커서 이동 -> 지연 -> 커서 위치 재확인 -> 버튼 down/up
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][int]$ScreenX,
        [Parameter(Mandatory)][int]$ScreenY,
        [Parameter(Mandatory)][string]$Intent,
        $EvidenceMeta,
        [int]$EvidenceMaxAgeSeconds = 180,
        [switch]$AllowWindowMoved,
        [ValidateSet('Left', 'Right', 'Middle')][string]$Button = 'Left',
        [switch]$DoubleClick,
        [int]$MoveDelayMs = 250,
        [int]$PressDelayMs = 60,
        [int]$SettleMs = 400,
        [switch]$AllowOutsideWindow,
        [switch]$UserApproved,
        [ValidateSet('Auto', 'Normal', 'High')][string]$Risk = 'Auto',
        [switch]$RestoreCursor,
        [switch]$UseAbsoluteMove,
        [string]$OutDir
    )

    Initialize-ScNative | Out-Null
    $dir = Resolve-ScOutDir -OutDir $OutDir

    # --- 1) 창 상태 --------------------------------------------------------
    $h = [IntPtr]$Window.HandleValue
    if (-not [ScreenControl.Native]::IsWindow($h)) {
        throw "클릭 대상 창이 사라졌습니다: $($Window.HandleHex). 클릭하지 않았습니다. [exit=$(Get-ScExitCode WindowNotFound)]"
    }
    if (-not [ScreenControl.Native]::IsWindowVisible($h)) {
        throw "클릭 대상 창이 보이지 않는 상태입니다: $($Window.HandleHex). 클릭하지 않았습니다. [exit=$(Get-ScExitCode WindowNotFound)]"
    }
    if ([ScreenControl.Native]::IsIconic($h)) {
        throw "클릭 대상 창이 최소화되어 있습니다: $($Window.HandleHex). 클릭하지 않았습니다. [exit=$(Get-ScExitCode ActivationFailed)]"
    }

    # --- 2) 활성화 ---------------------------------------------------------
    $live = Set-ScWindowActive -Window $Window -TimeoutMs 2500
    if (-not $live.Foreground) {
        throw "대상 창이 활성 상태가 아닙니다. 클릭하지 않았습니다. [exit=$(Get-ScExitCode ActivationFailed)]"
    }

    # --- 3) 화면 경계 ------------------------------------------------------
    $vs = Get-ScVirtualScreen
    if (-not (Test-ScPointInRect -X $ScreenX -Y $ScreenY -Rect $vs)) {
        throw "좌표가 화면 밖입니다: ($ScreenX,$ScreenY), 화면 영역 [$($vs.Left),$($vs.Top),$($vs.Right),$($vs.Bottom)]. 클릭하지 않았습니다. [exit=$(Get-ScExitCode OutOfBounds)]"
    }

    # --- 4) 창 경계 --------------------------------------------------------
    $inWindow = Test-ScPointInRect -X $ScreenX -Y $ScreenY -Rect $live.Bounds
    if (-not $inWindow -and -not $AllowOutsideWindow) {
        throw ("좌표가 대상 창 밖입니다: ($ScreenX,$ScreenY), 창 영역 [{0},{1},{2},{3}] ({4}x{5}). 드롭다운/팝업을 의도했다면 -AllowOutsideWindow 를 명시하세요. 클릭하지 않았습니다. [exit={6}]" -f `
            $live.Bounds.Left, $live.Bounds.Top, $live.Bounds.Right, $live.Bounds.Bottom, $live.Bounds.Width, $live.Bounds.Height, (Get-ScExitCode OutOfBounds))
    }

    # --- 5) 그 좌표에 실제로 대상 창이 있는가 ------------------------------
    $hitRoot = [ScreenControl.Native]::RootWindowOf([ScreenControl.Native]::WindowAtPoint($ScreenX, $ScreenY))
    $hitIsTarget = ($hitRoot -eq $h)
    if (-not $hitIsTarget -and -not $AllowOutsideWindow) {
        $hitTitle = ''
        try { $hitTitle = [ScreenControl.Native]::GetTitle($hitRoot) } catch { $hitTitle = '?' }
        throw ("그 좌표를 실제로 차지한 창이 대상이 아닙니다: 0x{0:X} '{1}' (대상 {2}). 다른 창이 가리고 있을 수 있습니다. 클릭하지 않았습니다. [exit={3}]" -f `
            [int64]$hitRoot, $hitTitle, $Window.HandleHex, (Get-ScExitCode OutOfBounds))
    }

    # --- 6) 증거 캡처 ------------------------------------------------------
    if ($null -eq $EvidenceMeta) {
        throw "클릭 전에 캡처한 증거 이미지가 필요합니다 (-Evidence). 보지 않고 클릭하지 않습니다. [exit=$(Get-ScExitCode EvidenceProblem)]"
    }
    $ev = Test-ScEvidence -Meta $EvidenceMeta -Window $live -MaxAgeSeconds $EvidenceMaxAgeSeconds -AllowWindowMoved:$AllowWindowMoved
    if (-not $ev.Ok) {
        throw ("증거 캡처 검증 실패 (클릭하지 않았습니다):`n - " + ($ev.Reasons -join "`n - ") + "`n[exit=$(Get-ScExitCode EvidenceProblem)]")
    }

    # --- 7) 위험 의도 승인 -------------------------------------------------
    $danger = Get-ScDangerMatch -Intent $Intent
    $isHigh = ($Risk -eq 'High') -or ($Risk -eq 'Auto' -and $danger.IsDangerous)
    if ($isHigh -and -not $UserApproved) {
        $why = if ($danger.IsDangerous) { "위험 키워드 감지: $($danger.Matches -join ', ')" } else { '-Risk High 로 지정됨' }
        throw ("위험할 수 있는 클릭입니다 ($why). 사용자에게 '$Intent' 를 실행해도 되는지 먼저 확인하고, 승인받은 뒤 -UserApproved 를 붙여 다시 실행하세요. 클릭하지 않았습니다. [exit=$(Get-ScExitCode ApprovalRequired)]")
    }

    # --- 미리보기(-WhatIf) -------------------------------------------------
    $evidenceImage = Get-ScProp $EvidenceMeta 'imagePath'
    $previewPath = $null
    if ($evidenceImage -and (Test-Path -LiteralPath $evidenceImage)) {
        $imgPoint = ConvertTo-ScImagePointFromScreen -ScreenX $ScreenX -ScreenY $ScreenY -Meta $EvidenceMeta
        if ($imgPoint.X -ge 0 -and $imgPoint.Y -ge 0 -and $imgPoint.X -lt (Get-ScProp $EvidenceMeta 'imageWidth') -and $imgPoint.Y -lt (Get-ScProp $EvidenceMeta 'imageHeight')) {
            $previewPath = Join-Path $dir ([System.IO.Path]::GetFileNameWithoutExtension($evidenceImage) + '.target.png')
            [void](Add-ScMarker -SourcePath $evidenceImage -OutPath $previewPath -X $imgPoint.X -Y $imgPoint.Y -Label "click ($ScreenX,$ScreenY)")
        }
    }

    $description = "$Button 클릭 ($ScreenX,$ScreenY) on $($live.HandleHex) [$($live.ProcessName)] '$($live.Title)' :: $Intent"
    if (-not $PSCmdlet.ShouldProcess($description, 'Invoke-ScClick')) {
        Write-ScLog -Action 'click-whatif' -OutDir $dir -Data @{
            intent = $Intent; x = $ScreenX; y = $ScreenY; window = $live.HandleHex
            title = $live.Title; preview = $previewPath
        }
        return [pscustomobject]@{
            Performed   = $false
            WhatIf      = $true
            ScreenX     = $ScreenX
            ScreenY     = $ScreenY
            Window      = $live
            PreviewPath = $previewPath
            Intent      = $Intent
            RiskHigh    = $isHigh
        }
    }

    # --- 8) 실제 이동 + 클릭 ----------------------------------------------
    $origCursor = [ScreenControl.Native]::GetCursor()

    if ($UseAbsoluteMove) {
        $abs = ConvertTo-ScAbsoluteMousePoint -X $ScreenX -Y $ScreenY -VirtualScreen $vs
        [void][ScreenControl.Native]::SendMouse(
            ([ScreenControl.Native]::MOUSEEVENTF_MOVE -bor [ScreenControl.Native]::MOUSEEVENTF_ABSOLUTE -bor [ScreenControl.Native]::MOUSEEVENTF_VIRTUALDESK),
            $abs.Dx, $abs.Dy)
    }
    else {
        [void][ScreenControl.Native]::SetCursorPos($ScreenX, $ScreenY)
    }

    # Windows UI(호버 상태, 애니메이션)가 따라올 시간을 준다.
    Start-Sleep -Milliseconds $MoveDelayMs

    $now = [ScreenControl.Native]::GetCursor()
    if ([Math]::Abs($now.X - $ScreenX) -gt 2 -or [Math]::Abs($now.Y - $ScreenY) -gt 2) {
        throw ("커서가 의도한 위치로 가지 않았습니다: 요청 ($ScreenX,$ScreenY) / 실제 ($($now.X),$($now.Y)). 다른 프로그램이 커서를 제어 중이거나 DPI 문제일 수 있습니다. 버튼은 누르지 않았습니다. [exit=$(Get-ScExitCode CursorVerifyFailed)]")
    }

    $hitRoot2 = [ScreenControl.Native]::RootWindowOf([ScreenControl.Native]::WindowAtPoint($now.X, $now.Y))
    if ($hitRoot2 -ne $h -and -not $AllowOutsideWindow) {
        throw ("커서 이동 후 그 지점의 창이 대상이 아닙니다 (0x{0:X}). 버튼은 누르지 않았습니다. [exit={1}]" -f [int64]$hitRoot2, (Get-ScExitCode OutOfBounds))
    }

    $downFlag = switch ($Button) {
        'Left'   { [ScreenControl.Native]::MOUSEEVENTF_LEFTDOWN }
        'Right'  { [ScreenControl.Native]::MOUSEEVENTF_RIGHTDOWN }
        'Middle' { [ScreenControl.Native]::MOUSEEVENTF_MIDDLEDOWN }
    }
    $upFlag = switch ($Button) {
        'Left'   { [ScreenControl.Native]::MOUSEEVENTF_LEFTUP }
        'Right'  { [ScreenControl.Native]::MOUSEEVENTF_RIGHTUP }
        'Middle' { [ScreenControl.Native]::MOUSEEVENTF_MIDDLEUP }
    }

    $clicks = if ($DoubleClick) { 2 } else { 1 }
    for ($i = 0; $i -lt $clicks; $i++) {
        if ([ScreenControl.Native]::SendMouse($downFlag, 0, 0) -ne 1) {
            throw "SendInput(버튼 누름)이 실패했습니다. 권한이 더 높은 창이 입력을 차단했을 수 있습니다. [exit=$(Get-ScExitCode GeneralError)]"
        }
        Start-Sleep -Milliseconds $PressDelayMs
        if ([ScreenControl.Native]::SendMouse($upFlag, 0, 0) -ne 1) {
            throw "SendInput(버튼 뗌)이 실패했습니다. [exit=$(Get-ScExitCode GeneralError)]"
        }
        if ($i -lt ($clicks - 1)) { Start-Sleep -Milliseconds 60 }
    }

    Start-Sleep -Milliseconds $SettleMs

    if ($RestoreCursor) {
        [void][ScreenControl.Native]::SetCursorPos($origCursor.X, $origCursor.Y)
    }

    Write-ScLog -Action 'click' -OutDir $dir -Data @{
        intent   = $Intent
        button   = $Button
        double   = [bool]$DoubleClick
        x        = $ScreenX
        y        = $ScreenY
        window   = $live.HandleHex
        process  = $live.ProcessName
        title    = $live.Title
        riskHigh = $isHigh
        approved = [bool]$UserApproved
        evidence = (Get-ScProp $EvidenceMeta 'imagePath')
        preview  = $previewPath
    }

    return [pscustomobject]@{
        Performed   = $true
        WhatIf      = $false
        ScreenX     = $ScreenX
        ScreenY     = $ScreenY
        Button      = $Button
        DoubleClick = [bool]$DoubleClick
        Window      = $live
        PreviewPath = $previewPath
        Intent      = $Intent
        RiskHigh    = $isHigh
    }
}

function Compare-ScCapture {
    <#
    .SYNOPSIS
        두 캡처 이미지의 변화량을 계산한다 (클릭 후 상태 변화 확인용).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BeforePath,
        [Parameter(Mandatory)][string]$AfterPath,
        [int]$Tolerance = 12
    )
    Initialize-ScNative | Out-Null
    foreach ($p in @($BeforePath, $AfterPath)) {
        if (-not (Test-Path -LiteralPath $p)) { throw "이미지가 없습니다: $p [exit=$(Get-ScExitCode InvalidArguments)]" }
    }
    $a = (Resolve-Path -LiteralPath $BeforePath).Path
    $b = (Resolve-Path -LiteralPath $AfterPath).Path
    $d = [ScreenControl.Imaging]::Diff($a, $b, $Tolerance)
    return [pscustomobject]@{
        BeforePath    = $a
        AfterPath     = $b
        SizeMismatch  = $d.SizeMismatch
        TotalPixels   = $d.TotalPixels
        ChangedPixels = $d.ChangedPixels
        ChangedRatio  = $d.ChangedRatio
        ChangedPct    = [Math]::Round($d.ChangedRatio * 100, 3)
        ChangedBox    = if ($d.Right -ge 0) { New-ScRect -Left $d.Left -Top $d.Top -Right $d.Right -Bottom $d.Bottom } else { $null }
    }
}

Export-ModuleMember -Function *-Sc*, Get-ScExitCode, Get-ScVersion, Get-ScDpiMode, Test-ScWindowsPlatform, Initialize-ScNative
