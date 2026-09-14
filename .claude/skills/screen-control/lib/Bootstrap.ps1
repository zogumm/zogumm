# 모든 CLI 스크립트가 공통으로 dot-source 하는 부트스트랩.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ScreenControl.psm1') -Force -DisableNameChecking

function Get-ScErrorExitCode {
    param([Parameter(Mandatory)]$ErrorRecord)
    $text = "$($ErrorRecord.Exception.Message)"
    $m = [regex]::Match($text, '\[exit=(\d+)\]')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 1
}

function Invoke-ScScript {
    <#
        본문을 실행하고, 실패 시 사람이 읽을 수 있는 오류 + 의미 있는 종료 코드로 끝낸다.
        "실패했는데 엉뚱한 곳을 클릭" 하는 상황을 만들지 않기 위해 예외는 절대 삼키지 않는다.
    #>
    param([Parameter(Mandatory)][scriptblock]$Body)
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
