<#
.SYNOPSIS
    Windows 없이도 돌릴 수 있는 순수 로직 단위 테스트 (좌표 변환, 위험 키워드, 증거 검증).
.EXAMPLE
    .\Test-Logic.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\ScreenControl.psm1') -Force -DisableNameChecking

$fail = 0
function Check($name, $cond, $detail='') {
    if ($cond) { Write-Host "PASS $name $detail" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ }
}

# 1. 위험 키워드
Check '저장 감지'      (Get-ScDangerMatch -Intent '저장 버튼 클릭').IsDangerous
Check 'delete 감지'    (Get-ScDangerMatch -Intent 'click the Delete button').IsDangerous
Check 'OK 감지'        (Get-ScDangerMatch -Intent 'press OK').IsDangerous
Check 'clock 오탐 없음' (-not (Get-ScDangerMatch -Intent 'the clock widget').IsDangerous)
Check 'book 오탐 없음'  (-not (Get-ScDangerMatch -Intent 'open the bookmark pane').IsDangerous)
Check '평범한 의도'     (-not (Get-ScDangerMatch -Intent '도면 영역 빈 곳 클릭').IsDangerous)
Check '플롯 감지'       (Get-ScDangerMatch -Intent '플롯 대화상자 열기').IsDangerous

# 2. 사각형/좌표
$r = New-ScRect -Left 100 -Top 200 -Right 500 -Bottom 400
Check 'rect width'  ($r.Width -eq 400)
Check 'inside'      (Test-ScPointInRect -X 300 -Y 300 -Rect $r)
Check 'left edge'   (Test-ScPointInRect -X 100 -Y 200 -Rect $r)
Check 'right edge 제외' (-not (Test-ScPointInRect -X 500 -Y 300 -Rect $r))
Check 'outside'     (-not (Test-ScPointInRect -X 99 -Y 300 -Rect $r))

$vs = New-ScRect -Left 0 -Top 0 -Right 1920 -Bottom 1080
$a = ConvertTo-ScAbsoluteMousePoint -X 0 -Y 0 -VirtualScreen $vs
Check 'abs 원점'    ($a.Dx -eq 0 -and $a.Dy -eq 0) "($($a.Dx),$($a.Dy))"
$a = ConvertTo-ScAbsoluteMousePoint -X 1919 -Y 1079 -VirtualScreen $vs
Check 'abs 우하단'  ($a.Dx -eq 65535 -and $a.Dy -eq 65535) "($($a.Dx),$($a.Dy))"
$vs2 = New-ScRect -Left -1920 -Top 0 -Right 1920 -Bottom 1080
$a = ConvertTo-ScAbsoluteMousePoint -X -1920 -Y 0 -VirtualScreen $vs2
Check '멀티모니터 좌측' ($a.Dx -eq 0) "dx=$($a.Dx)"

# 3. 이미지<->화면 좌표 (축소 캡처 보정)
$meta = [pscustomobject]@{ scale = 0.5; origin = [pscustomobject]@{ x = 100; y = 50 }; imageWidth = 800; imageHeight = 400 }
$p = ConvertTo-ScScreenPointFromImage -ImageX 200 -ImageY 100 -Meta $meta
Check '이미지->화면' ($p.X -eq 500 -and $p.Y -eq 250) "($($p.X),$($p.Y))"
$ip = ConvertTo-ScImagePointFromScreen -ScreenX 500 -ScreenY 250 -Meta $meta
Check '화면->이미지 왕복' ($ip.X -eq 200 -and $ip.Y -eq 100) "($($ip.X),$($ip.Y))"

# 4. 증거 검증
$img = Join-Path ([System.IO.Path]::GetTempPath()) 'sc-evidence-test.png'
Set-Content -LiteralPath $img -Value 'x'
function New-FakeMeta($ageSec, $handle, $bounds) {
    [pscustomobject]@{
        imagePath = $img
        timestampUtc = (Get-Date).ToUniversalTime().AddSeconds(-$ageSec).ToString('o')
        window = [pscustomobject]@{ handle = $handle; bounds = $bounds }
    }
}
$bounds = [pscustomobject]@{ left = 10; top = 20; right = 810; bottom = 620 }
$win = [pscustomobject]@{ HandleValue = 1234; HandleHex = '0x4D2'; Bounds = (New-ScRect -Left 10 -Top 20 -Right 810 -Bottom 620) }

$ev = Test-ScEvidence -Meta (New-FakeMeta 5 1234 $bounds) -Window $win
Check '신선한 증거 통과' $ev.Ok ($ev.Reasons -join '; ')
$ev = Test-ScEvidence -Meta (New-FakeMeta 999 1234 $bounds) -Window $win
Check '오래된 증거 거부' (-not $ev.Ok) ($ev.Reasons -join '; ')
$ev = Test-ScEvidence -Meta (New-FakeMeta 5 9999 $bounds) -Window $win
Check '다른 창 증거 거부' (-not $ev.Ok)
$movedBounds = [pscustomobject]@{ left = 30; top = 20; right = 830; bottom = 620 }
$ev = Test-ScEvidence -Meta (New-FakeMeta 5 1234 $movedBounds) -Window $win
Check '창 이동 시 거부' (-not $ev.Ok)
$ev = Test-ScEvidence -Meta (New-FakeMeta 5 1234 $movedBounds) -Window $win -AllowWindowMoved
Check '창 이동 허용 옵션' $ev.Ok
$screenMeta = [pscustomobject]@{ imagePath = $img; timestampUtc = (Get-Date).ToUniversalTime().ToString('o'); window = $null }
$ev = Test-ScEvidence -Meta $screenMeta -Window $win
Check '전체화면 증거 거부' (-not $ev.Ok)
$ev = Test-ScEvidence -Meta ([pscustomobject]@{ imagePath = 'C:\nope\none.png'; timestampUtc = (Get-Date).ToUniversalTime().ToString('o'); window = $null })
Check '없는 이미지 거부' (-not $ev.Ok)

# 5. 종료 코드 / 출력 폴더
Check 'exit code map' ((Get-ScExitCode OutOfBounds) -eq 4 -and (Get-ScExitCode ApprovalRequired) -eq 6)
$out = Resolve-ScOutDir
Check '출력 폴더 생성' (Test-Path -LiteralPath $out) $out
Write-ScLog -Action 'unit-test' -Data @{ note = 'linux logic test' }
Check '감사 로그 기록' (Test-Path -LiteralPath (Join-Path $out 'screen-control.log.jsonl'))

# 6. 부트스트랩 오류코드 파서
. (Join-Path $PSScriptRoot '..\lib\Bootstrap.ps1')
try { throw "테스트 실패 메시지 [exit=6]" } catch { Check '오류 코드 추출' ((Get-ScErrorExitCode -ErrorRecord $_) -eq 6) }

# 7. 플랫폼 가드
if (Test-ScWindowsPlatform) {
    Check 'Windows 플랫폼 감지' $true
    Check '네이티브 초기화' ([bool](Initialize-ScNative))
}
else {
    Check '비 Windows 감지' (-not (Test-ScWindowsPlatform))
    $threw = $false; $msg = ''
    try { Initialize-ScNative } catch { $threw = $true; $msg = $_.Exception.Message }
    Check '비 Windows 에서 명확히 실패' $threw $msg
}

Remove-Item -LiteralPath $img -Force -ErrorAction SilentlyContinue
Write-Host ""
if ($fail -gt 0) { Write-Host "$fail 개 실패" -ForegroundColor Red; exit 1 } else { Write-Host "모든 로직 테스트 통과" -ForegroundColor Green }
