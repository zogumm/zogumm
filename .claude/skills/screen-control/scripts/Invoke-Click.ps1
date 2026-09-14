<#
.SYNOPSIS
    검증을 통과한 경우에만 대상 창의 좌표를 클릭한다. (본 것만 클릭한다)

.DESCRIPTION
    반드시 -Evidence 로 "방금 캡처한 이미지"를 지정해야 한다. 다음 중 하나라도 어긋나면
    클릭하지 않고 0 이 아닌 종료 코드로 끝난다.
        2 창 없음/모호   3 활성화 실패        4 좌표가 창/화면 밖 or 다른 창이 가림
        5 증거 없음/오래됨/창 이동  6 사용자 승인 필요   8 커서 이동 검증 실패

    좌표 지정 방법 (하나만 선택)
        -WindowX/-WindowY : 창 캡처 .grid.png 의 라벨 좌표 (권장)
        -ClientX/-ClientY : 창 클라이언트 영역 기준
        -ScreenX/-ScreenY : 화면 절대 좌표
        -ImageX/-ImageY   : 증거 이미지의 픽셀 좌표(축소 캡처면 자동 보정)

.EXAMPLE
    # 1) 먼저 보고
    .\Capture-Screen.ps1 -ProcessName notepad -Name step1
    # 2) 어디를 누를지 미리 확인 (실제로 누르지 않음, .target.png 생성)
    .\Invoke-Click.ps1 -Evidence ...\step1.png -WindowX 420 -WindowY 160 -Intent '글꼴 크기 입력칸' -WhatIf
    # 3) 진짜 클릭
    .\Invoke-Click.ps1 -Evidence ...\step1.png -WindowX 420 -WindowY 160 -Intent '글꼴 크기 입력칸'
#>
[CmdletBinding(DefaultParameterSetName = 'Window', SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$Evidence,
    [Parameter(Mandatory = $true)][string]$Intent,

    [Parameter(ParameterSetName = 'Window', Mandatory = $true)][int]$WindowX,
    [Parameter(ParameterSetName = 'Window', Mandatory = $true)][int]$WindowY,
    [Parameter(ParameterSetName = 'Client', Mandatory = $true)][int]$ClientX,
    [Parameter(ParameterSetName = 'Client', Mandatory = $true)][int]$ClientY,
    [Parameter(ParameterSetName = 'Screen', Mandatory = $true)][int]$ScreenX,
    [Parameter(ParameterSetName = 'Screen', Mandatory = $true)][int]$ScreenY,
    [Parameter(ParameterSetName = 'Image', Mandatory = $true)][int]$ImageX,
    [Parameter(ParameterSetName = 'Image', Mandatory = $true)][int]$ImageY,

    [string]$ProcessName,
    [string]$TitleLike,
    [int]$ProcessId = 0,
    [string]$Handle = '0',

    [ValidateSet('Left', 'Right', 'Middle')][string]$Button = 'Left',
    [switch]$Double,
    [int]$MoveDelayMs = 250,
    [int]$PressDelayMs = 60,
    [int]$SettleMs = 400,
    [int]$EvidenceMaxAgeSeconds = 180,
    [switch]$AllowOutsideWindow,
    [switch]$AllowWindowMoved,
    [switch]$UserApproved,
    [ValidateSet('Auto', 'Normal', 'High')][string]$Risk = 'Auto',
    [switch]$RestoreCursor,
    [switch]$UseAbsoluteMove,
    [switch]$NoAfterCapture,
    [string]$OutDir,
    [switch]$Json
)

. (Join-Path $PSScriptRoot '..\lib\Bootstrap.ps1')

# 스크립트 스코프에서 확정해 둔다. 스크립트블록 안에서 $PSCmdlet 을 참조하면
# 래퍼 함수의 것이 잡힐 수 있어 좌표 변환이 통째로 건너뛰어진다.
$coordinateSet = $PSCmdlet.ParameterSetName
$whatIfRequested = [bool]$WhatIfPreference

Invoke-ScScript {
    Initialize-ScNative | Out-Null

    $meta = Import-ScCaptureMeta -Path $Evidence

    # --- 대상 창 확정: 명시가 없으면 증거 캡처에 기록된 창을 쓴다 ---------
    $handleValue = 0L
    if ($Handle -and $Handle -ne '0') {
        $handleValue = if ($Handle -match '^0x') { [Convert]::ToInt64($Handle.Substring(2), 16) } else { [int64]$Handle }
    }
    if ($handleValue -eq 0 -and -not $ProcessName -and -not $TitleLike -and $ProcessId -eq 0) {
        $metaWindow = Get-ScProp $meta 'window'
        if ($null -eq $metaWindow) {
            throw "증거 캡처가 전체 화면 캡처입니다. 클릭 대상 창을 -Handle/-ProcessName/-TitleLike 로 지정하거나, 창 캡처를 사용하세요. [exit=$(Get-ScExitCode InvalidArguments)]"
        }
        $handleValue = [int64](Get-ScProp $metaWindow 'handle')
    }

    $window = Resolve-ScTargetWindow -ProcessName $ProcessName -TitleLike $TitleLike -ProcessId $ProcessId -Handle $handleValue

    # --- 좌표 변환 --------------------------------------------------------
    $targetX = 0
    $targetY = 0
    switch ($coordinateSet) {
        'Window' {
            if ((Get-ScProp $meta 'labelSpace') -ne 'window') {
                throw "이 캡처는 창 기준 좌표계가 아닙니다(labelSpace=$(Get-ScProp $meta 'labelSpace')). -ScreenX/-ScreenY 를 사용하세요. [exit=$(Get-ScExitCode InvalidArguments)]"
            }
            $lo = Get-ScProp $meta 'labelOrigin'
            $or = Get-ScProp $meta 'origin'
            $targetX = $or.x + ($WindowX - $lo.x)
            $targetY = $or.y + ($WindowY - $lo.y)
        }
        'Client' {
            $targetX = $window.ClientRect.Left + $ClientX
            $targetY = $window.ClientRect.Top + $ClientY
        }
        'Screen' {
            $targetX = $ScreenX
            $targetY = $ScreenY
        }
        'Image' {
            $p = ConvertTo-ScScreenPointFromImage -ImageX $ImageX -ImageY $ImageY -Meta $meta
            $targetX = $p.X
            $targetY = $p.Y
        }
        default {
            throw "좌표를 지정해야 합니다: -WindowX/-WindowY, -ClientX/-ClientY, -ScreenX/-ScreenY, -ImageX/-ImageY 중 하나 (받은 세트: '$coordinateSet'). [exit=$(Get-ScExitCode InvalidArguments)]"
        }
    }

    $result = Invoke-ScClick -Window $window -ScreenX $targetX -ScreenY $targetY -Intent $Intent `
        -EvidenceMeta $meta -EvidenceMaxAgeSeconds $EvidenceMaxAgeSeconds -AllowWindowMoved:$AllowWindowMoved `
        -Button $Button -DoubleClick:$Double -MoveDelayMs $MoveDelayMs -PressDelayMs $PressDelayMs -SettleMs $SettleMs `
        -AllowOutsideWindow:$AllowOutsideWindow -UserApproved:$UserApproved -Risk $Risk `
        -RestoreCursor:$RestoreCursor -UseAbsoluteMove:$UseAbsoluteMove -OutDir $OutDir `
        -WhatIf:$whatIfRequested

    $after = $null
    $diff = $null
    if ($result.Performed -and -not $NoAfterCapture) {
        $after = New-ScCapture -Mode Window -Window $result.Window -OutDir $OutDir `
            -Name ('after-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff')) -Note "click 후 확인: $Intent" -SettleMs 250
        try {
            $diff = Compare-ScCapture -BeforePath (Get-ScProp $meta 'imagePath') -AfterPath $after.ImagePath
        }
        catch {
            Write-Warning "클릭 전후 비교 실패: $($_.Exception.Message)"
        }
    }

    if ($Json) {
        [pscustomobject]@{
            performed   = $result.Performed
            whatIf      = $result.WhatIf
            screenX     = $result.ScreenX
            screenY     = $result.ScreenY
            intent      = $Intent
            riskHigh    = $result.RiskHigh
            previewPath = $result.PreviewPath
            afterImage  = if ($after) { $after.ImagePath } else { $null }
            afterGrid   = if ($after) { $after.GridImagePath } else { $null }
            changedPct  = if ($diff) { $diff.ChangedPct } else { $null }
            changedBox  = if ($diff) { $diff.ChangedBox } else { $null }
        } | ConvertTo-Json -Depth 6
        return
    }

    Write-Host ""
    if ($result.Performed) {
        Write-Host ("클릭 실행: {0} ({1},{2}) :: {3}" -f $Button, $result.ScreenX, $result.ScreenY, $Intent) -ForegroundColor Green
    }
    else {
        Write-Host ("[-WhatIf] 클릭하지 않았습니다. 예정 좌표: {0} ({1},{2}) :: {3}" -f $Button, $result.ScreenX, $result.ScreenY, $Intent) -ForegroundColor Yellow
    }
    Write-Host ("  대상 창 : {0} [{1}] {2}" -f $result.Window.HandleHex, $result.Window.ProcessName, $result.Window.Title)
    if ($result.PreviewPath) {
        Write-Host ("  조준 이미지 : {0}   <- Read 도구로 열어 클릭 지점을 눈으로 확인" -f $result.PreviewPath) -ForegroundColor Cyan
    }
    if ($after) {
        Write-Host ("  클릭 후 캡처: {0}" -f $after.ImagePath) -ForegroundColor Cyan
        if ($after.GridImagePath) { Write-Host ("  클릭 후 격자: {0}" -f $after.GridImagePath) -ForegroundColor Cyan }
    }
    if ($diff) {
        if ($diff.SizeMismatch) {
            Write-Host "  변화 확인 : 창 크기가 바뀌어 픽셀 비교 불가(변화 있음)" -ForegroundColor Cyan
        }
        else {
            $box = if ($diff.ChangedBox) { "[$($diff.ChangedBox.Left),$($diff.ChangedBox.Top) - $($diff.ChangedBox.Right),$($diff.ChangedBox.Bottom)]" } else { '(없음)' }
            Write-Host ("  변화 확인 : {0}% 픽셀 변경, 변경 영역 {1}" -f $diff.ChangedPct, $box) -ForegroundColor Cyan
            if ($diff.ChangedPixels -eq 0) {
                Write-Host "  경고: 화면이 전혀 바뀌지 않았습니다. 좌표가 빈 곳이었을 수 있습니다." -ForegroundColor Yellow
            }
        }
    }
}
