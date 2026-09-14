# screen-control

Windows 화면을 **캡처해서 보고 → 좌표를 판단해 → 마우스로 클릭**하는 Claude Code 스킬.
PowerShell + `Add-Type`(Win32 API / System.Drawing) 만 쓰므로 **추가 설치나 MCP 서버가 필요 없다.**

사용 규칙과 루프 설명은 [`SKILL.md`](SKILL.md) 에 있다. 이 문서는 설치와 검증 방법만 다룬다.

## 설치 (Windows PC)

### 방법 A — 이 브랜치를 zip 으로 받아서 설치

```powershell
$zip = "$env:TEMP\screen-control.zip"
Invoke-WebRequest -Uri 'https://github.com/zogumm/zogumm/archive/refs/heads/claude/windows-screen-capture-click-6m6ahx.zip' -OutFile $zip
Expand-Archive -Path $zip -DestinationPath "$env:TEMP\sc-extract" -Force
$src = Get-ChildItem "$env:TEMP\sc-extract" -Recurse -Directory -Filter 'screen-control' | Select-Object -First 1
& "$($src.FullName)\Install-Skill.ps1" -Force
```

### 방법 B — git 으로 받아서 설치

```powershell
cd D:\ai
git clone https://github.com/zogumm/zogumm.git zogumm-skills
cd zogumm-skills
git checkout claude/windows-screen-capture-click-6m6ahx
.\.claude\skills\screen-control\Install-Skill.ps1 -Force
```

설치 위치: `%USERPROFILE%\.claude\skills\screen-control`
(다른 곳에 두려면 `-Destination` 사용. 특정 프로젝트 전용으로 쓰려면 그 프로젝트의
`.claude\skills\screen-control` 로 복사해도 된다.)

## 동작 검증

```powershell
# 1) 순수 로직 테스트 (창을 띄우지 않음, 몇 초)
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\screen-control\scripts\Test-Logic.ps1"

# 2) 전체 사이클 테스트 (메모장이 잠깐 떴다가 닫힘)
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\screen-control\scripts\Test-ScreenControl.ps1"
```

2번이 확인하는 것:

| 구분 | 항목 |
|---|---|
| 양성 | 창 캡처 + 좌표격자 + 메타데이터 생성 / 실제 버튼 클릭 / 클릭 후 화면 변화 감지 / `-WhatIf` 는 클릭하지 않고 조준 이미지만 생성 |
| 음성(반드시 거부) | 창 밖 좌표(exit 4) / 증거 캡처 없음(exit 5) / 위험 의도 무승인(exit 6) / 존재하지 않는 창(exit 2) |

테스트가 만든 이미지는 `D:\ai\.screen-control\selftest-<시각>\` 에 남는다
(D 드라이브가 없으면 `%LOCALAPPDATA%\screen-control\`). Read 도구로 열어서 눈으로 확인하면 된다.

## 지금까지 어디까지 검증했나

이 코드는 리눅스 컨테이너에서 작성되었기 때문에 **Windows 실기 검증은 위 2번 명령으로
사용자 PC에서 해야 한다.** 작성 환경에서 끝낸 검증은 다음과 같다.

- PowerShell 7.4 파서로 전 파일 구문 검사 통과
- 임베디드 C#(Win32 P/Invoke, INPUT 구조체, 이미지 diff) 컴파일 통과,
  `INPUT` 구조체 크기 40바이트(x64 실제 값과 일치) 확인
- `Test-Logic.ps1` 30개 항목 통과 — 좌표 변환(축소 캡처 보정, 멀티모니터 정규화),
  위험 키워드 탐지(`clock` 같은 오탐 방지 포함), 증거 검증(오래됨/다른 창/창 이동/전체화면 거부),
  종료 코드 매핑, 감사 로그 기록

검증하지 못한 부분은 실제 Windows GDI 캡처와 `SendInput` 마우스 입력 경로다. 2번 테스트가 그 부분을 덮는다.

## 폴더 구조

```
screen-control/
  SKILL.md              사용 규칙 (Claude 가 읽는 문서)
  README.md             설치/검증 (이 문서)
  Install-Skill.ps1     ~/.claude/skills 로 설치
  lib/
    ScreenControl.psm1  코어 (Win32 P/Invoke, 캡처, 클릭, 검증, 로깅)
    Bootstrap.ps1       스크립트 공통 오류/종료코드 처리
  scripts/
    Get-Window.ps1        창 목록/핸들
    Capture-Screen.ps1    캡처 (+ 좌표격자 + 메타데이터)
    Invoke-Click.ps1      검증 후 클릭 (-WhatIf 지원)
    Convert-Point.ps1     좌표계 변환
    Compare-Capture.ps1   전후 변화량 비교
    Find-UIElement.ps1    (선택) UI Automation 좌표 탐색
    Test-ScreenControl.ps1  전체 사이클 자동 검증
    Test-Logic.ps1          순수 로직 단위 테스트
```
