# 모든 CLI 스크립트가 공통으로 dot-source 하는 부트스트랩.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ScreenControl.psm1') -Force -DisableNameChecking

# 테스트 훅: SCREEN_CONTROL_MOCK 이 가리키는 스크립트를 모듈 내부 스코프에서 실행한다.
# Windows API 없이 전체 흐름(창 확정 -> 검증 -> 클릭 순서)을 검증할 때만 쓴다.
# 평상시에는 이 환경변수를 설정하지 않는다. 설정되면 경고가 찍히고 실제 클릭은 일어나지 않는다.
if ($env:SCREEN_CONTROL_MOCK -and (Test-Path -LiteralPath $env:SCREEN_CONTROL_MOCK)) {
    & (Get-Module ScreenControl) ([scriptblock]::Create((Get-Content -LiteralPath $env:SCREEN_CONTROL_MOCK -Raw)))
    Write-Warning 'ScreenControl: 모의(mock) 백엔드가 로드되었습니다 - 실제 클릭은 발생하지 않습니다.'
}

function Get-ScErrorExitCode {
    param([Parameter(Mandatory)]$ErrorRecord)
    $text = "$($ErrorRecord.Exception.Message)"
    $m = [regex]::Match($text, '\[exit=(\d+)\]')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 1
}

function Write-ScTable {
    <#
        표를 "리디렉션된 출력"에서도 보이게 찍는다.
        콘솔 폭을 알 수 없는 환경(파이프/자동화로 실행될 때)에서는 Format-Table 이
        아무것도 출력하지 않기 때문에, Out-String 으로 폭을 명시해 문자열로 만든다.
    #>
    param(
        [Parameter(ValueFromPipeline = $true)]$InputObject,
        [int]$Width = 200
    )
    begin { $rows = New-Object System.Collections.Generic.List[object] }
    process { if ($null -ne $InputObject) { [void]$rows.Add($InputObject) } }
    end {
        if ($rows.Count -eq 0) { return }
        $text = ($rows | Format-Table -AutoSize -Wrap | Out-String -Width $Width)
        Write-Host $text.TrimEnd()
    }
}

function Invoke-ScScript {
    <#
        본문을 실행하고, 실패 시 사람이 읽을 수 있는 오류 + 의미 있는 종료 코드로 끝낸다.
        "실패했는데 엉뚱한 곳을 클릭" 하는 상황을 만들지 않기 위해 예외는 절대 삼키지 않는다.
    #>
    # 주의: [Parameter()] 를 쓰면 advanced function 이 되어 호출자의 $PSCmdlet 을 가려버린다.
    # (그러면 스크립트의 ParameterSetName 이 __AllParameterSets 로 보인다)
    param([scriptblock]$Body)
    if (-not $Body) { throw 'Invoke-ScScript: -Body 가 필요합니다.' }
    try {
        & $Body
    }
    catch {
        $code = Get-ScErrorExitCode -ErrorRecord $_
        $msg = ($_.Exception.Message -replace '\s*\[exit=\d+\]\s*$', '')
        [Console]::Error.WriteLine("[screen-control] 실패(exit=$code): $msg")
        if ($_.ScriptStackTrace -and $env:SCREEN_CONTROL_DEBUG) {
            [Console]::Error.WriteLine($_.ScriptStackTrace)
        }
        exit $code
    }
}
