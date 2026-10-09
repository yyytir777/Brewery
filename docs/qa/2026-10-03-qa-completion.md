# Brewery 후속 QA 구현 및 실행 기록

2026-10-03 · [이전 구현 보고서](2026-10-03-implementation-progress.md)의 QA-01~03 / PERF-01 후속 기록. 제품 최소 버전은 macOS 13이며, 이번 실제 실행 환경은 Apple M5 Pro / macOS 26.6.2 / Xcode 26.6이다.

## 구현한 내용

- **QA-01**: 임시 prefix에 로컬 Formula/Cask를 설치하는 실제 Homebrew 통합 검사와 22개 안전성 테스트. 네이티브 앱도 동일한 제품 실행기로 연결하는 제한된 QA 도구를 추가했다. 사용자의 prefix·앱·캐시와 분리하고, 소유권·허용 명령·제어 프로세스의 생존을 확인한다. 실패한 실행은 증거와 작업 디렉터리를 보존한다.
- **QA-02**: `standard`, `queue`, `missing-homebrew`, `info-failure`, `offline`의 Debug 전용 fixture. 실제 명령·네트워크·기존 로그로 넘어가지 않으며 잘못된 설정은 오류 화면으로 끝난다.
- **QA-03**: XCUITest 10개, 별도 `BreweryUI` scheme, 단위/UI/Universal Release CI 작업, 접근성 식별자. CI는 UI 실행 결과의 총 10개·성공 10개·실패/skip 0개를 검사한다. UI 테스트를 빌드한 것과 실행한 것은 구분한다.
- **PERF-01**: 검색 binding→AppKit window update, `rows()`, 캐시 읽기·쓰기 구간의 opt-in Instruments signpost와 기록 스크립트. 키 이벤트나 GPU 프레임 완료로 해석하지 않는다.

## QA에서 발견해 수정한 결함

정보 조회에 실패하면 전역 `Homebrew Command Failed` alert가 정보 팝오버를 닫아 `Try Again`을 사용할 수 없었다. `packageInfo`의 throwing 경로가 오류를 호출자에게 전달하도록 수정했다. 팝오버와 의존성 그래프는 각자의 오류·재시도 상태를 유지하고, 별개 작업의 전역 오류는 덮거나 지우지 않는다. 오류 출력이 비어 있어도 안내 문구를 제공한다.

관련 7개 검증의 수정 전 실패를 확인한 뒤 구현했고, 전체 단위 테스트가 통과했다. 수동 재검증에서는 전역 alert가 나타나지 않고 팝오버에 오류와 재시도 버튼이 남는 것을 확인했다. 닫았다 다시 열면 버전 1.0 정보가 표시됐다. 동일 팝오버의 재시도 버튼으로 성공 내용까지 전환하는 네이티브 검증은 아직 완료하지 않았다.

검색 성능 측정에서 `List(rows)` 내부의 중복 `.id(row.id)`가 ID 열거와 행 비교 비용을 키우는 것을 확인해 제거했다. 최종 구현은 검색·종류·기간이 바뀔 때 결과 List의 수명을 새로 시작해 스크롤을 초기화한다. 검색창과 포커스는 유지한다. 단계별 입력에서 검색·종류·기간 변경 후 첫 행·스크롤 0 복귀를 직접 확인했다. 스크롤과 필터 클릭을 한 번에 합성한 입력에서는 이후 스크롤 이동이 관찰되어, 빠른 관성 입력 경계는 별도 확인 대상으로 남겼다.

별도 새로고침 기록에서는 캐시 읽기·쓰기와 행 계산이 겹친 1.21초 메인 스레드 Hang 및 343ms JSON 해석 구간을 발견했다. `CatalogService`의 화면 측 인터페이스는 유지하고, 파일 입출력·JSON 해석·검증을 공유 백그라운드 executor로 옮겼다. 여러 창의 캐시 병합→저장은 중간 대기 없이 같은 executor에서 수행한다. 실제 번들 읽기·캐시 복원·갱신/저장의 실행 스레드를 검사하는 3개 테스트가 수정 전 실패하고 수정 후 통과했다. 최신 응답 선택과 실패 메시지 전달도 보존했다.

재측정에서는 캐시 작업 6개가 모두 worker 스레드로 이동한 것을 확인했지만 행 계산이 두 번 발생했다. 최종 구현은 이름 정규화와 자연 정렬 순서를 백그라운드에서 준비하고, 카탈로그와 순위를 한 번에 반영한다. 자연 정렬·동명 패키지·설명 검색 보존 3개와 초기 로딩/새 요청의 순서가 바뀌는 경합 2개를 추가 검증했다. 새 데이터가 아직 없으면 로컬 데이터를 보여주고, 이미 새 데이터가 반영됐으면 늦은 초기 결과를 버린다.

UI 테스트의 오류/삭제 확인 문구도 실제 macOS 접근성 트리가 제목과 본문을 하나로 합치는 경우를 처리하도록 바꿨다. 큐 테스트는 시간 지연 대신 명시적 완료 gate를 사용하며, 오프라인 테스트는 재시도 횟수 1→2를 확인한다.

실제 명령과 Activity를 연결한 후속 QA에서는 패키지 설치 명령이 성공했는데 후속 조회가 `Process.waitUntilExit()`에서 멈춰 Activity가 Running이고 설치 목록이 이전 상태에 머무는 결함을 발견했다. 실제 앱 샘플의 작업 스레드가 종료된 자식을 기다리고 있었고, Homebrew·QA 가드·로거·ViewModel을 제외한 독립 프로그램에서도 17번째 짧은 명령에서 같은 대기가 발생해 25초 watchdog으로 끝났다. 같은 스레드에서 실행/대기를 유지한 메커니즘 대조군은 500회 완료했다.

제품에서는 실행 전에 종료 콜백을 등록하고, 양쪽 파이프를 Swift 협력 실행기 밖의 GCD 작업에서 읽도록 수정했다. 종료 코드·스트리밍·실행 실패 시 126 반환을 유지한다. 실제 제품 helper로 짧은 명령 500회, 동시 16개 명령의 양쪽 64KB 출력, 실행 실패와 신호 종료를 독립 검증했다. 앱 회귀에는 반복 종료·양쪽 256KB 출력·종료 전 콜백·실패 코드·인자/환경·실행 불가의 6개 테스트를 추가했다. 엄격한 동시성 검사에서 불변 결과 타입의 격리를 명시하고 테스트 fixture의 공유 참조도 잠금으로 보호했다. 수정 앱에서 실제 설치, 권한 실패 후 설치·업데이트 재시도, 네 건 선택 업데이트의 일부 실패, cleanup, 네 건 삭제가 완료됐다. 실제 종료 코드·파일 상태와 Activity의 완료·실패 기록을 대조했다.

이 실제 설치 데이터의 독립 리뷰에서는 구버전 keg가 남아 있을 때 `installed.first`가 이전 버전과 날짜를 표시하는 결함도 발견했다. `linked_keg`와 일치하는 설치를 우선하고, 연결 정보가 없으면 최근의 알려진 설치 시각을 선택하도록 수정했다. 동률은 Homebrew가 버전 순으로 반환하는 배열의 뒤쪽을 택한다. 영수증이 없어 설치 시각이 `null`인 유효 응답도 허용한다. 실제 snapshot의 두 Formula를 포함한 회귀 8개를 추가했으며, 수정 전 7개 실패·수정 후 전체 141개 통과를 확인했다. 버전과 날짜는 같은 선택 항목에서 파생된다. 연결 정보가 없는 경우 이 정책은 대표 설치를 선택하며 실행되는 opt 경로의 버전을 증명하지 않는다. 마지막 새 격리 앱에는 이 모델 수정도 포함했다. cleanup 전 구버전 keg가 남아 있는 동안 세 건 성공·한 건 실패의 2.0/2.0/2.0/1.0 표시와 재시도 후 네 건 모두 2.0인 화면을 실제 snapshot과 대조했다.

UI 타깃에도 strict concurrency를 적용하자 기존 동기 종료 처리에서 메인 액터의 앱·스크린샷을 참조하는 오류가 드러났다. 비동기 종료 처리 안에서 메인 액터로 이동해 실패 산출물 수집·앱 종료·참조 해제를 마치고 상위 종료 처리를 호출하도록 수정했다. 최신 UI 타깃과 Universal Release는 모두 strict concurrency + Swift warnings-as-errors로 빌드됐다. UI runner 자체 실행은 여전히 별도 범위다.

## 자동·실제 CLI 검증

| 검증 | 실행 결과 |
|---|---|
| XCTest | **141 통과, 0 실패, 0 skip**, strict concurrency + Swift warnings-as-errors 적용 |
| 릴리스 스크립트 모의 검사 | **125 통과, 0 실패** |
| 카탈로그 생성기 | **2 통과** |
| 격리 Homebrew 안전성 | **22 통과**: CLI 격리 13개 + 네이티브 제어/정리 가드 9개 |
| 실제 Homebrew 7.0.7 수명주기 | **29개 명령, 15개 검증 통과**, 최종 전체 시나리오 2회 성공 |
| UI 타깃 build-for-testing | **성공**. 로컬 XCUITest 런타임 실행은 하지 않음 |
| Universal Release | **성공**, arm64/x86_64 모두 포함 |
| Release fixture 제외 | 두 아키텍처의 바이너리에서 fixture 표식 7종 없음. Debug에서 양성 대조 확인 |
| 컴파일 경고 | Swift 경고 **0개**. AppIntents 메타데이터 추출 생략 안내만 남음 |
| CI 정적 검증 | YAML, shell 문법, scheme 분리, timeout·실패 시 산출물 업로드 조건 통과. 원격 실행 이력 없음 |
| 독립 리뷰 | 발견한 문제 수정 후 남은 P2 이상 결함 미발견 |
| 동시성 검사 | 전체 앱 strict concurrency + Swift warnings-as-errors 빌드 통과. 독립 typecheck도 통과 |

실제 Homebrew 검사는 Formula/Cask 1.0 설치→2.0 업데이트→삭제, qualified tap, 일부 항목 권한 실패 및 재시도, cleanup을 실행했다. Cellar 용량은 14,430→10,849→0바이트, 캐시는 2,116→0바이트였다. 보호 경로 9개 지문이 전후 일치했고 임시 작업 디렉터리가 제거됐다. 이 CLI 결과는 실제 Homebrew와 Brewery Activity 화면을 함께 검증했다는 의미는 아니다. [격리 절차·범위](qa-isolated-homebrew.md)

## 직접 네이티브 UI QA

| 시나리오 | 관찰 결과 |
|---|---|
| 최신 Release 시작·탐색 | 명령 완료·다중 keg 수정이 포함된 SHA `5d089548…` 실행 경로와 PID 94390 확인. 실제 설치 150개·업데이트 95개·Homebrew 7.0.7, 설치 검색 `git` 한 건 2.54.0, Home→⌘F→Discover의 `jq` 입력·뒤로 복귀 확인. 변경 명령 실행 없이 종료 및 프로세스 부재 확인 |
| Home→Discover→git 상세→뒤로 2회 | Discover와 Home으로 순서대로 복귀 |
| Home에서 첫 ⌘F | 최신 Release에서 검색창에 포커스하고 추가 클릭 없이 직접 입력 가능. 화면 생성 직후 같은 호출에 붙인 입력이 한 번 누락됐던 초기 전환의 초고속 입력은 추가 확인 필요 |
| 설치 목록 조건 보존 | 검색 `qa`, Cask, Updates only 적용 후 상세 왕복 시 세 조건과 결과 1개 유지 |
| 선택 업데이트 | git/qa-app 두 항목 선택→각 2.0. gettext는 1.0 유지. Activity에 두 Completed와 출력 표시 |
| 대기 작업 취소 | git Running, qa-app Waiting→Cancel. git 완료 후에도 qa-app Cancelled·1.0 유지, git만 2.0 |
| Formula 삭제 취소 | 확인창에서 Cancel 후 git 유지, Activity `No operations yet.` |
| Cask 데이터 삭제 취소 | 공유 데이터 경고와 Cancel 확인. Cask 1.0과 설치 수 3 유지 |
| Homebrew 미설치 | 오류 알림 닫기→Connect Homebrew·Retry Connection→설치 3개/업데이트 2개 복구 |
| 오프라인 | 캐시 4개 유지, Refresh로 오류 시도 1→2, `jq` 검색 가능 |
| 정보 조회 실패 | 원래 전역 알림이 팝오버를 닫는 결함 재현. 수정 후 오류/재시도 버튼 유지, 닫고 다시 열면 버전 1.0 표시. 동일 팝오버의 재시도 버튼 성공은 미확인 |
| 검색·필터 스크롤 회귀 | 단계별 입력에서 검색·종류·기간 변경 후 첫 행·스크롤 0 확인. 빠른 합성 스크롤과 클릭을 같은 호출에 보낸 경우는 별도 확인 필요 |
| 검색 최적화 단계 Release 강제 새로고침 | Catalog와 Formula/Cask popularity 시각이 모두 3:23 PM으로 갱신 |
| 검색 최적화 단계 Release 실제 정보 조회 | `git-lfs` 버전 3.8.0과 홈페이지 표시, Escape로 닫기 |
| 라이트·표시 환경 | 라이트 화면·검색, `accessibility3` 값 수신·검색/뒤로/앞으로, 주입한 SwiftUI increased contrast·필터 동작 확인. 실제 OS 고대비·글꼴 확대 효과는 별도 미검증 |
| 실제 격리 설치·실패·재시도 | Formula/Cask/추가 Formula 세 건 Completed. 권한 제한 Formula는 Failed 후 복구·재시도 Completed, 실제 네 건 1.0과 일치 |
| 실제 격리 선택 업데이트 | 네 건 선택 후 Running/Waiting 직렬 실행 관찰. 세 건 2.0 Completed, 권한 제한 한 건 1.0 Failed. 실제 종료 코드 0/0/0/1 및 파일 상태와 일치. 긴 오류 출력의 스크롤과 Done 접근 확인 |
| 실제 격리 업데이트 재시도 | 남은 한 건 선택·재시도 후 Activity Completed, 이전 Failed 기록 유지. 업데이트 0, 실제 네 건 2.0과 일치 |
| 다중 keg 버전 표시 재검증 | 최신 모델의 새 격리 앱에서 구버전 Formula keg 세 개가 남아 있는 상태로 네 행의 2.0 표시를 AX·스크린샷과 snapshot 04로 대조. 부분 실패 시 permission만 1.0인 상태도 일치 |
| 실제 격리 cleanup | 미리보기에서 구버전 keg 세 개와 캐시 대상 표시, 예상/실제 출력 13.3KB. 실행 후 Activity Completed, Home 용량 24.5→12.4KB, 최신 네 건 유지 |
| 실제 격리 삭제 | Cask는 일반 Uninstall만 실행, 데이터 삭제 옵션 사용 안 함. 삭제마다 설치 수 4→3→2→1→0, 최종 빈 화면과 Activity 네 건 Completed. 실제 inventory 빈 배열·Cellar 0·Cask 앱 제거 확인 |

모의 앱에서 실행한 업데이트와 취소는 메모리 안에서만 처리했다. 최초 보고서의 실제 설치 목록 조회·cleanup dry-run·그래프·좁은 창 검증도 유효하다. 이번 수동 동선 확인을 XCUITest 10개 실행 성공으로 표기하지 않는다. [표시 조건별 결과와 한계](display-conditions.md)에 실제 환경값과 적용되지 않은 고대비 시도까지 구분했다.

최종 실제 명령 연결 실행은 `/private/tmp/brewery-qa-io0m6z92/`의 임시 Homebrew와 로컬 네 패키지만 사용했다. snapshot 01→02→03의 Cellar는 7,136→10,849→17,985바이트, 캐시는 1,047→1,141→2,190바이트다. 업데이트 재시도 후 snapshot 04는 네 건 2.0, Cellar 21,698·캐시 2,284바이트였다. cleanup 후 snapshot 05는 최신 네 건을 유지하며 Cellar 10,849·캐시 1,144바이트로 감소했고 이전 keg 세 개가 제거됐다. 삭제 후 snapshot 06은 빈 inventory·Cellar 0·Cask 앱 없음·캐시 871바이트다. fresh cache가 남는 plain cleanup을 캐시 전체 삭제로 해석하지 않는다. [네이티브 격리 절차](native-homebrew-app.md)에 실행·종료 조건을 명시했다.

최종 실행의 앱 종료 후 `finish`는 **`namespace_verified`로 성공했다**. 빈 inventory·앱과 하위 프로세스 부재를 확인하고, 검증된 QA 고유 창 배치 설정 파일만 제거한 뒤 보호 경로 14개가 전후 동일함을 확인했다. 기존 Brewery 설정은 이번 실행 전에 보관한 원본과 바이트 단위로 동일했다. 임시 작업 디렉터리 제거와 제어 잠금 해제도 확인했다. 실제 앱 명령 이벤트 80개 중 변경 명령은 15개이며 의도한 권한 실패 두 건과 재시도 성공을 포함한다. `native-ui-observations.json`의 직접 관찰과 실제 명령 출력·snapshot을 함께 대조해 기능 및 환경 보존 통과로 판정했다. `result.json`, `native-finish-verification.json`에 종료 증거를 남겼다.

앞선 `/private/tmp/brewery-qa-5cq8e5hl/` 실행은 기능 시나리오를 마쳤지만 기존 Brewery 설정 지문 변화 때문에 `finish`가 정리를 거부했다. 다른 12개 보호 경로는 일치했고, QA 고유 설정 생성은 별도로 확인했다. 당시 기존 설정의 전후 내용이 없어 변경 원인을 확정할 수 없으므로 이 실패를 통과로 바꾸지 않았다. 설정 복원·기준 변경 없이 작업 디렉터리와 `native-finish-refusal-evidence.json`을 보존했다. 이후 다른 Brewery·테스트 앱을 함께 실행하지 않는 새 환경에서 위 최종 검사를 수행했다.

## 실제 검색 성능

같은 Mac·창·All/30일 조건에서 동일한 64개 검색 교체를 실행한 **검색 최적화 단계 Release**의 전후 기록이다. 완료된 binding→AppKit 창 갱신 구간은 89/94개이며, p50은 **164.38→89.18ms**, p95는 **379.48→140.02ms**, 최대값은 **493.19→152.63ms**로 줄었다. 검색과 겹친 Instruments 멈춤 표본은 **30→0개**였다. 검색 활성 구간의 메인 스레드 CPU 표본은 17,223→9,213ms로 감소했다. `rows()` 자체의 p95는 48.78→60.21ms여서 모든 계산이 개선됐다는 의미는 아니다. 이후 명령 완료 대기 수정은 다른 Release 바이너리로 검증했으며, 해당 검색·카탈로그 소스는 바뀌지 않았다.

최종 강제 새로고침에서는 캐시 읽기 4회·쓰기 2회(합계 165.73ms)와 정렬 인덱스 준비 1회(36.53ms)가 모두 worker에서 실행됐다. 캐시되지 않은 행 계산은 한 번(61.54ms)으로 줄었다. 이전의 접근성 조회와 무관한 549/533ms Hang은 이번 기록에서 나타나지 않았다. 최종 기록의 두 Microhang은 접근성 트리 조회가 대부분을 차지하므로 일반 새로고침 지연으로 귀속하지 않았다.

이는 한 장비에서 한 쌍의 검색 비교와 단일 새로고침 기록이며 입력 합쳐짐에 따라 완료 표본이 달라진다. 원시 키 입력→GPU 표시 지연이나 FPS가 아니다. 해당 Hitches 표는 0개지만 모든 상황의 프레임 무정지를 보장하지 않는다. 검색 최적화 단계의 바이너리로 재측정을 완료했으며 중간 후보는 별도 기록으로 구분했다. 이후 명령·설치 버전 수정이 포함된 최신 Release는 시작·검색 동선을 확인했으나 새 성능 trace를 기록하지 않았다. 정확한 입력 순서, 산출법, 원본 기록과 제한은 [성능 측정 기록](discover-performance.md)에 정리했다.

## 환경 및 남은 Task

| Task | 상태 / 다음 완료 조건 |
|---|---|
| **QA-01 · P2 실제 명령과 Activity 연동** | **완료**: 최신 코드로 설치·일부 실패·설치/업데이트 재시도·cleanup·삭제를 실제 파일/Activity와 대조. 구버전 keg 잔존 시 최신 버전 표시 확인. 최종 보호 경로 14개 일치·기존 설정 내용 동일·임시 작업 정리 완료. 이전 실패 증거는 별도 보존 |
| **QA-02a · P2 지원 OS/CPU** | ARM64 macOS 26.6.2 직접 실행 완료. macOS 13 / Intel 실기 실행은 가능한 호스트가 없어 대기. Universal 컴파일로 대체하지 않음 |
| **QA-02b · P2 접근성·표시 환경** | 다크·좁은 창·라이트 확인. SwiftUI 고대비·큰 글자 환경값의 배치/조작 확인. 실제 OS 고대비·글꼴 확대, VoiceOver, 키보드만으로 전체 동선은 미완료. 최초 검색 전환 직후 입력, 정보 팝오버 성공 재시도, 빠른 관성 스크롤 중 필터 변경 재확인 포함 |
| **QA-03 · P2 UI CI 최초 실행** | 코드·타깃·CI·빌드 완료. 실제 UI runner와 호스팅 CI의 첫 실행 결과가 필요. 사용자가 로컬 검증만 선택했으므로 원격 실행은 이번 작업 범위에서 제외 |
| **PERF-01 · P3 남은 성능 범위** | 검색 최적화 Release 검색 64회와 강제 새로고침 계측 완료. p95 140.02ms, 검색과 겹친 멈춤 표본 0, 캐시·정렬 준비 off-main 확인. 긴 실패 출력의 스크롤·완료 버튼 접근은 확인했으며 해당 화면의 성능·GPU 표시·지원 환경별 지표는 별도 검증 |

## 증거 위치

임시 로그는 `/private/tmp/brewery-qa-completion/` 아래에 있어 시스템 정리 시 사라질 수 있다. 지속 보관할 결과와 미확인 범위는 이 문서에 남겼다.

- `package-info-local-errors-red.log`: 수정 전 관련 7개 테스트 실패.
- `cache-executor/off-main-red.log`: 새 실행 스레드 검증 3개가 수정 전 실패.
- `cache-executor/post-isolation-unit.xcresult`, `post-isolation-unit.log`: 캐시 이동 단계 122개 테스트 통과, 관련 5개 소스의 전후 해시 일치.
- `cache-executor/review-typecheck.log`: strict concurrency 및 warnings-as-errors 통과.
- `search-index/final-verification.1wMoMh/`: 검색 최적화 단계 전체 앱 strict 빌드와 127개 unit, 입력 68개 파일의 전후 해시 일치.
- `index-list-final/`: 검색 성능 측정에 사용한 UI·Universal Release 빌드(`*-strict-setter-build`), xcresult, 입력 35개 파일 해시, 아키텍처·fixture 제외·ad-hoc 서명 검사.
- `command-execution-tests/full-unit-strict-verified-summary.json`, `full-unit-strict-verified.log`, `full-unit-strict-verified.xcresult`: 명령 완료 수정 단계 strict XCTest **133개 통과**. `verification-history.json`에 해당 소스 해시와 앞선 컴파일 오류·수정 이력을 구분했다.
- `command-completion-final/`: 명령 완료 수정 단계의 UI 타깃·Universal Release, 입력 35개 해시 일치와 fixture·서명 검사. 해당 Release SHA-256은 `21a038c2bf5cd0f33260435f251821519cbf360f880f2a2a48ef555795d88316`.
- `multi-keg-regression/`: 모델 수정 전 실패 기록과 최신 `full-strict-green-summary.json`, `.log`, `.xcresult`의 **141개 통과**. 제품·단위 테스트 입력 51개 해시 불변.
- `installed-version-final/`: 최신 `ui-final`·`release-final` 빌드와 xcresult, 입력 35개 해시 일치·fixture 제외·서명 검사. Release SHA-256 `5d089548feb0c8af185b883aa7f85aa846f27e3c993aa07d7810155b5fa3d297`. `release-runtime-observations.json`에 실제 실행 경로·화면 동선·종료를 기록했다. UI 종료 처리 수정 전 strict 컴파일 실패는 `ui-strict-red.log`로 보존했다.
- `native-safety-final/tests-approved.log`, `verification-approved.json`: 현재 QA 도구 소스의 안전성 테스트 22개 통과와 입력 해시 일치. 앞선 sandbox의 ps 차단은 별도 실패 로그로 보존했다.
- `command-wait-review/`: 종료 대기 정지 독립 재현, 같은 스레드 대조군, 실제 제품 helper의 500회 반복·동시 출력·실행 실패·신호 종료 검증.
- `native-qa-batch-running-sample.txt`: 수정 전 실제 앱의 종료 대기 정지 스택.
- `/private/tmp/brewery-qa-io0m6z92/`: 최신 모델·실행기의 최종 네이티브 QA. `native-snapshot-01~06.json`, `native-command-events.jsonl`, `native-ui-observations.json`, `result.json`, `native-finish-verification.json`. 보호 경로 14개 일치, 정상 설정 내용 동일, 임시 작업 정리 성공.
- `display-qa/`: 임시 표시 조건 앱의 런타임 값과 적용 실패 시도까지 보존한 기록.
- `release-script-final.log`: 125개 릴리스 검사.
- `isolation/run-pdyipla7/result.json`: 실제 격리 실행, 29개 명령·15개 검증·보호 경로 지문.
- `search-controlled.trace`, `search-index-final.trace`: 동일 입력의 최초/최종 비교 및 각 XML·JSON 분석 결과. `search-final.trace`는 파일명과 달리 중간 후보 기록이다.
- `search-refresh.trace`, `search-refresh-background.trace`, `refresh-index-final.trace`: 최초·캐시 이동·최종 일괄 적용 단계의 강제 새로고침 기록.
- `search-interaction.trace`, `search-interaction-stop.json`: 긴 SwiftUI 그래프 후처리를 중단한 최초 시도. 성능 통과 근거에서 제외.

## 원래 작업 폴더 반영

최종 검증 후 이전 56개 파일의 SHA-256과 원래 작업 폴더를 다시 비교해 후속 14개 파일을 충돌 없이 반영했다. 마지막 네이티브 재검증 후에는 결과 문서 5개만 추가 동기화했다. 감사·구현 전체의 변경/추가 파일 61개가 검증한 worktree와 바이트 단위로 일치한다. 앞선 백업은 `/private/tmp/brewery-qa-completion/pre-native-integration/`, 마지막 문서 백업은 `pre-local-final-integration/`이며 반영 기록은 `native-integration.json`, `final-local-integration.json`, `integrated-manifest.json`에 있다. 기존 작업 내용은 보존했다. 제품·테스트 변경 없이 UI/Release 입력 35개와 단위 테스트 입력 51개의 해시가 두 작업 폴더 모두 검증 시점과 같음을 다시 확인했다.

사용자의 **“로컬 검증까지만 진행”** 선택에 따라 커밋·push·PR·배포 및 CI dispatch는 하지 않았다. 지원 환경·실제 UI CI 등 미실행 항목은 통과로 간주하지 않고 후속 Task로 남겼다.
