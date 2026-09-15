<#
.SYNOPSIS
    클릭/캡처 대상으로 쓸 수 있는 창 목록을 보여준다.
.EXAMPLE
    .\Get-Window.ps1
    .\Get-Window.ps1 -ProcessName acad
    .\Get-Window.ps1 -TitleLike '메모장' -Json
#>
[CmdletBinding()]
param(
    [string]$ProcessName,
    [string]$TitleLike,
    [int]$ProcessId = 0,
    [int64]$Handle = 0,
    [switch]$IncludeInvisible,
    [switch]$Json
)

. (Join-Path $PSScriptRoot '..\lib\Bootstrap.ps1')

Invoke-ScScript {
    $windows = @(Get-ScWindow -ProcessName $ProcessName -TitleLike $TitleLike -ProcessId $ProcessId -Handle $Handle -IncludeInvisible:$IncludeInvisible)

    if ($Json) {
        $windows | Select-Object HandleValue, HandleHex, ProcessId, ProcessName, Title, ClassName, Visible, Minimized, Maximized, Foreground, Dpi, Bounds |
            ConvertTo-Json -Depth 6
        return
    }

    if ($windows.Count -eq 0) {
        Write-Host "조건에 맞는 창이 없습니다." -ForegroundColor Yellow
        return
    }

    $windows |
        Select-Object @{n = 'Handle'; e = { $_.HandleHex } },
                      @{n = 'PID'; e = { $_.ProcessId } },
                      ProcessName,
                      @{n = 'Pos'; e = { "$($_.Bounds.Left),$($_.Bounds.Top)" } },
                      @{n = 'Size'; e = { "$($_.Bounds.Width)x$($_.Bounds.Height)" } },
                      @{n = 'DPI'; e = { $_.Dpi } },
                      @{n = 'FG'; e = { if ($_.Foreground) { '*' } else { '' } } },
                      @{n = 'Title'; e = { if ($_.Title.Length -gt 60) { $_.Title.Substring(0, 57) + '...' } else { $_.Title } } } |
        Write-ScTable

    Write-Host "총 $($windows.Count) 개. 이후 명령에는 -Handle <핸들> 로 고정해서 쓰는 것이 가장 안전합니다." -ForegroundColor DarkGray
}
