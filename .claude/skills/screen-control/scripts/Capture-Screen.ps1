<#
.SYNOPSIS
    대상 창(기본) 또는 전체 화면을 PNG 로 캡처한다. Claude 가 Read 도구로 바로 열어볼 수 있다.

.DESCRIPTION
    - 기본은 "창 한 개"만 캡처한다. 전체 화면은 -Screen 을 명시해야 한다.
    - 캡처와 함께 같은 이름의 .json(메타데이터)과 .grid.png(좌표 격자 사본)를 만든다.
    - .grid.png 의 숫자 라벨이 곧 Invoke-Click.ps1 의 -WindowX / -WindowY 값이다.

.EXAMPLE
    .\Capture-Screen.ps1 -ProcessName notepad
    .\Capture-Screen.ps1 -Handle 0x1A2B3C -Name before-click
    .\Capture-Screen.ps1 -Screen -Note '전체 화면 확인용'
#>
[CmdletBinding(DefaultParameterSetName = 'Window')]
param(
    [Parameter(ParameterSetName = 'Window')][string]$ProcessName,
    [Parameter(ParameterSetName = 'Window')][string]$TitleLike,
    [Parameter(ParameterSetName = 'Window')][int]$ProcessId = 0,
    [Parameter(ParameterSetName = 'Window')][string]$Handle = '0',
    [Parameter(ParameterSetName = 'Window')][switch]$NoActivate,
    [Parameter(ParameterSetName = 'Window')][switch]$Restore,
    [Parameter(ParameterSetName = 'Window')][ValidateSet('Auto', 'Screen', 'PrintWindow')][string]$Method = 'Auto',

    [Parameter(ParameterSetName = 'Screen', Mandatory = $true)][switch]$Screen,

    [string]$Name,
    [string]$OutDir,
    [switch]$NoGrid,
    [int]$GridStep = 100,
    [int]$MaxWidth = 1600,
    [int]$SettleMs = 350,
    [string]$Note = '',
    [switch]$Json
)

. (Join-Path $PSScriptRoot '..\lib\Bootstrap.ps1')

$captureSet = $PSCmdlet.ParameterSetName   # 스크립트블록 밖에서 확정 (래퍼의 $PSCmdlet 과 혼동 방지)

Invoke-ScScript {
    Initialize-ScNative | Out-Null

    $result = $null
    if ($captureSet -eq 'Screen') {
        $result = New-ScCapture -Mode Screen -OutDir $OutDir -Name $Name -NoGrid:$NoGrid -GridStep $GridStep `
            -MaxWidth $MaxWidth -SettleMs $SettleMs -Note $Note
    }
    else {
        $handleValue = 0L
        if ($Handle -and $Handle -ne '0') {
            $handleValue = if ($Handle -match '^0x') { [Convert]::ToInt64($Handle.Substring(2), 16) } else { [int64]$Handle }
        }
        $window = Resolve-ScTargetWindow -ProcessName $ProcessName -TitleLike $TitleLike -ProcessId $ProcessId -Handle $handleValue -AllowMinimized:$Restore
        $result = New-ScCapture -Mode Window -Window $window -Method $Method -OutDir $OutDir -Name $Name `
            -NoGrid:$NoGrid -GridStep $GridStep -MaxWidth $MaxWidth -NoActivate:$NoActivate -Restore:$Restore `
            -SettleMs $SettleMs -Note $Note
    }

    if ($Json) {
        $result.Meta | ConvertTo-Json -Depth 8
        return
    }

    $m = $result.Meta
    Write-Host ""
    Write-Host "캡처 완료 ($($m.mode) / $($m.method))" -ForegroundColor Green
    if ($m.window) {
        Write-Host ("  대상 창   : {0} [{1}] {2}" -f $m.window.handleHex, $m.window.processName, $m.window.title)
        Write-Host ("  창 위치   : {0},{1}  크기 {2}x{3}  DPI {4}" -f $m.window.bounds.left, $m.window.bounds.top, $m.window.bounds.width, $m.window.bounds.height, $m.window.dpi)
    }
    else {
        Write-Host ("  전체 화면 : {0},{1} {2}x{3}" -f $m.captureRect.left, $m.captureRect.top, $m.captureRect.width, $m.captureRect.height)
        Write-Host "  주의: 전체 화면 캡처는 클릭의 증거로 쓸 수 없습니다(창 캡처만 가능)." -ForegroundColor Yellow
    }
    Write-Host ("  이미지    : {0}  ({1}x{2}, scale {3})" -f $m.imagePath, $m.imageWidth, $m.imageHeight, [Math]::Round($m.scale, 4))
    if ($m.gridImagePath) {
        Write-Host ("  좌표 격자 : {0}" -f $m.gridImagePath)
    }
    Write-Host ("  메타데이터: {0}" -f $result.MetaPath)
    Write-Host ""
    Write-Host "다음 단계: Read 도구로 위 이미지(가능하면 .grid.png)를 직접 열어 좌표를 확인하세요." -ForegroundColor Cyan
    if ($m.labelSpace -eq 'window') {
        Write-Host "격자 라벨 = 창 기준 좌표 → Invoke-Click.ps1 -WindowX <라벨X> -WindowY <라벨Y> 로 그대로 사용합니다." -ForegroundColor Cyan
    }
    else {
        Write-Host "격자 라벨 = 화면 절대 좌표 → -ScreenX / -ScreenY 로 사용합니다." -ForegroundColor Cyan
    }
}
