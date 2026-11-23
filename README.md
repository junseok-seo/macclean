# MacClean

> Mac disk and memory management tool

맥 저장공간과 메모리를 **"어디에 뭐가 있고, 지워도 되는지"** 판정해서 보여 주는 macOS 앱입니다.
기본 '저장 공간 관리'가 "기타 / 시스템 데이터"로 뭉뚱그리는 것을 폴더 단위로 풀어서, 항목마다 무엇인지·어느 앱 것인지·지우면 어떻게 되는지를 설명합니다.

## 설치

### 릴리스에서 받기

[Releases](https://github.com/junseok-seo/macclean/releases)에서 `MacClean-x.y.z.dmg` 를 받아 열고, `MacClean` 을 `Applications` 로 끌어 넣으세요.

Apple 개발자 인증서로 공증(notarize)하지 않은 앱이라 처음 열 때 "확인되지 않은 개발자" 경고가 뜹니다.
시스템 설정 > 개인정보 보호 및 보안 아래쪽의 **"그래도 열기"** 를 누르거나, 터미널에서 다음을 실행하세요.

```bash
xattr -dr com.apple.quarantine /Applications/MacClean.app
```

### 직접 빌드

```bash
./scripts/build.sh --install
```

- `dist/MacClean.app` 과 `dist/MacClean-1.0.0.dmg` 를 만들고 `/Applications` 에 복사합니다.
- 요구 사항: macOS 14 이상(실행), Xcode 또는 Swift 6 도구(빌드).

### 권장: 전체 디스크 접근 권한

시스템 설정 > 개인정보 보호 및 보안 > **전체 디스크 접근 권한** 에서 MacClean을 켜고 앱을 다시 실행하세요.
권한이 없으면 휴지통·메일·메시지·다른 앱의 데이터 폴더 크기를 읽지 못하고, 폴더마다 접근 허용 창이 뜹니다.
권한이 없는 첫 실행에서는 허용 창이 연달아 뜨지 않도록 자동 검사를 하지 않습니다.

> 앱을 다시 빌드하면 서명이 바뀌어 권한을 다시 켜야 할 수 있습니다.

## 기능

| 화면 | 하는 일 |
|---|---|
| **개요** | 디스크 여유·퍼지 가능 공간, 메모리 압력, 정리 가능 용량, 가장 큰 항목 |
| **정리 추천** | 알려진 정리 대상을 그룹별로 찾아 체크리스트로 보여 줌. 항목을 누르면 설명·경로·정리 방법 |
| **디스크 탐색** | 홈/전체 디스크/폴더를 스캔해 폴더를 따라 들어가며 크기와 판정 확인. 오른쪽 패널에 설명과 조치 버튼 |
| **대용량 파일** | Spotlight + 스캔 결과에서 큰 파일을 크기·마지막으로 연 날·종류로 거름 |
| **앱 관리** | 앱 크기 + 라이브러리에 남긴 데이터 크기 + 마지막 사용일. 앱과 찌꺼기를 함께 휴지통으로 |
| **메모리** | 메모리 압력, 사용 내역(앱/와이어드/압축/캐시/스왑), 앱별 사용량(헬퍼·가상머신 포함), 상태 해석, 앱 종료 |
| **메뉴 막대** | 창을 내려놓으면 디스크 사용률·메모리 사용량·CPU·GPU를 숫자로 표시. 더블클릭하면 창이 다시 열림 |

### 메뉴 막대로 내려놓기

- 창의 **노란 버튼(최소화)** 또는 ⌥⌘M → 창과 Dock 아이콘이 사라지고 메뉴 막대에 `디스크 74% · 메모리 81% · CPU 12% · GPU 10%` 가 표시됩니다.
- 메모리 %는 실제 메모리 대비 사용량(앱 + 와이어드 + 압축)입니다. 높아도 정상일 수 있어 경고색은 **메모리 압력**이 경고 이상일 때만 켜집니다. 마우스를 올리면 GB 수치가 보입니다.
- 숫자를 **더블클릭** → 창이 다시 열립니다. 한 번 클릭하면 요약 팝오버, 우클릭하면 메뉴.
- 빨간 버튼으로 닫아도 앱은 메뉴 막대에 남습니다. 설정에서 "창이 열려 있을 때도 수치 표시"를 켤 수 있습니다.
- GPU 사용률은 IOKit의 가속기 성능 통계(Apple Silicon 포함)에서 읽으며 관리자 권한이 필요 없습니다.

### 정리 추천이 찾는 것

- **휴지통**
- **개발 도구**: Xcode DerivedData·DeviceSupport·프리뷰, 사용 불가 시뮬레이터, npm/Yarn/pnpm/Bun/pip/uv/Poetry, Homebrew, Gradle/Maven, Cargo, Go, CocoaPods, JetBrains, VS Code 확장 설치 파일, Flutter/Dart, Arduino·ESP-IDF 다운로드, Conda, Hugging Face
- **Docker**: 빌드 캐시·멈춘 컨테이너(안전), 사용하지 않는 이미지 전부(주의, 직접 선택해야 함). **볼륨(DB·모델 데이터)은 지우지 않습니다.**
- **앱 캐시**: `~/Library/Caches` 와 샌드박스 앱 캐시를 앱 이름별로
- **브라우저·웹 기반 앱 캐시**: Chrome·웨일·Edge 와 Electron 앱(VS Code, Slack, Discord, Claude…)의 Cache / Code Cache / GPUCache / Service Worker 캐시 (로그인·기록은 그대로)
- **로그·임시 파일**, 메일 첨부 임시 사본
- **프로젝트 빌드 산출물**: `node_modules`, `.next`, Rust `target`, Swift `.build`, Gradle/Flutter `build`, `Pods`, `.venv` — 프로젝트를 90일 넘게 안 건드렸을 때만 기본 선택
- **다운로드 폴더**: 설치 파일(.dmg/.pkg), 오래된 압축 파일, 이미 설치된 앱의 사본, 6개월 넘은 큰 파일
- **iPhone·iPad 백업** (기기 이름·마지막 백업일 표시)
- **삭제된 앱의 잔여 파일**: 설치된 앱이 없는데 남아 있는 Application Support / Containers / Caches / Preferences 등
- **앱에서 직접 정리할 큰 데이터** (안내만): 카카오톡·텔레그램·iMessage·Mail·사진 보관함·Android SDK·시뮬레이터 런타임 등 — 직접 지우면 위험하므로 해당 앱에서 줄이는 방법을 알려 줌
- **Time Machine 로컬 스냅샷**

## 판정 기준

| 배지 | 의미 | 정리 방식 |
|---|---|---|
| 🟢 **안전** | 캐시·로그·빌드 산출물처럼 지워도 자동으로 다시 만들어짐 | 바로 삭제 (설정에서 휴지통으로 바꿀 수 있음) |
| 🔵 **확인** | 내가 받거나 만든 파일, 삭제된 앱의 잔여물 | 휴지통으로 이동 |
| 🟠 **주의** | 앱 데이터·백업. 지우면 기록·설정이 사라짐 | 휴지통으로 이동, 기본 선택 안 함 |
| 🔴 **보존** | 직접 지우면 손상됨 (사진 보관함, Mail, 키체인, 시스템) | 지우기 버튼 없음, 앱 안에서 정리하는 방법 안내 |

판정은 `Sources/MacCleanCore/PathKnowledge.swift` 의 경로 규칙(약 200개)으로 이뤄집니다. 규칙이 없는 폴더는 상위 폴더 규칙을 물려받고, 그래도 없으면 이름·확장자로 추정하며 "추정" 표시를 붙입니다.
폴더 이름이 번들 ID(`com.foo.bar`)인데 해당 앱이 설치돼 있지 않으면 "삭제된 앱"으로 표시합니다.

## 안전장치

- `/`, `/System`, `/Applications`, 홈, `~/Library` 와 그 바로 아래 폴더, `~/Documents`·`~/Desktop`·`~/Downloads` 등 기본 폴더 자체, `~/.ssh`, 키체인은 **코드 수준에서 삭제 거부**
- 홈 밖에서는 `/Applications` 안의 앱만 삭제 가능
- 캐시 폴더는 폴더를 남기고 내용만 비움
- 그룹 전체 선택 체크박스는 '안전'·'확인' 항목만 고름. '주의' 항목은 하나씩 직접 골라야 함
- 정리 전 확인 창에서 바로 삭제/휴지통/명령 실행을 나눠서 보여 주고, 실행 중인 앱과 '주의' 항목을 경고
- iCloud·클라우드 전용 파일은 크기를 셀 때 다운로드되지 않도록 막음
- 파일 내용은 읽지 않고 크기·날짜만 확인. 네트워크로 아무것도 보내지 않음

## 메모리에 대해

- 숫자보다 **메모리 압력**이 중요합니다. 초록(정상)이면 사용량이 높아 보여도 macOS가 남는 메모리를 캐시로 쓰고 있는 것입니다.
- 앱의 헬퍼 프로세스와, 그 앱이 띄운 가상머신(Docker·Claude 등)까지 앱 단위로 합쳐서 보여 줍니다.
- '메모리 정리(purge)'는 캐시만 비우므로 보통 효과가 없다는 점을 화면에서 설명합니다. 부족할 때는 많이 쓰는 앱을 종료하는 것이 확실합니다.

## 개발

```bash
swift build                          # 디버그 빌드
swift run mccheck explain ~/Library/Caches/Google   # 경로 판정 확인
swift run mccheck cleanup            # 정리 추천 검사 (아무것도 지우지 않음)
swift run mccheck scan ~/Library     # 폴더 스캔
swift run mccheck memory             # 메모리·프로세스
swift run mccheck apps 20            # 앱 크기
swift run mccheck selftest           # 삭제 안전장치 테스트 (임시 폴더만 사용)
swift run mccheck clean --default    # 기본 선택 항목 미리보기 (--yes 를 붙여야 실제 정리)

# 화면 검증 (각 화면을 PNG로 저장, 아무것도 지우지 않음)
dist/MacClean.app/Contents/MacOS/MacClean --snapshot /tmp/shots ~/Library/Developer
dist/MacClean.app/Contents/MacOS/MacClean --window-test /tmp/wt   # 내려놓기·더블클릭 복귀 확인
```

구조:

```
Sources/MacCleanCore/   판정·스캔·정리 엔진 (UI 없음)
  PathKnowledge.swift   경로 → "무엇인지, 지워도 되는지" 규칙
  AppRegistry.swift     설치된 앱 목록, 폴더 이름 → 소유 앱 / 삭제된 앱 판별
  DiskScanner.swift     fts 기반 고속 스캔 (작은 파일은 폴더별 합계로 보관)
  Cleanup.swift         정리 추천 검사와 실행
  Apps.swift            앱 크기·관련 데이터·삭제
  Memory.swift          메모리 통계, 앱별 프로세스 집계
  System.swift          삭제 안전장치, 셸 명령, 디스크 용량, 권한 확인
Sources/MacClean/       SwiftUI 앱
Sources/mccheck/        검증용 명령줄 도구
scripts/                빌드·아이콘·Info.plist
```
