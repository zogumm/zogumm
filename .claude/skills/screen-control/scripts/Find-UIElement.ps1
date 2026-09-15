<#
.SYNOPSIS
    (선택) UI Automation 으로 대상 창 안의 클릭 가능한 요소와 그 좌표를 찾는다.

.DESCRIPTION
    눈으로 좌표를 추정하기 전에 이걸 먼저 시도하면 훨씬 정확하다.
    UI Automation 을 지원하지 않는 앱(AutoCAD 도면 영역, 게임, 일부 Qt 앱)에서는
    결과가 비어 있을 수 있고, 그때는 캡처 이미지 + 격자로 좌표를 판단한다.

.EXAMPLE
    .\Find-UIElement.ps1 -ProcessName notepad
    .\Find-UIElement.ps1 -Handle 0x1A2B3C -NameLike '확인' -Json
#>
[CmdletBinding()]
param(
    [string]$ProcessName,
    [string]$TitleLike,
    [int]$ProcessId = 0,
    [string]$Handle = '0',
    [string]$NameLike,
    [string[]]$ControlType,
    [switch]$IncludeAll,
    [int]$MaxResults = 200,
    [switch]$Json
)

. (Join-Path $PSScriptRoot '..\lib\Bootstrap.ps1')

Invoke-ScScript {
    Initialize-ScNative | Out-Null

    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    }
    catch {
        throw "UI Automation 어셈블리를 불러올 수 없습니다: $($_.Exception.Message). 이 기능 없이도 캡처+격자 좌표로 진행할 수 있습니다. [exit=$(Get-ScExitCode PlatformError)]"
    }

    $handleValue = 0L
    if ($Handle -and $Handle -ne '0') {
        $handleValue = if ($Handle -match '^0x') { [Convert]::ToInt64($Handle.Substring(2), 16) } else { [int64]$Handle }
    }
    $window = Resolve-ScTargetWindow -ProcessName $ProcessName -TitleLike $TitleLike -ProcessId $ProcessId -Handle $handleValue

    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$window.HandleValue)
    if ($null -eq $root) {
        throw "UI Automation 요소를 얻지 못했습니다: $($window.HandleHex) [exit=$(Get-ScExitCode WindowNotFound)]"
    }

    $defaultTypes = @('Button', 'MenuItem', 'TabItem', 'CheckBox', 'RadioButton', 'Edit', 'ComboBox',
                      'ListItem', 'TreeItem', 'Hyperlink', 'SplitButton', 'Text', 'Custom', 'Pane', 'Document')
    $wanted = if ($ControlType) { $ControlType } elseif ($IncludeAll) { $defaultTypes } else { @('Button', 'MenuItem', 'TabItem', 'CheckBox', 'RadioButton', 'Edit', 'ComboBox', 'ListItem', 'TreeItem', 'Hyperlink', 'SplitButton') }

    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::IsControlElementProperty, $true)
    $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($el in $found) {
        try {
            $cur = $el.Current
            if ($cur.IsOffscreen) { continue }
            $type = ($cur.ControlType.ProgrammaticName -replace '^ControlType\.', '')
            if ($wanted -notcontains $type) { continue }
            $r = $cur.BoundingRectangle
            if ($r.Width -le 0 -or $r.Height -le 0 -or [double]::IsInfinity($r.X)) { continue }
            $name = $cur.Name
            if ($NameLike) {
                $pattern = $NameLike
                if ($pattern -notmatch '[\*\?]') { $pattern = "*$pattern*" }
                if ($name -notlike $pattern) { continue }
            }
            $cx = [int][Math]::Round($r.X + ($r.Width / 2))
            $cy = [int][Math]::Round($r.Y + ($r.Height / 2))
            $danger = Get-ScDangerMatch -Intent $name
            [void]$rows.Add([pscustomobject]@{
                Name        = $name
                ControlType = $type
                AutomationId = $cur.AutomationId
                Enabled     = $cur.IsEnabled
                ScreenX     = $cx
                ScreenY     = $cy
                WindowX     = $cx - $window.Bounds.Left
                WindowY     = $cy - $window.Bounds.Top
                Width       = [int]$r.Width
                Height      = [int]$r.Height
                InsideWindow = (Test-ScPointInRect -X $cx -Y $cy -Rect $window.Bounds)
                LooksRisky  = $danger.IsDangerous
            })
            if ($rows.Count -ge $MaxResults) { break }
        }
        catch { continue }
    }

    if ($Json) {
        $rows | ConvertTo-Json -Depth 6
        return
    }

    if ($rows.Count -eq 0) {
        Write-Host "UI Automation 으로 찾은 요소가 없습니다. 캡처 이미지(.grid.png)를 보고 좌표를 정하세요." -ForegroundColor Yellow
        return
    }

    $rows | Select-Object @{n = 'Type'; e = { $_.ControlType } },
                          @{n = 'Name'; e = { if ($_.Name.Length -gt 34) { $_.Name.Substring(0, 31) + '...' } else { $_.Name } } },
                          @{n = 'WindowX'; e = { $_.WindowX } },
                          @{n = 'WindowY'; e = { $_.WindowY } },
                          @{n = 'Size'; e = { "$($_.Width)x$($_.Height)" } },
                          @{n = 'Risky'; e = { if ($_.LooksRisky) { '!' } else { '' } } } |
        Write-ScTable

    Write-Host "Risky(!) 로 표시된 요소는 클릭 전에 반드시 사용자 승인을 받으세요." -ForegroundColor Yellow
    Write-Host "좌표는 그대로 Invoke-Click.ps1 -WindowX <WindowX> -WindowY <WindowY> 에 사용할 수 있습니다 (창이 움직이지 않았다면)." -ForegroundColor DarkGray
}
