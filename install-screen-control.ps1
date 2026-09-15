<#
.SYNOPSIS
    Windows PC 에 Claude Code(CLI) 와 screen-control 스킬을 설치하고, 설치가 제대로 됐는지 검증한다.

.DESCRIPTION
    한 번에 다음을 수행한다.
      1) 환경 점검 (Windows / PowerShell / 실행 정책)
      2) Node.js 확인 (없으면 winget 으로 설치 시도)
      3) Claude Code CLI 설치 (npm install -g @anthropic-ai/claude-code)
      4) screen-control 스킬을 GitHub 에서 받아 %USERPROFILE%\.claude\skills\screen-control 에 설치
      5) 검증: 로직 테스트 + 통합 테스트(가짜 창) + 실기 테스트(메모장이 잠깐 떴다 닫힘)

    관리자 권한은 필요 없다. 이미 설치된 항목은 건너뛴다. 여러 번 실행해도 안전하다.

.EXAMPLE
    # 전체 설치 + 검증
    powershell -ExecutionPolicy Bypass -File .\install-screen-control.ps1

.EXAMPLE
    # 스킬만 다시 받기 (Claude Code 는 이미 있음, 메모장 테스트 생략)
    .\install-screen-control.ps1 -SkipClaudeCode -SkipRealTest
#>
[CmdletBinding()]
param(
    [string]$Repo = 'zogumm/zogumm',
    [string]$Branch = 'claude/windows-screen-capture-click-6m6ahx',
    [string]$Destination = '',   # 비우면 %USERPROFILE%\.claude\skills\screen-control
    [switch]$SkipClaudeCode,
    [switch]$SkipNode,
    [switch]$SkipTests,
    [switch]$SkipRealTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:Steps = New-Object System.Collections.Generic.List[object]

function Write-Step { param([string]$Text) Write-Host ""; Write-Host "==== $Text" -ForegroundColor Cyan }
function Write-Ok { param([string]$Text) Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn2 { param([string]$Text) Write-Host "  [주의] $Text" -ForegroundColor Yellow }
function Write-Bad { param([string]$Text) Write-Host "  [실패] $Text" -ForegroundColor Red }
function Add-Step { param([string]$Name, [string]$State, [string]$Detail = '')
    [void]$script:Steps.Add([pscustomobject]@{ Step = $Name; Result = $State; Note = $Detail })
}
function Test-Command { param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

if (-not $Destination) {
    $home_ = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $Destination = Join-Path $home_ '.claude\skills\screen-control'
}

Write-Host ""
Write-Host "screen-control 설치 스크립트" -ForegroundColor White
Write-Host "리포: $Repo / 브랜치: $Branch"
Write-Host "설치 위치: $Destination"

# ---------------------------------------------------------------------------
# 1) 환경 점검
# ---------------------------------------------------------------------------
Write-Step "1/5 환경 점검"
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-Bad "이 스크립트는 Windows 에서 실행해야 합니다 (현재: $([System.Environment]::OSVersion.Platform))."
    exit 7
}
Write-Ok "Windows: $([System.Environment]::OSVersion.VersionString)"
Write-Ok "PowerShell: $($PSVersionTable.PSVersion)"
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Bad "PowerShell 5.1 이상이 필요합니다."
    exit 7
}
$arch = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
Write-Ok "프로세스 아키텍처: $arch"
Add-Step '환경 점검' '완료' "PowerShell $($PSVersionTable.PSVersion)"

# ---------------------------------------------------------------------------
# 2) Node.js
# ---------------------------------------------------------------------------
Write-Step "2/5 Node.js 확인"
$nodeOk = $false
if ($SkipNode) {
    Write-Warn2 "-SkipNode 지정됨 — 건너뜁니다."
    Add-Step 'Node.js' '건너뜀'
}
elseif (Test-Command 'node') {
    $nodeVersion = (& node -v) 2>$null
    Write-Ok "이미 설치됨: $nodeVersion"
    $nodeOk = $true
    Add-Step 'Node.js' '이미 있음' $nodeVersion
}
else {
    Write-Warn2 "Node.js 가 없습니다. Claude Code CLI 설치에 필요합니다."
    if (Test-Command 'winget') {
        Write-Host "  winget 으로 설치를 시도합니다 (UAC 창이 뜰 수 있습니다)..."
        try {
            & winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
            Write-Ok "Node.js 설치 명령 완료 — PATH 반영을 위해 터미널을 새로 열어야 할 수 있습니다."
            Add-Step 'Node.js' '설치함' 'winget'
        }
        catch {
            Write-Bad "winget 설치 실패: $($_.Exception.Message)"
            Add-Step 'Node.js' '실패' 'https://nodejs.org 에서 수동 설치'
        }
    }
    else {
        Write-Warn2 "winget 이 없습니다. https://nodejs.org 에서 LTS 버전을 직접 설치해 주세요."
        Add-Step 'Node.js' '수동 필요' 'https://nodejs.org'
    }
}

# ---------------------------------------------------------------------------
# 3) Claude Code CLI
# ---------------------------------------------------------------------------
Write-Step "3/5 Claude Code CLI"
if ($SkipClaudeCode) {
    Write-Warn2 "-SkipClaudeCode 지정됨 — 건너뜁니다."
    Add-Step 'Claude Code' '건너뜀'
}
elseif (Test-Command 'claude') {
    $claudeVersion = ''
    try { $claudeVersion = (& claude --version) 2>$null } catch { $claudeVersion = '(버전 확인 실패)' }
    Write-Ok "이미 설치됨: $claudeVersion"
    Add-Step 'Claude Code' '이미 있음' "$claudeVersion"
}
elseif (Test-Command 'npm') {
    Write-Host "  npm install -g @anthropic-ai/claude-code 실행 중... (몇 분 걸릴 수 있습니다)"
    try {
        & npm install -g @anthropic-ai/claude-code
        if ($LASTEXITCODE -ne 0) { throw "npm 이 $LASTEXITCODE 코드로 종료" }
        Write-Ok "설치 완료. 새 터미널에서 'claude' 명령을 쓸 수 있습니다."
        Add-Step 'Claude Code' '설치함' 'npm -g'
    }
    catch {
        Write-Bad "설치 실패: $($_.Exception.Message)"
        Write-Warn2 "터미널을 새로 열고 다시 실행하거나, 수동으로 'npm install -g @anthropic-ai/claude-code' 를 실행해 보세요."
        Add-Step 'Claude Code' '실패' $_.Exception.Message
    }
}
else {
    Write-Warn2 "npm 이 없습니다 (Node.js 설치 후 터미널을 새로 열어야 합니다). 스킬 설치는 계속 진행합니다."
    Add-Step 'Claude Code' '보류' 'Node.js 설치 후 재실행'
}

# ---------------------------------------------------------------------------
# 4) 스킬 다운로드 + 설치
# ---------------------------------------------------------------------------
Write-Step "4/5 screen-control 스킬 설치"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('sc-install-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $zipUrl = "https://codeload.github.com/$Repo/zip/refs/heads/$Branch"
    $zipPath = Join-Path $tempRoot 'skill.zip'
    Write-Host "  다운로드: $zipUrl"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    Write-Ok ("받은 크기: {0:N0} bytes" -f (Get-Item $zipPath).Length)

    $extractDir = Join-Path $tempRoot 'extract'
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    $sourceDir = Get-ChildItem -Path $extractDir -Recurse -Directory -Filter 'screen-control' | Select-Object -First 1
    if (-not $sourceDir) { throw "압축 안에서 screen-control 폴더를 찾지 못했습니다." }

    if (Test-Path -LiteralPath $Destination) {
        $backup = "$Destination.bak-" + (Get-Date).ToString('yyyyMMdd-HHmmss')
        Move-Item -LiteralPath $Destination -Destination $backup
        Write-Warn2 "기존 설치를 백업했습니다: $backup"
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $sourceDir.FullName | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }

    $skillMd = Join-Path $Destination 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMd)) { throw "SKILL.md 가 복사되지 않았습니다." }
    $fileCount = (Get-ChildItem -LiteralPath $Destination -Recurse -File).Count
    Write-Ok "설치 완료: $Destination (파일 $fileCount 개)"
    Add-Step '스킬 설치' '완료' $Destination
}
catch {
    Write-Bad "스킬 설치 실패: $($_.Exception.Message)"
    Add-Step '스킬 설치' '실패' $_.Exception.Message
    Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue
    exit 1
}
finally {
    Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 5) 검증
# ---------------------------------------------------------------------------
Write-Step "5/5 검증"
$psExe = (Get-Process -Id $PID).Path
function Invoke-TestScript {
    param([string]$Name, [string]$Path, [string[]]$ExtraArgs = @())
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Bad "$Name : 스크립트를 찾을 수 없습니다 ($Path)"
        Add-Step $Name '없음' $Path
        return $false
    }
    Write-Host "  $Name 실행 중..."
    $output = & $psExe -NoProfile -ExecutionPolicy Bypass -File $Path @ExtraArgs 2>&1
    $code = $LASTEXITCODE
    $tail = ($output | Select-Object -Last 3 | Out-String).Trim()
    if ($code -eq 0) {
        Write-Ok "$Name 통과"
        Add-Step $Name '통과' ($tail -split "`n" | Select-Object -Last 1)
        return $true
    }
    Write-Bad "$Name 실패 (exit=$code)"
    Write-Host ($output | Out-String)
    Add-Step $Name '실패' "exit=$code"
    return $false
}

if ($SkipTests) {
    Write-Warn2 "-SkipTests 지정됨 — 검증을 건너뜁니다."
}
else {
    [void](Invoke-TestScript '로직 테스트' (Join-Path $Destination 'scripts\Test-Logic.ps1'))
    [void](Invoke-TestScript '통합 테스트(가짜 창)' (Join-Path $Destination 'tests\Test-Integration.ps1'))
    if ($SkipRealTest) {
        Write-Warn2 "-SkipRealTest 지정됨 — 실기 테스트를 건너뜁니다."
    }
    else {
        Write-Host ""
        Write-Warn2 "이제 실기 테스트를 합니다. 메모장이 잠깐 떴다가 자동으로 닫히고, 그 창을 실제로 클릭합니다."
        Write-Host "  (중단하려면 지금 Ctrl+C. 3초 후 시작합니다)"
        Start-Sleep -Seconds 3
        [void](Invoke-TestScript '실기 테스트(진짜 캡처+클릭)' (Join-Path $Destination 'scripts\Test-ScreenControl.ps1'))
    }
}

# ---------------------------------------------------------------------------
# 요약
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "================ 설치 요약 ================" -ForegroundColor White
Write-Host ((
    $script:Steps | Select-Object @{ n = '단계'; e = { $_.Step } }, @{ n = '결과'; e = { $_.Result } }, @{ n = '비고'; e = { $_.Note } } |
        Format-Table -AutoSize | Out-String -Width 200
).TrimEnd())
Write-Host ""

$failed = @($script:Steps | Where-Object { $_.Result -eq '실패' })
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) 개 단계가 실패했습니다. 위 메시지를 Claude 에게 그대로 붙여넣으면 됩니다." -ForegroundColor Yellow
}
else {
    Write-Host "설치 완료." -ForegroundColor Green
}

Write-Host ""
Write-Host "다음 단계:" -ForegroundColor Cyan
Write-Host "  1) 터미널을 새로 열고  cd D:\ai  후  claude  실행 (처음이면 로그인 안내가 나옵니다)"
Write-Host "  2) 그 안에서 이렇게 말하면 됩니다:"
Write-Host "       \"메모장 띄웠는데 화면 캡처해서 보여줘\"" -ForegroundColor DarkGray
Write-Host "       \"AutoCAD 창 보고 저 대화상자에서 레이어 버튼 눌러줘\"" -ForegroundColor DarkGray
Write-Host "  * 관리자 권한으로 실행 중인 앱을 조작하려면 claude 도 관리자 터미널에서 실행하세요."
Write-Host "  * 캡처 이미지와 감사 로그 위치: D:\ai\.screen-control (D 드라이브 없으면 %LOCALAPPDATA%\screen-control)"
Write-Host ""
