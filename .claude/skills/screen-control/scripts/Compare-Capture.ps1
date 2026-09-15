<#
.SYNOPSIS
    두 캡처 PNG 를 비교해 얼마나 바뀌었는지 알려준다 (클릭 결과 확인용).
.EXAMPLE
    .\Compare-Capture.ps1 -Before before.png -After after.png
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Before,
    [Parameter(Mandatory = $true)][string]$After,
    [int]$Tolerance = 12,
    [double]$MinChangedPct = 0.0,
    [switch]$Json
)

. (Join-Path $PSScriptRoot '..\lib\Bootstrap.ps1')

Invoke-ScScript {
    $diff = Compare-ScCapture -BeforePath $Before -AfterPath $After -Tolerance $Tolerance

    if ($Json) {
        $diff | ConvertTo-Json -Depth 6
    }
    else {
        if ($diff.SizeMismatch) {
            Write-Host "두 이미지의 크기가 다릅니다 → 창 크기/상태가 바뀐 것으로 간주합니다." -ForegroundColor Yellow
        }
        else {
            Write-Host ("변경 픽셀 {0} / {1} ({2}%)" -f $diff.ChangedPixels, $diff.TotalPixels, $diff.ChangedPct) -ForegroundColor Green
            if ($diff.ChangedBox) {
                Write-Host ("변경 영역(이미지 좌표): {0},{1} - {2},{3}" -f $diff.ChangedBox.Left, $diff.ChangedBox.Top, $diff.ChangedBox.Right, $diff.ChangedBox.Bottom)
            }
        }
    }

    if ($MinChangedPct -gt 0 -and -not $diff.SizeMismatch -and $diff.ChangedPct -lt $MinChangedPct) {
        throw "기대한 변화가 없습니다: $($diff.ChangedPct)% < $MinChangedPct% [exit=$(Get-ScExitCode GeneralError)]"
    }
}
