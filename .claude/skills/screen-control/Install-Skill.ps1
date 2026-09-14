<#
.SYNOPSIS
    이 폴더를 Claude Code 스킬 위치(~\.claude\skills\screen-control)에 설치한다.
.EXAMPLE
    .\Install-Skill.ps1
    .\Install-Skill.ps1 -Destination 'D:\ai\.claude\skills\screen-control'
#>
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $env:USERPROFILE '.claude\skills\screen-control'),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = $PSScriptRoot
if ((Test-Path -LiteralPath $Destination) -and -not $Force) {
    $existing = @(Get-ChildItem -LiteralPath $Destination -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        Write-Host "이미 존재합니다: $Destination" -ForegroundColor Yellow
        Write-Host "덮어쓰려면 -Force 를 붙여 다시 실행하세요." -ForegroundColor Yellow
        exit 1
    }
}

New-Item -ItemType Directory -Path $Destination -Force | Out-Null
foreach ($item in @('SKILL.md', 'README.md', 'Install-Skill.ps1', 'lib', 'scripts')) {
    $src = Join-Path $source $item
    if (-not (Test-Path -LiteralPath $src)) { continue }
    Copy-Item -LiteralPath $src -Destination $Destination -Recurse -Force
}

Write-Host "설치 완료: $Destination" -ForegroundColor Green
Write-Host ""
Write-Host "다음 명령으로 동작을 검증하세요 (메모장이 잠깐 떴다 닫힙니다):" -ForegroundColor Cyan
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$Destination\scripts\Test-ScreenControl.ps1`"" -ForegroundColor Cyan
