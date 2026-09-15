<#
.SYNOPSIS
    창 좌표 <-> 화면 좌표 <-> 이미지 좌표 변환 헬퍼. 어떤 좌표계인지 헷갈릴 때 먼저 확인한다.
.EXAMPLE
    .\Convert-Point.ps1 -Handle 0x1A2B3C -WindowX 200 -WindowY 120
    .\Convert-Point.ps1 -Evidence D:\ai\.screen-control\step1.png -ImageX 640 -ImageY 300
#>
[CmdletBinding(DefaultParameterSetName = 'Window')]
param(
    [Parameter(ParameterSetName = 'Window', Mandatory = $true)][int]$WindowX,
    [Parameter(ParameterSetName = 'Window', Mandatory = $true)][int]$WindowY,
    [Parameter(ParameterSetName = 'Client', Mandatory = $true)][int]$ClientX,
    [Parameter(ParameterSetName = 'Client', Mandatory = $true)][int]$ClientY,
    [Parameter(ParameterSetName = 'Screen', Mandatory = $true)][int]$ScreenX,
    [Parameter(ParameterSetName = 'Screen', Mandatory = $true)][int]$ScreenY,
    [Parameter(ParameterSetName = 'Image', Mandatory = $true)][int]$ImageX,
    [Parameter(ParameterSetName = 'Image', Mandatory = $true)][int]$ImageY,

    [string]$Evidence,
    [string]$ProcessName,
    [string]$TitleLike,
    [int]$ProcessId = 0,
    [string]$Handle = '0',
    [switch]$Json
)

. (Join-Path $PSScriptRoot '..\lib\Bootstrap.ps1')

$pointSet = $PSCmdlet.ParameterSetName   # 스크립트블록 밖에서 확정 (래퍼의 $PSCmdlet 과 혼동 방지)

Invoke-ScScript {
    Initialize-ScNative | Out-Null

    $meta = $null
    if ($Evidence) { $meta = Import-ScCaptureMeta -Path $Evidence }

    $handleValue = 0L
    if ($Handle -and $Handle -ne '0') {
        $handleValue = if ($Handle -match '^0x') { [Convert]::ToInt64($Handle.Substring(2), 16) } else { [int64]$Handle }
    }
    if ($handleValue -eq 0 -and -not $ProcessName -and -not $TitleLike -and $ProcessId -eq 0 -and $meta -and (Get-ScProp $meta 'window')) {
        $handleValue = [int64](Get-ScProp (Get-ScProp $meta 'window') 'handle')
    }

    $window = Resolve-ScTargetWindow -ProcessName $ProcessName -TitleLike $TitleLike -ProcessId $ProcessId -Handle $handleValue

    $sx = 0; $sy = 0
    switch ($pointSet) {
        'Window' { $sx = $window.Bounds.Left + $WindowX; $sy = $window.Bounds.Top + $WindowY }
        'Client' { $sx = $window.ClientRect.Left + $ClientX; $sy = $window.ClientRect.Top + $ClientY }
        'Screen' { $sx = $ScreenX; $sy = $ScreenY }
        'Image' {
            if (-not $meta) { throw "-ImageX/-ImageY 에는 -Evidence 가 필요합니다. [exit=$(Get-ScExitCode InvalidArguments)]" }
            $p = ConvertTo-ScScreenPointFromImage -ImageX $ImageX -ImageY $ImageY -Meta $meta
            $sx = $p.X; $sy = $p.Y
        }
        default {
            throw "좌표를 지정해야 합니다 (받은 세트: '$pointSet'). [exit=$(Get-ScExitCode InvalidArguments)]"
        }
    }

    $vs = Get-ScVirtualScreen
    $out = [ordered]@{
        screen      = @{ x = $sx; y = $sy }
        window      = @{ x = $sx - $window.Bounds.Left; y = $sy - $window.Bounds.Top }
        client      = @{ x = $sx - $window.ClientRect.Left; y = $sy - $window.ClientRect.Top }
        image       = $null
        insideWindow = (Test-ScPointInRect -X $sx -Y $sy -Rect $window.Bounds)
        insideScreen = (Test-ScPointInRect -X $sx -Y $sy -Rect $vs)
        windowHandle = $window.HandleHex
        windowTitle  = $window.Title
        windowBounds = @{ left = $window.Bounds.Left; top = $window.Bounds.Top; width = $window.Bounds.Width; height = $window.Bounds.Height }
    }
    if ($meta) {
        $ip = ConvertTo-ScImagePointFromScreen -ScreenX $sx -ScreenY $sy -Meta $meta
        $out.image = @{ x = $ip.X; y = $ip.Y }
    }

    if ($Json) {
        [pscustomobject]$out | ConvertTo-Json -Depth 6
        return
    }

    Write-Host ("대상 창   : {0} '{1}'  [{2},{3} {4}x{5}]" -f $window.HandleHex, $window.Title, $window.Bounds.Left, $window.Bounds.Top, $window.Bounds.Width, $window.Bounds.Height)
    Write-Host ("화면 좌표 : {0},{1}   (-ScreenX/-ScreenY)" -f $out.screen.x, $out.screen.y)
    Write-Host ("창 좌표   : {0},{1}   (-WindowX/-WindowY, 격자 라벨과 동일)" -f $out.window.x, $out.window.y)
    Write-Host ("클라이언트: {0},{1}   (-ClientX/-ClientY)" -f $out.client.x, $out.client.y)
    if ($out.image) { Write-Host ("이미지    : {0},{1}   (-ImageX/-ImageY)" -f $out.image.x, $out.image.y) }
    Write-Host ("창 안쪽?  : {0} / 화면 안쪽? {1}" -f $out.insideWindow, $out.insideScreen) -ForegroundColor $(if ($out.insideWindow) { "Green" } else { "Yellow" })
}
