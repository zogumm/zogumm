<#
.SYNOPSIS
    Windows 없이 전체 흐름을 검증하는 통합 테스트 (모의 Win32 백엔드 사용).

.DESCRIPTION
    tests/MockBackend.ps1 이 user32/GDI 호출을 대신하므로, 실제 창이나 마우스 없이
    "창 확정 -> 검증 게이트 -> 좌표 변환 -> 클릭 순서" 를 그대로 실행해 볼 수 있다.
    각 시나리오는 CLI 스크립트를 자식 프로세스로 실행해 종료 코드와 실제로 전송된
    마우스 이벤트를 확인한다. 거부되어야 하는 경우에는 클릭 이벤트가 하나도
    발생하지 않았음을 함께 확인한다.

    Windows 에서도 그대로 돌아간다(진짜 창을 건드리지 않는다). 실제 GDI 캡처와
    SendInput 경로는 scripts/Test-ScreenControl.ps1 이 담당한다.

.EXAMPLE
    pwsh -File .\tests\Test-Integration.ps1
#>
[CmdletBinding()]
param([switch]$KeepArtifacts)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$scriptsDir = Join-Path $skillRoot 'scripts'
$mockPath = Join-Path $PSScriptRoot 'MockBackend.ps1'
$hostExe = (Get-Process -Id $PID).Path

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('sc-itest-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$statePath = Join-Path $work 'state.json'
$eventLog = Join-Path $work 'events.log'

$env:SCREEN_CONTROL_MOCK = $mockPath
$env:SCREEN_CONTROL_MOCK_STATE = $statePath
$env:SCREEN_CONTROL_OUT = $work

$script:Failures = 0
$script:Count = 0

function Set-MockState {
    param(
        [hashtable]$Window1 = @{},
        [switch]$Minimized,
        [switch]$ActivateFails,
        [switch]$SendInputFails,
        [int]$CursorDrift = 0,
        [hashtable]$Blocker,
        [string]$SecondTitle = '다른 앱 창'
    )
    $b = @{ left = 100; top = 100; right = 900; bottom = 700 }
    foreach ($k in $Window1.Keys) { $b[$k] = $Window1[$k] }
    $state = [ordered]@{
        windows = @(
            [ordered]@{
                handle = 1001; title = '모의 메모장 - 제목 없음'; className = 'Notepad'; pid = 4242
                visible = $true; iconic = [bool]$Minimized; dpi = 96
                bounds = $b
                client = @{ left = ($b.left + 8); top = ($b.top + 40); right = ($b.right - 8); bottom = ($b.bottom - 8) }
            },
            [ordered]@{
                handle = 2002; title = $SecondTitle; className = 'Other'; pid = 555
                visible = $true; iconic = $false; dpi = 96
                bounds = @{ left = 1000; top = 100; right = 1500; bottom = 500 }
                client = @{ left = 1008; top = 140; right = 1492; bottom = 492 }
            }
        )
        foreground = 2002
        eventLog = $eventLog
        cursorDrift = $CursorDrift
        activateFails = [bool]$ActivateFails
        sendInputFails = [bool]$SendInputFails
        virtualScreen = @{ left = 0; top = 0; right = 1920; bottom = 1080 }
    }
    if ($Blocker) { $state.blocker = $Blocker }
    ($state | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Clear-Events { Set-Content -LiteralPath $eventLog -Value '' -Encoding UTF8 }

function Get-ClickEvents {
    if (-not (Test-Path -LiteralPath $eventLog)) { return @() }
    return @(Get-Content -LiteralPath $eventLog | Where-Object { $_ -match '^(down|up|absmove)' })
}

function Invoke-Cli {
    param([string]$Script, [string[]]$CliArgs)
    $out = & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsDir $Script) @CliArgs 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($out | Out-String) }
}

function ConvertFrom-CliJson {
    # 경고 줄이 섞여 들어와도 JSON 본문만 잘라서 해석한다.
    param([string]$Text)
    $Text = $Text.TrimStart([char]0xFEFF)
    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { return $null }
    return ($Text.Substring($start, $end - $start + 1) | ConvertFrom-Json)
}

function Test-Case {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:Count++
    if ($Ok) { Write-Host ("[PASS] {0}  {1}" -f $Name, $Detail) -ForegroundColor Green }
    else { Write-Host ("[FAIL] {0}  {1}" -f $Name, $Detail) -ForegroundColor Red; $script:Failures++ }
}

Write-Host "통합 테스트 작업 폴더: $work" -ForegroundColor DarkGray
Write-Host ""

# =====================================================================
# 1. 창 목록
# =====================================================================
Set-MockState
Clear-Events
$r = Invoke-Cli 'Get-Window.ps1' @()
Test-Case '창 목록에 모의 창 2개가 보인다' (($r.Code -eq 0) -and ($r.Output -match '모의 메모장') -and ($r.Output -match '다른 앱 창')) "exit=$($r.Code)"

$r = Invoke-Cli 'Get-Window.ps1' @('-TitleLike', '모의')
Test-Case '제목 필터가 동작한다' (($r.Code -eq 0) -and ($r.Output -match '모의 메모장') -and ($r.Output -notmatch '다른 앱 창')) "exit=$($r.Code)"

# =====================================================================
# 2. 캡처 + 메타데이터
# =====================================================================
$r = Invoke-Cli 'Capture-Screen.ps1' @('-Handle', '0x3E9', '-Name', 't1', '-OutDir', $work)
$meta = $null
if (Test-Path -LiteralPath (Join-Path $work 't1.json')) {
    $meta = (Get-Content -LiteralPath (Join-Path $work 't1.json') -Raw).TrimStart([char]0xFEFF) | ConvertFrom-Json
}
Test-Case '창 캡처가 png/grid/json 을 만든다' (
    ($r.Code -eq 0) -and (Test-Path (Join-Path $work 't1.png')) -and (Test-Path (Join-Path $work 't1.grid.png')) -and ($null -ne $meta) -and
    ($meta.window.handle -eq 1001) -and ($meta.labelSpace -eq 'window') -and ($meta.origin.x -eq 100) -and ($meta.origin.y -eq 100)
) "exit=$($r.Code)"

# =====================================================================
# 3. 좌표 변환
# =====================================================================
$r = Invoke-Cli 'Convert-Point.ps1' @('-Handle', '0x3E9', '-WindowX', '50', '-WindowY', '60', '-Json')
$pt = $null
if ($r.Code -eq 0) { $pt = ConvertFrom-CliJson $r.Output }
Test-Case '창 좌표 -> 화면/클라이언트 변환' (
    ($null -ne $pt) -and ($pt.screen.x -eq 150) -and ($pt.screen.y -eq 160) -and
    ($pt.client.x -eq 42) -and ($pt.client.y -eq 20) -and $pt.insideWindow
) "screen=$($pt.screen.x),$($pt.screen.y) client=$($pt.client.x),$($pt.client.y)"

# =====================================================================
# 4. 정상 클릭 (창 좌표 / 화면 좌표 / 클라이언트 좌표)
# =====================================================================
Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '빈 영역 클릭', '-WindowX', '300', '-WindowY', '200', '-NoAfterCapture', '-OutDir', $work)
$ev = @(Get-ClickEvents)
Test-Case '창 좌표 클릭이 정확한 화면 좌표로 간다' (
    ($r.Code -eq 0) -and (($ev -join ' ') -match 'down flags=2 at 400,300') -and (($ev -join ' ') -match 'up flags=4 at 400,300')
) "exit=$($r.Code) events=$($ev.Count)"

Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '빈 영역 클릭', '-ScreenX', '250', '-ScreenY', '250', '-NoAfterCapture', '-OutDir', $work)
Test-Case '화면 절대 좌표 클릭' (($r.Code -eq 0) -and (@(Get-ClickEvents) -join ' ') -match 'down flags=2 at 250,250') "exit=$($r.Code)"

Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '빈 영역 클릭', '-ClientX', '10', '-ClientY', '10', '-NoAfterCapture', '-OutDir', $work)
Test-Case '클라이언트 좌표 클릭' (($r.Code -eq 0) -and (@(Get-ClickEvents) -join ' ') -match 'down flags=2 at 118,150') "exit=$($r.Code)"

# =====================================================================
# 5. 축소 캡처에서의 이미지 좌표 보정
# =====================================================================
$r = Invoke-Cli 'Capture-Screen.ps1' @('-Handle', '0x3E9', '-Name', 'small', '-MaxWidth', '400', '-OutDir', $work)
$smallMeta = (Get-Content -LiteralPath (Join-Path $work 'small.json') -Raw).TrimStart([char]0xFEFF) | ConvertFrom-Json
Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 'small.png'), '-Intent', '축소 이미지 좌표 클릭', '-ImageX', '100', '-ImageY', '50', '-NoAfterCapture', '-OutDir', $work)
Test-Case '축소 캡처(scale 0.5)에서 이미지 좌표 보정' (
    ($smallMeta.scale -eq 0.5) -and ($r.Code -eq 0) -and ((@(Get-ClickEvents) -join ' ') -match 'down flags=2 at 300,200')
) "scale=$($smallMeta.scale) exit=$($r.Code)"

# =====================================================================
# 6. 버튼 종류 / 더블클릭
# =====================================================================
Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '컨텍스트 메뉴 열기', '-WindowX', '300', '-WindowY', '200', '-Button', 'Right', '-NoAfterCapture', '-OutDir', $work)
Test-Case '오른쪽 버튼 클릭' (($r.Code -eq 0) -and (@(Get-ClickEvents) -join ' ') -match 'down flags=8') "exit=$($r.Code)"

Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '항목 열기', '-WindowX', '300', '-WindowY', '200', '-Double', '-NoAfterCapture', '-OutDir', $work)
$downs = @(@(Get-ClickEvents) | Where-Object { $_ -match '^down' })
Test-Case '더블클릭은 down/up 이 두 번' (($r.Code -eq 0) -and ($downs.Count -eq 2)) "exit=$($r.Code) down=$($downs.Count)"

# =====================================================================
# 7. 거부 시나리오 — 모두 "클릭 이벤트 0건" 이어야 한다
# =====================================================================
Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '창 밖', '-WindowX', '5000', '-WindowY', '10', '-NoAfterCapture', '-OutDir', $work)
Test-Case '거부: 화면 밖 좌표 (exit 4, 클릭 없음)' (($r.Code -eq 4) -and (@(Get-ClickEvents).Count -eq 0)) "exit=$($r.Code)"

Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '창 밖이지만 화면 안', '-WindowX', '1000', '-WindowY', '10', '-NoAfterCapture', '-OutDir', $work)
Test-Case '거부: 창 밖 좌표 (exit 4, 클릭 없음)' (($r.Code -eq 4) -and (@(Get-ClickEvents).Count -eq 0)) "exit=$($r.Code)"

Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 'nothing.png'), '-Intent', '증거 없음', '-Handle', '0x3E9', '-WindowX', '100', '-WindowY', '100', '-NoAfterCapture', '-OutDir', $work)
Test-Case '거부: 증거 캡처 없음 (exit 5, 클릭 없음)' (($r.Code -eq 5) -and (@(Get-ClickEvents).Count -eq 0)) "exit=$($r.Code)"

Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '저장 버튼 클릭', '-WindowX', '300', '-WindowY', '200', '-NoAfterCapture', '-OutDir', $work)
Test-Case '거부: 위험 의도 무승인 (exit 6, 클릭 없음)' (($r.Code -eq 6) -and (@(Get-ClickEvents).Count -eq 0)) "exit=$($r.Code)"

Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '저장 버튼 클릭', '-WindowX', '300', '-WindowY', '200', '-UserApproved', '-NoAfterCapture', '-OutDir', $work)
Test-Case '승인 후에는 위험 클릭 허용 (exit 0)' (($r.Code -eq 0) -and (@(Get-ClickEvents) -join ' ') -match 'down flags=2 at 400,300') "exit=$($r.Code)"

Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '없는 창', '-Handle', '0x7FFFFFF0', '-WindowX', '10', '-WindowY', '10', '-NoAfterCapture', '-OutDir', $work)
Test-Case '거부: 존재하지 않는 창 (exit 2, 클릭 없음)' (($r.Code -eq 2) -and (@(Get-ClickEvents).Count -eq 0)) "exit=$($r.Code)"

# 캡처 후 창이 움직인 경우
Set-MockState -Window1 @{ left = 300; top = 200; right = 1100; bottom = 800 }
Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '이동한 창 클릭', '-WindowX', '300', '-WindowY', '200', '-NoAfterCapture', '-OutDir', $work)
Test-Case '거부: 캡처 후 창 이동 (exit 5, 클릭 없음)' (($r.Code -eq 5) -and (@(Get-ClickEvents).Count -eq 0)) "exit=$($r.Code)"

Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '이동한 창의 빈 지점 클릭', '-ScreenX', '600', '-ScreenY', '400', '-AllowWindowMoved', '-NoAfterCapture', '-OutDir', $work)
Test-Case '-AllowWindowMoved 로는 진행됨' (($r.Code -eq 0) -and (@(Get-ClickEvents) -join ' ') -match 'down flags=2 at 600,400') "exit=$($r.Code)"

# 최소화된 창
Set-MockState -Minimized
Clear-Events
$r = Invoke-Cli 'Capture-Screen.ps1' @('-Handle', '0x3E9', '-Name', 'min', '-OutDir', $work)
Test-Case '거부: 최소화된 창 캡처 (exit 3)' ($r.Code -eq 3) "exit=$($r.Code)"

# 활성화 실패 (관리자 권한 창 등)
Set-MockState -ActivateFails
Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '활성화 안 되는 창', '-WindowX', '300', '-WindowY', '200', '-NoAfterCapture', '-OutDir', $work)
Test-Case '거부: 창 활성화 실패 (exit 3, 클릭 없음)' (($r.Code -eq 3) -and (@(Get-ClickEvents).Count -eq 0)) "exit=$($r.Code)"

# 다른 창이 그 좌표를 가리고 있음
Set-MockState -Blocker @{ handle = 3003; left = 350; top = 250; right = 500; bottom = 400 }
Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '가려진 지점 클릭', '-WindowX', '300', '-WindowY', '200', '-NoAfterCapture', '-OutDir', $work)
Test-Case '거부: 다른 창이 그 지점을 가림 (exit 4, 클릭 없음)' (($r.Code -eq 4) -and (@(Get-ClickEvents).Count -eq 0)) "exit=$($r.Code)"

# 커서가 의도한 위치로 가지 않음
Set-MockState -CursorDrift 40
Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '커서 어긋남', '-WindowX', '300', '-WindowY', '200', '-NoAfterCapture', '-OutDir', $work)
$downs = @(@(Get-ClickEvents) | Where-Object { $_ -match '^down' })
Test-Case '거부: 커서 위치 검증 실패 (exit 8, 버튼 안 누름)' (($r.Code -eq 8) -and ($downs.Count -eq 0)) "exit=$($r.Code) down=$($downs.Count)"

# SendInput 자체가 막힘 (UIPI)
Set-MockState -SendInputFails
Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 't1.png'), '-Intent', '입력 차단 상황', '-WindowX', '300', '-WindowY', '200', '-NoAfterCapture', '-OutDir', $work)
Test-Case '입력이 차단되면 명확히 실패한다 (exit != 0)' (($r.Code -ne 0) -and ($r.Output -match '권한')) "exit=$($r.Code)"

# =====================================================================
# 8. 오래된 증거 / 전체화면 증거
# =====================================================================
Set-MockState
$r = Invoke-Cli 'Capture-Screen.ps1' @('-Handle', '0x3E9', '-Name', 'stale', '-OutDir', $work)
$stalePath = Join-Path $work 'stale.json'
$staleMeta = (Get-Content -LiteralPath $stalePath -Raw).TrimStart([char]0xFEFF) | ConvertFrom-Json
$staleMeta.timestampUtc = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
($staleMeta | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $stalePath -Encoding UTF8
Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 'stale.png'), '-Intent', '오래된 증거', '-WindowX', '300', '-WindowY', '200', '-NoAfterCapture', '-OutDir', $work)
Test-Case '거부: 오래된 캡처 (exit 5, 클릭 없음)' (($r.Code -eq 5) -and (@(Get-ClickEvents).Count -eq 0)) "exit=$($r.Code)"

$r = Invoke-Cli 'Capture-Screen.ps1' @('-Screen', '-Name', 'full', '-OutDir', $work)
$fullOk = ($r.Code -eq 0) -and (Test-Path (Join-Path $work 'full.png'))
$fullMeta = (Get-Content -LiteralPath (Join-Path $work 'full.json') -Raw).TrimStart([char]0xFEFF) | ConvertFrom-Json
Test-Case '전체 화면 캡처 동작 (라벨=화면 좌표)' ($fullOk -and ($fullMeta.labelSpace -eq 'screen') -and ($fullMeta.captureRect.width -eq 1920)) "exit=$($r.Code)"

Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 'full.png'), '-Intent', '전체화면 증거로 클릭', '-Handle', '0x3E9', '-ScreenX', '400', '-ScreenY', '300', '-NoAfterCapture', '-OutDir', $work)
Test-Case '거부: 전체화면 캡처를 증거로 쓸 수 없음 (exit 5)' (($r.Code -eq 5) -and (@(Get-ClickEvents).Count -eq 0)) "exit=$($r.Code)"

# =====================================================================
# 9. 모호한 창 지정
# =====================================================================
Set-MockState -SecondTitle '모의 메모장 - 다른 문서'
Clear-Events
$r = Invoke-Cli 'Capture-Screen.ps1' @('-TitleLike', '모의 메모장', '-Name', 'ambig', '-OutDir', $work)
Test-Case '거부: 창이 모호하면 고르지 않는다 (exit 2)' (($r.Code -eq 2) -and ($r.Output -match '모호')) "exit=$($r.Code)"

# =====================================================================
# 10. -WhatIf
# =====================================================================
Set-MockState
$r = Invoke-Cli 'Capture-Screen.ps1' @('-Handle', '0x3E9', '-Name', 'preview', '-OutDir', $work)
Clear-Events
$r = Invoke-Cli 'Invoke-Click.ps1' @('-Evidence', (Join-Path $work 'preview.png'), '-Intent', '조준만', '-WindowX', '300', '-WindowY', '200', '-WhatIf', '-OutDir', $work)
Test-Case '-WhatIf 는 조준 이미지만 만들고 클릭하지 않는다' (
    ($r.Code -eq 0) -and (Test-Path (Join-Path $work 'preview.target.png')) -and (@(Get-ClickEvents).Count -eq 0)
) "exit=$($r.Code)"

# =====================================================================
# 11. 감사 로그
# =====================================================================
$logPath = Join-Path $work 'screen-control.log.jsonl'
$logOk = $false
if (Test-Path -LiteralPath $logPath) {
    $lines = @(Get-Content -LiteralPath $logPath)
    $clickLines = @($lines | Where-Object { $_ -match '"action":"click"' })
    $logOk = ($clickLines.Count -ge 1) -and (($clickLines -join ' ') -match 'intent')
}
Test-Case '모든 클릭이 감사 로그에 남는다' $logOk $logPath

# =====================================================================
Write-Host ""
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) / $($script:Count) 개 실패" -ForegroundColor Red
    Write-Host "산출물: $work"
    exit 1
}
Write-Host "통합 테스트 $($script:Count) 개 전부 통과" -ForegroundColor Green
if (-not $KeepArtifacts) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
else { Write-Host "산출물: $work" }
