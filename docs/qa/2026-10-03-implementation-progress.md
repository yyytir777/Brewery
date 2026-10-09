# Brewery 개선 구현 및 QA 결과

2026-10-03 · 기준: `7fabaf8` + 작업 시작 당시의 미커밋 내비게이션 변경사항.

**최신 후속 결과는 [QA 구현 및 실행 기록](2026-10-03-qa-completion.md)에 있다.** 아래 자동 검증·UI 표는 첫 구현 단계의 기록이다. 이후 XCTest 141개, strict concurrency 검사, 실제 격리 Homebrew CLI 29개 명령·15개 검증, 네이티브 앱의 설치·부분 실패·재시도·정리·삭제, Universal Release와 UI 타깃 빌드까지 검증했다. 정보 팝오버 오류, List 식별자, 캐시/JSON의 메인 스레드 실행, 중복 행 계산과 초기 로딩 경쟁 상태, 실제 명령 종료 뒤 Activity 정지, 다중 keg의 버전·날짜 표시도 추가 수정했다. 검색 최적화 단계 Release의 동일 64개 검색 교체에서 binding→AppKit 창 갱신 p95는 379.48→140.02ms였고, 강제 새로고침의 캐시·정렬 준비가 백그라운드에서 실행됨을 확인했다. 이후 명령 실행기·설치 버전 수정은 이 성능 측정 뒤에 적용됐으며 해당 검색 소스는 유지됐다. 최종 네이티브 QA는 최신 모델의 구버전 keg 잔존 표시까지 확인했고, 보호 경로 14개·기존 설정 내용 동일 및 임시 환경 정리를 검증했다. 앞서 설정 지문 변화로 정리가 거부된 실행의 증거는 따로 보존했다. 지원 환경별 실행과 UI CI 최초 실행은 후속 Task이며, 사용자 선택에 따라 커밋·push·PR 없이 로컬 검증까지만 진행했다.

최초 [서비스 감사](2026-10-03-service-audit.md)의 T01~T12, T14~T16을 구현했다. T13은 자동 회귀와 직접 UI QA까지 진행했으며 UI 자동화와 환경별 QA가 남았다. T17은 계산 비용 계측·최적화를 완료했고 전체 화면 렌더링 프로파일링이 남았다. 제품 기능의 구현 완료와 실제 Homebrew 변경 명령의 운영 검증은 구분한다.

## Task별 결과

| Task | 상태 | 구현 및 근거 |
|---|---|---|
| T01 기간 경쟁 상태 | 완료 | 최신 요청만 화면에 반영하고 기간별 스냅샷을 보존. 지연 응답 회귀 테스트 |
| T02 부분 실패 데이터 보존 | 완료 | Formula/Cask별 마지막 성공 데이터를 유지하고 실패·갱신 시각 표시 |
| T03 카탈로그·순위 캐시 | 완료 | 카탈로그 24시간, 기간·종류별 통계 1시간 TTL, 강제 새로고침, 스키마 검증, 원자적 저장, 번들/오프라인 복구. 여러 창의 실패가 최신 디스크 데이터를 덮지 않도록 병합 |
| T04 패키지 식별자 | 완료 | Formula full_name, Cask full_token과 타입으로 구분. 외부 tap 동명 패키지 분리. Cask outdated의 짧은 token은 수신 단계에서만 설치 ID에 대응 |
| T05 로딩·실패 상태 | 완료 | 손상/명령 실패 시 기존 목록 보존. 정보 팝오버 재시도. 업데이트 조회 실패를 최신 상태와 구분 |
| T06 전체 인기순 | 완료 | Formula/Cask 통합 순위, 타입과 기간·설치 수 표기. 검색 시 원래 인기 순위 유지 |
| T07 설치 목록 검색 | 완료 | 검색·종류·업데이트 필터, 새로고침, 선택 및 상세 왕복 시 검색 조건 보존 |
| T08 업데이트 작업 흐름 | 완료 | Home 카드에서 목록 이동, 선택 업데이트, Activity에서 항목별 결과 확인. Homebrew 정의 갱신과 패키지 업그레이드 구분 |
| T09 작업 공통화 | 완료 | 앱 전체 공유 모델, 변경 명령 직렬 큐, 중복/충돌 방지, 출력·결과 기록, 대기 작업 취소. 실행 중인 Homebrew 변경은 완료 후 다음 작업 수행 |
| T10 정리·데이터 삭제 | 완료 | cleanup --dry-run 미리보기, 결과와 용량 재조회, Cask 데이터 삭제 시 공유 파일 경고 |
| T11 검색·레이아웃 | 완료 | 최초 ⌘F 포커스, 좁은 창 필터 줄바꿈, 검색/필터 변경 시 목록 상단 복귀 |
| T12 그래프 갱신 | 완료 | 루트 메타데이터 변경 시 이전 로딩 무효화, 동일 메타데이터의 상태 유지, 화면 이탈 시 대기 로딩 취소 |
| T13 회귀·QA | 부분 완료 | 최신 XCTest 141개 통과. Debug fixture·UI 자동화 10개·CI 구현과 strict 빌드 완료. 실제 UI runner·환경별 실행은 후속 기록 참조 |
| T14 Homebrew 연결 | 완료 | 미설치 안내·공식 설치 링크·재시도. 미연결 시 변경 작업 차단 |
| T15 불필요 코드 | 완료 | 호출되지 않는 CLI 검색과 SearchResult 제거 |
| T16 정보·내비게이션 | 완료 | Sidebar를 Home/Installed/Updates/Discover로 통합. Home 중복 숫자 축소, Settings를 Diagnostics로 정리 |
| T17 검색 성능 | 부분 완료 | 검색 필드 정규화·결과 캐시·자연 정렬 인덱스·List 최적화, 캐시/JSON 백그라운드 처리. 최종 Release 검색 p95 140.02ms·검색과 겹친 멈춤 표본 0개 확인. 부분 실패의 긴 안내·GPU 표시·지원 환경별 지표는 남은 범위 |

## 자동 검증

- 최종 새 Debug 빌드에서 **XCTest 97개 통과, 실패 0**. 16개 suite: Discover 22, 그래프 29, 인벤토리/작업 15, 내비게이션·필터 12, 기존 파싱·식별자·명령 등 19.
- 모의 릴리스 스크립트 **125개 assertion 통과** (`zsh scripts/tests/release_test.sh`). 배포 명령은 모의 실행기로 검증했다.
- Python 카탈로그 생성기 **2개 테스트 통과**.
- 최적화 Release 빌드 **BUILD SUCCEEDED**. 마지막 Release 앱 재실행 시 Mac이 잠겨 실행 화면은 확인하지 못했다. 위 직접 UI QA는 Debug 앱에서 완료한 결과다. 서명/공증/배포는 이 검증 범위에 포함하지 않았다.
- 최종 Swift 소스 컴파일 경고 **0개**. Xcode의 AppIntents 메타데이터 생략 안내와 macOS 13 테스트 타깃이 macOS 14용 XCTest 프레임워크를 링크하는 도구 경고는 남아 있다. macOS 13에서 실행된 테스트라는 의미가 아니다.
- 독립 코드 리뷰에서 발견한 여러 창의 캐시 롤백, 외부 tap Cask의 업데이트 판정, 강제 새로고침 누락, 상세의 잘못된 Latest 표기를 수정했다. 재리뷰에서 남은 P2 이상 결함은 발견되지 않았다.

최종 명령:

```sh
xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/brewery-implementation/final-DD CODE_SIGNING_ALLOWED=NO test
xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/brewery-implementation/release-DD CODE_SIGNING_ALLOWED=NO build
zsh scripts/tests/release_test.sh
python3 -m unittest discover -s scripts/tests -p '*test.py'
```

## 직접 UI QA

현재 Mac의 ARM64/다크 모드에서 네이티브 앱을 직접 조작했다. 변경 명령의 성공·실패·중복·큐 동작은 주입한 명령 실행기로 테스트했다.

| 시나리오 | 관찰 결과 |
|---|---|
| Home 초기 로딩 | 실제 설치 150개, 업데이트 95개, 버전·용량 및 목적지 표시 |
| 최초 ⌘F → Discover | 검색창 포커스 확인 후 바로 입력 가능 |
| 스크롤 후 git 검색 | 첫 QA에서 이전 위치 유지 결함 발견 → 수정 후 scroll=0, 정확히 일치하는 git이 맨 위 |
| 검색 결과 없음 | 안내와 Clear Filters로 복구 |
| 30일 → 365일 → 30일 | git 설치 수 55,200 → 1,417,416 → 55,200, 헤더 기간과 데이터 일치 |
| Discover ⌘R | 캐시 TTL 안에서도 갱신 시각이 12:39 → 12:45로 변경 |
| 패키지 정보 | git-lfs 정보, 버전, 홈페이지 표시 및 Escape 닫기 |
| 설치 목록 검색 | git 1건, iterm 1건으로 필터링. 상세·뒤로가기 후 검색값 유지 |
| 선택 업데이트 | Select Available Updates로 선택 수와 Update Selected(1) 일치. 실제 실행은 모의 테스트에서 검증 |
| Formula 상세·그래프 | git → pcre2 확장, 의존성 없음 상태 및 뒤로가기 정상 |
| 좁은 창 | 약 808×464pt에서 Installed 버튼 접근 가능, Discover 필터 세로 배치. Home은 스크롤로 하단 접근 |
| Cleanup preview | 실제 dry-run이 대상과 예상 162.4MB를 표시. 취소 후 삭제 실행 없음 |
| Activity | 빈 상태 및 Done/Escape 닫기. 진행·완료·실패 상태는 모델 회귀로 검증 |
| Settings | Diagnostics 표시, 로그 삭제 확인 문구 및 취소 |
| Cask 데이터 삭제 | iterm2 경고에 다른 앱과 공유되는 파일 설명 표시. 취소 후 설치 수 150개와 상세 유지 |

## 성능 계측

16,249개 패키지에 대한 최적화 Swift `rows()` harness에서 검색어를 바꾸는 90회 계산의 p50은 **38.65 → 15.86ms**, p95는 **143.56 → 34.31ms**였다. 반복 동일 검색의 평균 계산은 약 0.5~1ms, 최초 인덱스 준비는 약 31ms다. 실제 키 입력부터 SwiftUI 화면 렌더링 완료까지의 지연이나 프레임 속도를 측정한 수치는 아니다.

## 남은 Task

이 목록은 최초 구현 단계의 인수 조건이다. 이후 격리 CLI와 UI 자동화/CI 구현이 완료되었으므로 **현재 상태와 남은 실행 조건은 [후속 QA Task 표](2026-10-03-qa-completion.md#환경-및-남은-task)**를 따른다.

- [ ] **QA-01 · P2 · 격리된 Homebrew 환경에서 실제 변경 명령 검증**
  - Formula/Cask 설치·업데이트·삭제, tap 패키지, 권한 실패, 여러 항목 중 일부 실패, cleanup 결과/용량 갱신을 전용 사용자 또는 VM에서 실행한다.
  - 완료 조건: 실행 전후 패키지·파일 상태와 Activity 결과가 일치하고 실패 후 재시도가 가능하다. 이 세션에서는 사용자의 실제 패키지를 변경하지 않았다.
- [ ] **QA-02 · P2 · 지원 환경 및 접근성 검증**
  - macOS 13/Intel, 라이트 모드, 고대비·글자 확대, VoiceOver, 키보드만으로 전체 동선, 네트워크 단절/복구 및 미설치 시작 화면을 검증한다.
  - 완료 조건: 환경별 결과와 스크린샷·실패 재현을 QA 행렬에 기록한다. 연결/오프라인 분기는 모의 자동 테스트가 있으며 해당 환경의 전체 화면 QA는 남아 있다.
- [ ] **QA-03 · P2 · UI 회귀 자동화와 CI 연결**
  - 실제 Homebrew를 실행하지 않는 앱 fixture 진입점과 UI 테스트 타깃을 추가한다.
  - 완료 조건: Home → Discover → 상세 → 뒤로가기, 최초 포커스, 필터 유지, 선택·큐 취소, 삭제 취소가 CI에서 재현 가능하다. 이번 세션의 직접 UI 조작은 반복 실행 가능한 자동 UI suite가 아니다.
- [ ] **PERF-01 · P3 · 입력부터 렌더링까지 성능 측정**
  - Instruments로 검색 입력, 목록 갱신, 부분 실패 후 긴 안내 표시, 카탈로그/캐시 저장의 메인 스레드 점유를 측정한다.
  - 완료 조건: 대표 검색의 프레임 끊김과 p95 입력 지연을 기록하고 필요한 경우 계산·파일 작업을 메인 스레드 밖으로 분리한다.

## 보존 및 검증 기록

원래 작업 폴더의 기존 변경사항을 복사한 관리형 worktree에서 구현했다. 반영 직전 시작 시점 SHA-256과 원본 파일을 비교해 동시 변경이 없음을 확인했고, 37개 파일을 원래 작업 폴더에 반영했다. 제품·테스트 파일이 검증한 worktree와 바이트 단위로 동일함을 확인했다. 반영 전 파일 백업은 `/private/tmp/brewery-implementation-baseline/pre-integration/`에 있다. 커밋·push·PR·릴리스 생성은 수행하지 않았다.

로그는 `/private/tmp/brewery-implementation/`에 있으며 임시 디렉터리 정리 시 사라질 수 있다. 주요 파일: `final-tests.log`, `release-build.log`, `release-script-tests.log`, `inventory-boundary-red2.log`/`inventory-boundary-green.log`, `outdated-red.log`, `cask-outdated-red.log`/`cask-outdated-green.log`, `discover-multi-instance-red.log`/`discover-multi-instance-green.log`. 원본 리뷰 재현기는 `/private/tmp/brewery-review-probe/`에 있다. 이 문서에 지속 보관할 요약과 재현 조건을 남겼다.
