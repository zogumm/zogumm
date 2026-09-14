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
$SC = "$env:USERPROFILE\.claude\skills\screen-control"

# 1) 순수 로직 테스트 (창을 띄우지 않음, 몇 초)
powershell -ExecutionPolicy Bypass -File "$SC\scripts\Test-Logic.ps1"

# 2) 통합 테스트 — 모의 Win32 백엔드 위에서 전체 흐름 검증 (실제 창/마우스 안 건드림)
powershell -ExecutionPolicy Bypass -File "$SC\tests\Test-Integration.ps1"

# 3) 실기 테스트 — 진짜 캡처 + 진짜 클릭 (메모장이 잠깐 떴다가 닫힘)
powershell -ExecutionPolicy Bypass -File "$SC\scripts\Test-ScreenControl.ps1"
```

3번이 확인하는 것:

| 구분 | 항목 |
|---|---|
| 양성 | 창 캡처 + 좌표격자 + 메타데이터 생성 / 실제 버튼 클릭 / 클릭 후 화면 변화 감지 / `-WhatIf` 는 클릭하지 않고 조준 이미지만 생성 |
| 음성(반드시 거부) | 창 밖 좌표(exit 4) / 증거 캡처 없음(exit 5) / 위험 의도 무승인(exit 6) / 존재하지 않는 창(exit 2) |

테스트가 만든 이미지는 `D:\ai\.screen-control\selftest-<시각>\` 에 남는다
(D 드라이브가 없으면 `%LOCALAPPDATA%\screen-control\`). Read 도구로 열어서 눈으로 확인하면 된다.

### 모의(mock) 백엔드

`tests/MockBackend.ps1` 은 user32/GDI 호출을 가짜 창으로 대체한다.
`SCREEN_CONTROL_MOCK` 환경변수가 설정되어 있을 때만 로드되며, 로드되면 경고를 찍고
**실제 클릭은 절대 발생하지 않는다.** 평상시에는 이 변수를 설정하지 않는다.
이 덕분에 Windows·실제 창 없이도 CI나 리눅스에서 안전장치 동작을 회귀 검증할 수 있다.

## 지금까지 어디까지 검증했나

이 코드는 리눅스 컨테이너에서 작성되었다. 거기서 돌릴 수 있는 것은 전부 돌렸고,
**실제 GDI 캡처와 SendInput 입력만 Windows 실기 확인(위 3번)이 남아 있다.**

통과한 검사 (총 69개):

| 테스트 | 개수 | 내용 |
|---|---|---|
| 구문/컴파일 | - | 전 파일 파서 검사, 임베디드 C# 컴파일, `INPUT` 구조체 40바이트(x64 실제값과 일치) |
| `Test-Logic.ps1` | 30 | 좌표 변환(축소 보정·멀티모니터 정규화), 위험 키워드 탐지(`clock` 오탐 방지 포함), 증거 검증(오래됨/다른 창/창 이동/전체화면), 종료 코드, 감사 로그 |
| `Test-Integration.ps1` | 29 | 창 목록·필터, 4가지 좌표계 클릭, 축소 캡처 보정, 오른쪽/더블 클릭, 거부 시나리오 11종(전부 "클릭 이벤트 0건" 까지 확인), `-WhatIf`, 모호한 창, 감사 로그 |
| `Test-ScreenControl.ps1` (모의 백엔드) | 10 | 캡처 → 클릭 → 재캡처 변화 감지 전체 사이클 |

이 과정에서 실제로 잡은 버그 3건:

1. **모든 클릭이 (0,0) 으로 계산되던 문제** — 래퍼 함수가 advanced function 이라
   스크립트의 `$PSCmdlet` 을 가려 파라미터 세트가 `__AllParameterSets` 로 잡혔고,
   좌표 변환 `switch` 가 통째로 건너뛰어졌다. (Windows 에서도 동일하게 깨졌을 버그)
2. **`-WhatIf` 실행 시 출력 폴더 생성과 감사 로그 기록이 조용히 취소되던 문제** —
   ShouldProcess 를 지원하는 cmdlet 들이 전부 건너뛰어졌다.
3. **출력이 파이프로 리디렉션되면 표가 아무것도 출력되지 않던 문제** —
   자동화(= Claude 가 스크립트를 실행하는 경우)에서 창 목록이 빈 것처럼 보였다.

## 폴더 구조

```
screen-control/
  SKILL.md              사용 규칙 (Claude 가 읽는 문서)
  README.md             설치/검증 (이 문서)
  Install-Skill.ps1     ~/.claude/skills 로 설치
  lib/
    ScreenControl.psm1  코어 (Win32 P/Invoke, 캡처, 클릭, 검증, 로깅)
    Bootstrap.ps1       스크립트 공통 오류/종료코드 처리
  tests/
    MockBackend.ps1       모의 Win32/GDI 백엔드 (SCREEN_CONTROL_MOCK 로만 활성화)
    Test-Integration.ps1  모의 백엔드 위에서 도는 통합 테스트 29종
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
