---
name: screen-control
description: Windows 화면을 캡처해서 직접 보고, 좌표를 판단해 마우스로 클릭하는 GUI 자동화. 특정 창(AutoCAD, 메모장 등)을 대상으로 "캡처 → 이미지 확인 → 클릭 → 재캡처로 검증" 루프를 안전장치와 함께 수행한다. Use when the user wants to see the Windows desktop or a specific window, click a button by coordinates, drive a GUI app that has no CLI/API, verify what is currently on screen, or combine screenshots with SendKeys keyboard automation. PowerShell + Win32 API 만 사용하며 MCP 서버가 필요 없다.
---

# screen-control — Windows 화면 보고 클릭하기

PowerShell 에서 `Add-Type` 으로 Win32 API(user32/dwmapi)와 System.Drawing 을 직접 호출한다.
추가 설치나 MCP 서버가 필요 없다. **Windows 전용** (Windows PowerShell 5.1 권장, PowerShell 7 도 가능).

## 대원칙: 본 것만 클릭한다

1. 클릭은 항상 **대상 창 하나**를 기준으로 한다. 창이 없거나/최소화/비활성이면 클릭하지 않는다.
2. **직전에 캡처한 이미지(증거)** 없이는 클릭이 거부된다. 캡처 후 창이 움직였어도 거부된다.
3. 삭제/저장/전송/확인 같은 **위험한 클릭은 사용자 승인** 없이는 거부된다.
4. 커서 이동 후 **지연 → 커서 위치 재확인 → 그 지점의 창이 대상인지 재확인** 후에야 버튼을 누른다.
5. 실패는 조용히 넘어가지 않는다. 항상 명확한 메시지 + 종료 코드로 끝나고, **엉뚱한 곳을 클릭하지 않는다**.

## 기본 루프 (이 순서를 지킬 것)

```powershell
$SC = "$env:USERPROFILE\.claude\skills\screen-control\scripts"

# 1) 대상 창 찾기 — 핸들을 고정해두면 가장 안전하다
& $SC\Get-Window.ps1 -ProcessName notepad

# 2) 캡처 (창 활성화 + PNG + 좌표격자 + 메타데이터 생성)
& $SC\Capture-Screen.ps1 -Handle 0x1A2B3C -Name step1
```
3) **Read 도구로 `...step1.grid.png` 를 직접 열어본다.** (이 단계를 건너뛰지 말 것)
   격자의 숫자 라벨이 곧 `-WindowX / -WindowY` 값이다.

```powershell
# 4) (선택, 정확도 급상승) UI 요소의 좌표를 자동으로 얻기
& $SC\Find-UIElement.ps1 -Handle 0x1A2B3C -NameLike '보기'

# 5) 어디를 누를지 먼저 조준만 해보기 (실제로 누르지 않음, .target.png 생성)
& $SC\Invoke-Click.ps1 -Evidence <step1.png 경로> -WindowX 420 -WindowY 160 -Intent '보기 메뉴' -WhatIf
```
6) `.target.png` 를 Read 로 열어 **십자 표식이 원하는 버튼 위에 있는지 확인**한다.

```powershell
# 7) 진짜 클릭 (끝나면 자동으로 재캡처 + 변화량 비교까지 해준다)
& $SC\Invoke-Click.ps1 -Evidence <step1.png 경로> -WindowX 420 -WindowY 160 -Intent '보기 메뉴'
```
8) 출력에 찍힌 `클릭 후 캡처` 이미지를 Read 로 열어 **의도한 변화가 생겼는지 확인**한다.
   변화량이 0% 면 빈 곳을 눌렀다는 뜻이니 좌표를 다시 잡는다.

좌표를 다시 잡아야 하면 **2번부터 다시** 한다. 오래된 캡처를 근거로 다시 클릭하지 않는다(자동 거부됨).

## 스크립트

| 스크립트 | 하는 일 |
|---|---|
| `Get-Window.ps1` | 창 목록/핸들/위치/DPI 확인 |
| `Capture-Screen.ps1` | 창(기본) 또는 `-Screen` 전체화면 캡처 → `.png` + `.grid.png` + `.json` |
| `Invoke-Click.ps1` | 검증 통과 시에만 클릭. `-WhatIf` 로 조준만 가능 |
| `Convert-Point.ps1` | 창 ↔ 화면 ↔ 클라이언트 ↔ 이미지 좌표 변환 |
| `Compare-Capture.ps1` | 두 캡처의 변화량(%) 및 변화 영역 |
| `Find-UIElement.ps1` | (선택) UI Automation 으로 버튼/메뉴 좌표 자동 탐색 |
| `Test-ScreenControl.ps1` | 전체 사이클 + 안전장치 자동 검증 |
| `Test-Logic.ps1` | 좌표/키워드/증거 검증 로직 단위 테스트 (Windows 아니어도 실행 가능) |
| `../tests/Test-Integration.ps1` | 모의 Win32 백엔드로 전체 흐름 검증 (실제 창/마우스를 건드리지 않음) |

산출물 기본 폴더: `D:\ai\.screen-control` (없으면 `%LOCALAPPDATA%\screen-control`).
`SCREEN_CONTROL_OUT` 환경변수나 `-OutDir` 로 바꿀 수 있다. 모든 캡처/클릭은
`screen-control.log.jsonl` 에 기록된다.

## 좌표계 (헷갈리면 `Convert-Point.ps1`)

| 옵션 | 기준점 | 언제 |
|---|---|---|
| `-WindowX/-WindowY` | 창 좌상단 (0,0) | **기본 권장.** 창 캡처 `.grid.png` 의 라벨과 동일 |
| `-ClientX/-ClientY` | 타이틀바/테두리를 뺀 내부 영역 좌상단 | 앱 내부 좌표를 알고 있을 때 |
| `-ScreenX/-ScreenY` | 모니터 전체(가상 데스크톱) 절대 좌표 | 전체화면 캡처, 멀티모니터 |
| `-ImageX/-ImageY` | 증거 이미지의 픽셀 좌표 | 축소 캡처일 때 자동 보정됨 |

캡처가 `-MaxWidth`(기본 1600)로 축소되면 `.json` 의 `scale` 이 1 미만이 된다.
이때도 **격자 라벨은 원본 좌표**이므로 `-WindowX/-WindowY` 를 그대로 쓰면 된다.
이미지 픽셀을 눈대중으로 셀 때만 `-ImageX/-ImageY` 를 쓴다.

## Claude 가 지켜야 할 안전 규칙

- **블라인드 클릭 금지.** 클릭 전에 반드시 캡처 이미지를 Read 로 열어보거나, 최소한
  `-WhatIf` 로 만든 `.target.png` 를 확인하고 어디를 누를지 사용자에게 말로 설명한다.
- **위험 버튼은 먼저 물어본다.** 삭제/저장/덮어쓰기/전송/결제/종료/확인(OK)/플롯 등은
  `-Intent` 문구에서 자동 감지되어 `exit 6` 으로 거부된다.
  이때 **사용자에게 한국어로 무엇을 누를지 설명하고 허락을 받은 다음에만** `-UserApproved` 를 붙인다.
  사용자가 허락하지 않았는데 `-UserApproved` 를 붙이는 것은 이 스킬의 규칙 위반이다.
- **전체화면 캡처(`-Screen`)는 클릭의 증거로 쓸 수 없다.** 화면 파악용으로만 쓰고,
  클릭 직전에는 창 캡처를 다시 한다.
- **실패하면 같은 명령을 반복하지 말고** 원인(종료 코드)을 읽고 사용자에게 보고한다.
  특히 `exit 3`(활성화 실패)는 보통 관리자 권한 창이나 UAC 대화상자 때문이며, 재시도로 풀리지 않는다.
- 드롭다운/컨텍스트 메뉴처럼 창 밖에 뜨는 팝업을 누를 때만 `-AllowOutsideWindow` 를 쓴다.
  이 옵션은 "다른 창을 눌러도 된다"는 뜻이므로, 사용 전에 캡처로 팝업 위치를 확인한다.

## 종료 코드

| 코드 | 의미 | 대처 |
|---|---|---|
| 0 | 성공 | |
| 2 | 창 없음/모호함 | `Get-Window.ps1` 로 확인 후 `-Handle` 로 고정 |
| 3 | 창 활성화 실패 | 관리자 권한 앱/UAC/전체화면 앱. 사용자에게 창을 앞으로 올려달라고 요청 |
| 4 | 좌표가 창·화면 밖이거나 다른 창이 가림 | 다시 캡처해서 좌표 재계산 |
| 5 | 증거 캡처 없음/오래됨(기본 180초)/창이 이동함 | **다시 캡처**한 뒤 클릭 |
| 6 | 위험한 클릭 — 사용자 승인 필요 | 사용자에게 확인 후 `-UserApproved` |
| 7 | Windows 아님 / 네이티브 초기화 실패 | |
| 8 | 커서가 의도한 위치로 가지 않음 | 다른 자동화 도구/원격 세션 확인 |
| 9 | 인자 오류 | |

## 키보드 입력과 함께 쓰기

이 스킬은 마우스만 담당한다. 키 입력은 기존 방식이 그대로 유효하다.

```powershell
$w = New-Object -ComObject WScript.Shell
$w.AppActivate((Get-Process acad).MainWindowTitle) | Out-Null
Start-Sleep -Milliseconds 300
$w.SendKeys('LINE{ENTER}')
```

AutoCAD 처럼 **명령행이 있는 앱은 좌표 클릭보다 명령어 입력이 훨씬 안전하다.**
클릭은 (a) 명령어가 없는 대화상자 버튼, (b) 팔레트/리본의 아이콘,
(c) 도면 영역의 특정 지점을 찍어야 할 때만 쓴다.

## 자주 막히는 곳

- **좌표가 어긋난다 (특히 4K/노트북)** — 스크립트가 DPI 인식을 켜므로 물리 픽셀 기준으로 동작한다.
  그래도 어긋나면 `Convert-Point.ps1` 로 실제 창 위치를 먼저 확인한다.
- **관리자 권한으로 실행 중인 앱** — 일반 권한 PowerShell 의 입력은 무시된다(UIPI).
  PowerShell 을 같은 권한으로 실행해야 한다.
- **RDP/원격 세션이 최소화됨** — 화면이 그려지지 않아 캡처가 검게 나온다. 세션을 열어둔 채로 실행한다.
- **창이 다른 창에 가려짐** — 캡처는 활성화 후 찍으므로 보통 괜찮지만, 항상 위(topmost) 창이 있으면
  `exit 4` 로 거부된다. 그 창을 치운 뒤 다시 시도한다.
- **캡처가 검게 나오는 앱(하드웨어 가속/보호 콘텐츠)** — `Capture-Screen.ps1 -Method PrintWindow` 를 시도한다.
