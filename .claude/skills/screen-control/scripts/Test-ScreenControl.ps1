<#
.SYNOPSIS
    "캡처 -> 좌표 판단 -> 클릭 -> 재캡처로 변화 확인" 전체 사이클과 안전장치를 자동 검증한다.

.DESCRIPTION
    기본적으로 메모장을 띄워 테스트하고 끝나면 닫는다. 다음을 확인한다.
      [양성] 창 캡처 / 격자 생성 / 실제 버튼 클릭 / 클릭 후 변화 감지 / -WhatIf 시 클릭 안 함
      [음성] 창 밖 좌표(4) / 증거 없음(5) / 위험 의도 무승인(6) / 없는 창(2) 은 반드시 거부

    이미 떠 있는 특정 창으로 테스트하려면 -Handle 또는 -ProcessName 을 주면 된다(이 경우 창을 닫지 않음).

.EXAMPLE
    .\Test-ScreenControl.ps1
    .\Test-ScreenControl.ps1 -ProcessName acad -KeepApp
#>
[CmdletBinding()]
param(
    [string]$LaunchApp = 'notepad.exe',
    [string]$ProcessName,
    [string]$TitleLike,
    [string]$Handle = '0',
    [switch]$KeepApp,
    [string]$OutDir,
    [double]$MinChangedPct = 0.1
)

. (Join-Path $PSScriptRoot '..\lib\Bootstrap.ps1')

$script:Results = New-Object System.Collections.Generic.List[object]
$script:Artifacts = New-Object System.Collections.Generic.List[string]

function Add-TestResult {
    param([string]$Step, [bool]$Ok, [string]$Detail)
    [void]$script:Results.Add([pscustomobject]@{ Step = $Step; Ok = $Ok; Detail = $Detail })
    $color = if ($Ok) { 'Green' } else { 'Red' }
    $mark = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1} - {2}" -f $mark, $Step, $Detail) -ForegroundColor $color
}

Invoke-ScScript {
    $hostExe = (Get-Process -Id $PID).Path
    $clickScript = Join-Path $PSScriptRoot 'Invoke-Click.ps1'
    $captureScript = Join-Path $PSScriptRoot 'Capture-Screen.ps1'

    function Invoke-ClickCli {
        param([string[]]$CliArgs)
        # 5.1 에서는 자식의 stderr 출력이 NativeCommandError 로 승격되므로 잠시 낮춘다.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $clickScript @CliArgs 2>&1
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $prevEap }
        return [pscustomobject]@{ Code = $code; Output = ($out | Out-String) }
    }

    # --- 0) 초기화 ---------------------------------------------------------
    $dpiMode = Initialize-ScNative
    $vs = Get-ScVirtualScreen
    Add-TestResult -Step '네이티브 초기화' -Ok $true -Detail ("DPI={0}, 가상화면=[{1},{2} {3}x{4}], INPUT={5}바이트" -f `
        $dpiMode, $vs.Left, $vs.Top, $vs.Width, $vs.Height, [ScreenControl.Native]::InputStructSize())

    $dir = Resolve-ScOutDir -OutDir $OutDir
    $testDir = Join-Path $dir ('selftest-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    Write-Host "테스트 산출물 폴더: $testDir" -ForegroundColor DarkGray

    # --- 1) 대상 창 확보 ---------------------------------------------------
    $launched = $null
    $handleValue = 0L
    if ($Handle -and $Handle -ne '0') {
        $handleValue = if ($Handle -match '^0x') { [Convert]::ToInt64($Handle.Substring(2), 16) } else { [int64]$Handle }
    }

    $window = $null
    if ($handleValue -ne 0 -or $ProcessName -or $TitleLike) {
        $window = Resolve-ScTargetWindow -ProcessName $ProcessName -TitleLike $TitleLike -Handle $handleValue
        Add-TestResult -Step '대상 창 확보(기존 창)' -Ok $true -Detail ("{0} [{1}] {2}" -f $window.HandleHex, $window.ProcessName, $window.Title)
    }
    else {
        $launched = Start-Process -FilePath $LaunchApp -PassThru
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
            $candidates = @(Get-ScWindow -ProcessId $launched.Id)
            if ($candidates.Count -eq 0) {
                # 일부 앱은 런처 프로세스가 따로 있다 (프로세스 이름으로 재시도)
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($LaunchApp)
                $candidates = @(Get-ScWindow -ProcessName $baseName)
            }
            $candidates = @($candidates | Where-Object { $_.Bounds.Width -gt 100 -and $_.Bounds.Height -gt 100 })
            if ($candidates.Count -ge 1) { $window = $candidates[0]; break }
        }
        if ($null -eq $window) {
            throw "테스트용 앱($LaunchApp)의 창을 찾지 못했습니다. [exit=$(Get-ScExitCode WindowNotFound)]"
        }
        Add-TestResult -Step '대상 창 확보(새로 실행)' -Ok $true -Detail ("{0} [{1}] {2}" -f $window.HandleHex, $window.ProcessName, $window.Title)
    }

    try {
        # --- 2) 캡처 #1 ----------------------------------------------------
        $cap1 = New-ScCapture -Mode Window -Window $window -OutDir $testDir -Name '01-before' -Note 'selftest before' -Restore
        [void]$script:Artifacts.Add($cap1.ImagePath)
        if ($cap1.GridImagePath) { [void]$script:Artifacts.Add($cap1.GridImagePath) }
        $capOk = (Test-Path -LiteralPath $cap1.ImagePath) -and ((Get-Item -LiteralPath $cap1.ImagePath).Length -gt 0) -and `
                 (Test-Path -LiteralPath $cap1.MetaPath) -and (Test-Path -LiteralPath $cap1.GridImagePath) -and `
                 ($cap1.Meta.window.handle -eq $window.HandleValue) -and `
                 ($cap1.Meta.captureRect.left -eq $window.Bounds.Left) -and ($cap1.Meta.captureRect.top -eq $window.Bounds.Top) -and `
                 ($cap1.Meta.imageWidth -gt 0) -and ($cap1.Meta.scale -gt 0)
        Add-TestResult -Step '창 캡처 + 격자 + 메타데이터' -Ok $capOk -Detail ("{0} ({1}x{2}), 메타 창핸들={3}, 영역={4},{5}" -f `
            $cap1.ImagePath, $cap1.Meta.imageWidth, $cap1.Meta.imageHeight, ('0x{0:X}' -f [int64]$cap1.Meta.window.handle), $cap1.Meta.captureRect.left, $cap1.Meta.captureRect.top)
        $window = $cap1.Window

        $cw = $window.ClientRect.Width
        $ch = $window.ClientRect.Height
        $centerClientX = [int]($cw / 2)
        $centerClientY = [int]($ch / 2)

        # --- 3) 음성 테스트: 창 밖 좌표 -------------------------------------
        $r = Invoke-ClickCli @('-Evidence', $cap1.ImagePath, '-Intent', '창 밖 좌표 테스트', '-WindowX', [string]($window.Bounds.Width + 500), '-WindowY', '10', '-NoAfterCapture', '-OutDir', $testDir)
        Add-TestResult -Step '거부: 창 밖 좌표' -Ok ($r.Code -eq (Get-ScExitCode OutOfBounds)) -Detail ("exit={0} (기대 {1})" -f $r.Code, (Get-ScExitCode OutOfBounds))

        # --- 4) 음성 테스트: 증거 캡처 없음 ---------------------------------
        $r = Invoke-ClickCli @('-Evidence', (Join-Path $testDir 'nope.png'), '-Intent', '증거 없는 클릭', '-WindowX', [string]$centerClientX, '-WindowY', [string]$centerClientY, '-Handle', $window.HandleHex, '-NoAfterCapture', '-OutDir', $testDir)
        Add-TestResult -Step '거부: 증거 캡처 없음' -Ok ($r.Code -eq (Get-ScExitCode EvidenceProblem)) -Detail ("exit={0} (기대 {1})" -f $r.Code, (Get-ScExitCode EvidenceProblem))

        # --- 5) 음성 테스트: 위험 의도인데 승인 없음 ------------------------
        $r = Invoke-ClickCli @('-Evidence', $cap1.ImagePath, '-Intent', '저장 버튼 클릭', '-ClientX', [string]$centerClientX, '-ClientY', [string]$centerClientY, '-NoAfterCapture', '-OutDir', $testDir)
        Add-TestResult -Step '거부: 위험 의도 무승인' -Ok ($r.Code -eq (Get-ScExitCode ApprovalRequired)) -Detail ("exit={0} (기대 {1})" -f $r.Code, (Get-ScExitCode ApprovalRequired))

        # --- 6) 음성 테스트: 존재하지 않는 창 -------------------------------
        $r = Invoke-ClickCli @('-Evidence', $cap1.ImagePath, '-Intent', '없는 창 클릭', '-Handle', '0x7FFFFFF0', '-ClientX', '10', '-ClientY', '10', '-NoAfterCapture', '-OutDir', $testDir)
        Add-TestResult -Step '거부: 없는 창' -Ok ($r.Code -eq (Get-ScExitCode WindowNotFound)) -Detail ("exit={0} (기대 {1})" -f $r.Code, (Get-ScExitCode WindowNotFound))

        # --- 7) -WhatIf 는 클릭하지 않는다 ----------------------------------
        $capW = New-ScCapture -Mode Window -Window $window -OutDir $testDir -Name '02-whatif-before' -Note 'whatif before'
        $r = Invoke-ClickCli @('-Evidence', $capW.ImagePath, '-Intent', '조준 위치 테스트', '-ClientX', [string]$centerClientX, '-ClientY', [string]$centerClientY, '-WhatIf', '-OutDir', $testDir)
        $previewPath = Join-Path $testDir ([System.IO.Path]::GetFileNameWithoutExtension($capW.ImagePath) + '.target.png')
        $capW2 = New-ScCapture -Mode Window -Window $window -OutDir $testDir -Name '03-whatif-after' -Note 'whatif after'
        $diffW = Compare-ScCapture -BeforePath $capW.ImagePath -AfterPath $capW2.ImagePath
        $whatIfOk = ($r.Code -eq 0) -and (Test-Path -LiteralPath $previewPath) -and (-not $diffW.SizeMismatch) -and ($diffW.ChangedPct -lt 1.0)
        if (Test-Path -LiteralPath $previewPath) { [void]$script:Artifacts.Add($previewPath) }
        Add-TestResult -Step '-WhatIf: 조준 이미지만 생성, 클릭 안 함' -Ok $whatIfOk -Detail ("exit={0}, 조준이미지={1}, 화면변화={2}%" -f $r.Code, (Test-Path -LiteralPath $previewPath), $diffW.ChangedPct)

        # --- 8) 실제 클릭 대상 고르기 ---------------------------------------
        $targetName = ''
        $targetClientX = $centerClientX
        $targetClientY = $centerClientY
        $useUia = $false
        try {
            $uiaJson = & (Join-Path $PSScriptRoot 'Find-UIElement.ps1') -Handle $window.HandleHex -Json 2>$null
            if ($uiaJson) {
                $elements = @($uiaJson | ConvertFrom-Json)
                $pick = $elements |
                    Where-Object { $_.Enabled -and -not $_.LooksRisky -and $_.InsideWindow -and $_.Width -ge 16 -and $_.Height -ge 12 -and $_.Name } |
                    Where-Object { $_.ControlType -in @('MenuItem', 'Button', 'TabItem', 'SplitButton') } |
                    Select-Object -First 1
                if ($pick) {
                    $useUia = $true
                    $targetName = "$($pick.ControlType) '$($pick.Name)'"
                    $targetClientX = $pick.ScreenX - $window.ClientRect.Left
                    $targetClientY = $pick.ScreenY - $window.ClientRect.Top
                }
            }
        }
        catch {
            Write-Host "UI Automation 탐색 실패(무시하고 좌표 기반으로 진행): $($_.Exception.Message)" -ForegroundColor DarkGray
        }
        if (-not $useUia) { $targetName = '클라이언트 영역 중앙' }
        Write-Host "클릭 대상: $targetName (client $targetClientX,$targetClientY)" -ForegroundColor DarkGray

        # --- 9) 진짜 클릭 + 변화 확인 ---------------------------------------
        $cap2 = New-ScCapture -Mode Window -Window $window -OutDir $testDir -Name '04-click-before' -Note 'click before'
        [void]$script:Artifacts.Add($cap2.ImagePath)
        $r = Invoke-ClickCli @('-Evidence', $cap2.ImagePath, '-Intent', "테스트 클릭: $targetName", '-ClientX', [string]$targetClientX, '-ClientY', [string]$targetClientY, '-NoAfterCapture', '-OutDir', $testDir)
        $clickOk = ($r.Code -eq 0)
        Add-TestResult -Step '실제 클릭 실행' -Ok $clickOk -Detail ("exit={0} {1}" -f $r.Code, ($r.Output -split "`n" | Where-Object { $_ -match '클릭 실행' } | Select-Object -First 1))

        if (-not $useUia -and $clickOk) {
            # 버튼이 없는 앱이면 클릭으로 포커스를 준 뒤 타이핑해서 변화를 만든다.
            try {
                $wshell = New-Object -ComObject WScript.Shell
                Start-Sleep -Milliseconds 200
                [void]$wshell.SendKeys('screen-control selftest')
                Start-Sleep -Milliseconds 400
            }
            catch {
                Write-Host "SendKeys 사용 불가(무시): $($_.Exception.Message)" -ForegroundColor DarkGray
            }
        }

        $cap3 = New-ScCapture -Mode Window -Window $window -OutDir $testDir -Name '05-click-after' -Note 'click after'
        [void]$script:Artifacts.Add($cap3.ImagePath)
        if ($cap3.GridImagePath) { [void]$script:Artifacts.Add($cap3.GridImagePath) }
        $diff = Compare-ScCapture -BeforePath $cap2.ImagePath -AfterPath $cap3.ImagePath
        $changeOk = $diff.SizeMismatch -or ($diff.ChangedPct -ge $MinChangedPct)
        $boxText = if ($diff.ChangedBox) { "[$($diff.ChangedBox.Left),$($diff.ChangedBox.Top)-$($diff.ChangedBox.Right),$($diff.ChangedBox.Bottom)]" } else { '(없음)' }
        Add-TestResult -Step '클릭 후 화면 변화 감지' -Ok $changeOk -Detail ("{0}% 변경, 영역 {1} (기준 {2}%)" -f $diff.ChangedPct, $boxText, $MinChangedPct)

        # 열린 메뉴가 있으면 닫는다.
        try {
            [void][ScreenControl.Native]::Activate([IntPtr]$window.HandleValue, 1500)
            $wshell2 = New-Object -ComObject WScript.Shell
            [void]$wshell2.SendKeys('{ESC}')
            Start-Sleep -Milliseconds 200
        }
        catch { }
    }
    finally {
        if ($launched -and -not $KeepApp) {
            try {
                Stop-Process -Id $launched.Id -Force -ErrorAction Stop
                Write-Host "테스트용 앱을 닫았습니다 (PID $($launched.Id))." -ForegroundColor DarkGray
            }
            catch {
                Write-Host "테스트용 앱 종료 실패: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    # --- 결과 요약 ---------------------------------------------------------
    Write-Host ""
    Write-Host "================= 결과 요약 =================" -ForegroundColor Cyan
    $script:Results | Select-Object @{n = '결과'; e = { if ($_.Ok) { 'PASS' } else { 'FAIL' } } }, Step, Detail |
        Write-ScTable
    $failed = @($script:Results | Where-Object { -not $_.Ok })
    Write-Host ""
    Write-Host "확인용 이미지 (Read 도구로 열어보세요):" -ForegroundColor Cyan
    $script:Artifacts | ForEach-Object { Write-Host "  $_" }
    Write-Host ""

    if ($failed.Count -gt 0) {
        Write-Host "$($failed.Count) 개 항목 실패." -ForegroundColor Red
        exit 1
    }
    Write-Host "전체 $($script:Results.Count) 개 항목 통과." -ForegroundColor Green
}
