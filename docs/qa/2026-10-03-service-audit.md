# Brewery 서비스 점검 및 개발 Task

2026년 10월 3일 KST 기준, 현재 작업 폴더의 코드와 직접 실행한 macOS 앱을 점검했다. 기본 조회·검색·상세 화면·의존성 탐색은 동작하지만, Discover의 데이터 일관성과 설치 목록의 오류 처리를 먼저 개선해야 한다. 디자인에서는 업데이트 대상에 빠르게 접근하는 동선이 가장 부족하다.

최초 검토 기준은 커밋 `7fabaf8`과 기존 미커밋 내비게이션 변경사항이다. 최초 감사는 코드 수정 없이 진행했고, 이후 사용자의 진행 지시에 따라 개선을 구현했다. 아래 감사 내용은 최초 관찰 기록이며 최신 Task 상태와 검증 결과는 [개선 구현 및 QA 결과](2026-10-03-implementation-progress.md)를 참고한다. T01~T12, T14~T16은 구현 완료했고, T13과 T17은 후속 QA·계측이 남아 있다.

**QA 실행 결과**

| 검사 | 결과 | 범위와 증거 |
| --- | --- | --- |
| Debug 빌드 및 XCTest | 48개 통과, 실패 0 | Xcode 26.6, Swift 6.3.3, macOS 26.6.2, arm64, unsigned |
| 릴리스 스크립트 | 125개 검증 통과 | 외부 명령을 모의 실행하는 기존 테스트 |
| 카탈로그 생성기 | 2개 통과 | 정규화·결정성·스키마 검증 |
| zsh 문법 검사 | 통과 | release.sh, release_lib.sh, release_test.sh |
| Home 및 설치 목록 | 조회 정상 | 150개 설치, 95개 outdated 표시. 카드에서 대상 목록 이동은 불가 |
| Discover 검색 | 기본 동작 정상 | git 이름 검색, 없는 검색어, Clear Filters, Cask 필터, 90일 전환 |
| Discover 순위 | 결함 확인 | All 목록에서 gh와 codex 모두 1위로 표시 |
| 검색 버튼 포커스 | 결함 재현 | 상세 → 툴바 Discover → 입력은 반영되지 않음. 버튼 재클릭 후에는 반영 |
| 패키지 상세 | 조회 정상 | git Formula, ghostty Cask, 미설치 Cask 정보 팝오버, More info |
| 의존성 그래프 | 기본 조작 정상 | git → gettext 확장, json-c/libunistring 표시, 120% 확대, 100% 리셋 |
| 뒤로가기 | 정상 | ⌘[로 Discover 복귀, 검색어 유지 |
| 삭제 확인 | 확인창·취소 정상 | Formula 삭제, Cask 데이터 포함 삭제. 실제 삭제는 실행하지 않음 |
| 설정 | 기본 동작 정상 | ⌘,로 열기, 로그 크기 표시, 로그 삭제 확인창 취소 |
| 작은 창 | 부분 개선 필요 | Home 콘텐츠 유지. Discover 최소 폭 부근에서 Period가 Peri-/od로 줄바꿈 |
| 오류·비동기 재현 검사 | 4개 결함 확인 | 지연 응답, 부분 실패, 설치 JSON 오류, tap 이름 불일치에 mock 입력 사용 |

기존 자동 검사 합계는 175개이며, 별도의 결함 재현 검사는 이 숫자에 포함하지 않았다. 앱 호스트를 사용하는 XCTest의 실행 줄 커버리지는 33.18%다. 앱 시작만으로 실행된 줄도 포함하므로 사용자 동작의 검증률로 해석하면 안 된다. 특히 DiscoverViewModel의 로딩·검색·기간 변경과 CatalogService의 네트워크 동작에는 기존 테스트의 행위 검증이 없다.

실제 패키지 설치·삭제·업그레이드·cleanup·Homebrew update, 라이트 모드, 트랙패드 제스처, VoiceOver 전체 사용 흐름, Intel 및 macOS 13 실기기, 서명된 Release 배포는 검증하지 않았다. 삭제 기능은 확인창을 취소하는 범위까지만 실행했다. 초기 sandbox 빌드는 Swift Preview 매크로의 실행 환경 문제로 실패했고, 같은 명령을 승인된 환경에서 재실행해 성공했다.

**우선순위 기준**

P2는 다음 개발 주기에 우선 처리할 정확성·주요 사용성 문제, P3는 후속 정리·세부 사용성 개선이다. 재현된 결함, 코드로 확인한 미개발 부분, 제품 개선 제안을 각 Task에 구분했다. 예상 소요 시간은 구현·정책 선택에 따라 달라지므로 임의로 확정하지 않았다.

- [x] **T01 · P2 · 기간 변경 시 이전 통계가 적용되는 문제 수정**

  재현된 결함. 30일 통계를 불러오는 동안 90일로 변경하면 화면은 90일을 선택하지만 30일 응답이 적용된다. mock 재현 결과는 `selected=90d requests=["30d"] displayedInstalls=[30, 30]`였다. [DiscoverViewModel.swift](/Users/wonjae/Swift/Brewery/Brewery/Discover/DiscoverViewModel.swift:31)의 실행 중 요청 처리와 응답 적용이 원인이다.

  완료 조건: 지연된 이전 요청이 현재 기간의 결과를 덮어쓰지 않고 마지막으로 선택한 기간을 반드시 조회한다. 30 → 90 → 365일 연속 선택과 역순 응답 테스트가 통과한다.

- [x] **T02 · P2 · 부분 새로고침 실패 시 성공했던 통계 유지**

  재현된 결함. Formula 갱신 성공·Cask 갱신 실패 시 기존 Cask 설치 수가 사라진다. 재현 결과는 `git=31, firefox=nil`이었다. [CatalogService.swift](/Users/wonjae/Swift/Brewery/Brewery/Discover/CatalogService.swift:65)가 실패한 종류를 nil로 반환하고 [DiscoverViewModel.swift](/Users/wonjae/Swift/Brewery/Brewery/Discover/DiscoverViewModel.swift:74)가 전체 통계를 교체한다.

  완료 조건: 같은 기간에서 종류별 마지막 성공 데이터를 유지한다. 실패한 종류와 마지막 성공 시각을 표시하고, 전체 실패·한 종류 실패 모두 기존 목록을 보존한다.

- [x] **T03 · P2 · 카탈로그 갱신과 기간별 캐시 구현**

  코드로 확인한 미개발 부분. 번들에는 2026-08-16 생성된 16,249개 패키지가 있으며 [CatalogService.swift](/Users/wonjae/Swift/Brewery/Brewery/Discover/CatalogService.swift:54)의 카탈로그 갱신 함수는 nil만 반환한다. 새로고침 버튼은 인기 통계만 갱신한다. 앱이 관리하는 통계 디스크 캐시도 없다. 따라서 번들에 없는 새 패키지를 찾을 수 없고, 오프라인 재시작 시 저장된 인기순을 복원하지 못한다.

  완료 조건: 기존 설계의 카탈로그 24시간·통계 1시간 TTL, 기간·종류별 캐시, 스키마 검증, 원자적 저장, 번들 fallback을 구현한다. 갱신 시각을 보여주고 검색어·필터를 유지한다. 새 패키지 반영, 손상 캐시, 오프라인 재시작, 일부 소스 실패를 테스트한다.

- [x] **T04 · P2 · tap을 포함한 패키지 식별자 통일**

  재현된 결함. 설치 목록은 짧은 이름으로 저장하지만 outdated 응답의 `owner/tap/tool`을 그대로 비교한다. 재현 결과는 `outdatedCount=1`, `tool`의 outdated=false, `owner/tap/tool`의 outdated=true였다. 실제 UI는 짧은 이름을 사용하므로 영향을 받는 패키지가 Latest로 표시되고 Update 버튼을 잃는다. [BrewViewModel.swift](/Users/wonjae/Swift/Brewery/Brewery/model/BrewViewModel.swift:163)와 [설치 목록 구성](/Users/wonjae/Swift/Brewery/Brewery/model/BrewViewModel.swift:181)이 근거다.

  완료 조건: kind와 tap을 포함한 정규 식별자를 설치·outdated·명령·그래프·진행 상태에서 일관되게 사용한다. core/tap 동명 Formula와 Formula/Cask 동명 패키지를 테스트한다.

- [x] **T05 · P2 · 목록과 정보 로딩 실패를 정상 빈 상태와 구분**

  설치 목록 오류는 재현된 결함이다. 정상 종료 코드와 잘못된 JSON을 반환했을 때 `alert=false installed=0`이었다. [BrewViewModel.swift](/Users/wonjae/Swift/Brewery/Brewery/model/BrewViewModel.swift:175)는 디코딩 실패를 콘솔에만 출력한다. [패키지 정보 조회](/Users/wonjae/Swift/Brewery/Brewery/model/BrewViewModel.swift:290)도 디코딩 실패를 nil로 반환해 미리보기에서 unknown으로 끝날 수 있다. 후자는 코드로 확인했으며 UI 오류 주입은 하지 않았다.

  완료 조건: loading·loaded·failed 상태를 구분하고 마지막 성공 목록과 오류 안내·재시도를 함께 제공한다. 미리보기 실패도 정보 없음과 구분한다. 정상 빈 목록·명령 실패·형식 변경·잘못된 JSON을 각각 테스트한다.

- [x] **T06 · P2 · 전체 인기순의 순위와 숫자 의미 정리**

  화면에서 확인한 결함. All 목록은 설치 수로 섞어 정렬하지만 종류별 원래 순위를 그대로 보여준다. gh 1위 다음 여러 Formula가 나오고 codex Cask도 1위로 표시됐다. [DiscoverViewModel.swift](/Users/wonjae/Swift/Brewery/Brewery/Discover/DiscoverViewModel.swift:57)가 원본 rank를 유지한다.

  완료 조건: All은 통합 순위를 다시 계산하고 종류별 화면은 해당 종류 순위를 보여준다. 검색 시의 순위가 전체 인기순인지 검색 결과 순번인지 명시한다. 설치 수 열에는 제목과 기간을 제공해 숫자의 의미를 알 수 있게 한다.

- [x] **T07 · P2 · 설치 목록 검색과 업데이트 대상 필터 추가**

  제품 개선 제안. 실제 환경의 설치 패키지 150개가 사이드바에 나열되지만 검색·outdated 필터·목록 새로고침이 없다. [SideBarView.swift](/Users/wonjae/Swift/Brewery/Brewery/View/SideBarView.swift:29)에서 전체 항목을 직접 나열한다. 터미널에서 변경한 설치 상태를 가져오기 위한 명시적 동선도 필요하다.

  완료 조건: 설치된 패키지 이름 검색, 전체/업데이트 필요 필터, 종류별 개수와 새로고침을 제공한다. 선택한 패키지가 사라졌을 때 빈 상세 화면에 머물지 않는다. 직접 설치와 의존성 설치 구분은 후속 확장으로 검토한다.

- [x] **T08 · P2 · Home을 업데이트 작업으로 연결**

  제품 개선 제안. Home은 95개의 업데이트 필요 상태를 보여주지만 카드가 클릭되지 않고 대상 목록·선택 업데이트가 없다. 인접한 Brew Update는 `brew update`를 실행하며 패키지 업그레이드는 각 상세의 `brew upgrade`에서 수행한다. [HomeView.swift](/Users/wonjae/Swift/Brewery/Brewery/View/HomeView.swift:39), [명령 실행](/Users/wonjae/Swift/Brewery/Brewery/model/BrewViewModel.swift:188), [Homebrew 명령 문서](https://docs.brew.sh/Manpage#update-up-options)가 근거다.

  완료 조건: Outdated 카드에서 T07의 대상 목록으로 이동한다. Homebrew 갱신과 패키지 업데이트를 명확한 이름·설명으로 구분한다. T09 구현 후 선택 업데이트와 패키지별 성공·실패 요약을 제공한다.

- [x] **T09 · P2 · 패키지 작업 상태와 충돌 제어를 공통화**

  코드로 확인한 개발 공백이며 실제 동시 설치 충돌은 재현하지 않았다. 설치·업데이트·삭제·cleanup이 서로 다른 플래그를 사용하고, [BreweryCommand.swift](/Users/wonjae/Swift/Brewery/Brewery/util/BreweryCommand.swift:27)는 분리된 프로세스의 출력을 종료까지 모은다. 긴 작업의 단계·출력·취소를 UI에서 확인하기 어렵다.

  완료 조건: PackageID 기준 공통 작업 상태와 충돌 정책을 정의하고 중복 요청을 막는다. 작업 진행·로그·성공·실패를 화면에 제공한다. 취소는 하위 프로세스와 패키지 상태를 고려해 지원 가능한 단계에서만 제공한다. 성공·실패·중복 클릭·다른 창의 동시 요청은 모의 명령으로 검증한다.

- [x] **T10 · P2 · Cleanup의 대상과 결과를 표시**

  제품 개선 제안과 코드로 확인한 상태 갱신 공백. Home의 Cleanup은 설명 없이 바로 실행되고 성공 후 Homebrew 용량을 다시 조회하지 않는다. [HomeView.swift](/Users/wonjae/Swift/Brewery/Brewery/View/HomeView.swift:53), [BrewViewModel.swift](/Users/wonjae/Swift/Brewery/Brewery/model/BrewViewModel.swift:205)가 근거다. Homebrew는 [cleanup --dry-run](https://docs.brew.sh/Manpage#cleanup-options-formulacask-)을 지원한다.

  완료 조건: 정리 예정 항목·확보 예상 용량을 미리 보여주고 실행 후 결과와 실제 용량을 갱신한다. 실제 사용자 파일을 삭제하지 않는 fixture 기반 QA를 만든다. Cask 데이터 포함 삭제는 고급 동작으로 유지하고, 다른 앱과 공유된 파일에도 영향을 줄 수 있음을 경고에 반영한다. 이 동작은 [Homebrew uninstall 문서](https://docs.brew.sh/Manpage#uninstall-remove-rm-options-installed_formulainstalled_cask-)로 확인했다.

- [x] **T11 · P3 · 검색 진입 포커스와 좁은 화면 레이아웃 수정**

  두 항목 모두 직접 재현했다. 다른 화면 → 툴바 Discover → 입력은 검색에 반영되지 않지만 동일 버튼 재클릭 후에는 반영된다. [DiscoverView.swift](/Users/wonjae/Swift/Brewery/Brewery/View/DiscoverView.swift:75)는 focusRequest 변경만 관찰하고 새 화면 생성 시 초기 요청을 처리하지 않는다. 작은 창에서는 종류·기간 Picker가 한 줄의 폭을 경쟁해 Period가 Peri-/od로 나뉜다.

  완료 조건: 첫 진입부터 입력 포커스를 제공하고 ⌘F 동작을 일관되게 정의한다. 좁은 폭에서는 필터를 두 줄로 배치하거나 라벨·컨트롤을 재구성한다. 키보드만으로 검색·필터·결과의 정보 보기까지 접근 가능하도록 검증한다.

- [x] **T12 · P2 · 같은 패키지의 메타데이터 변경 시 그래프 갱신**

  코드로 확인한 수명주기 문제이며 실제 패키지 업그레이드로 재현하지 않았다. [BreweryDetailVeiw.swift](/Users/wonjae/Swift/Brewery/Brewery/View/BreweryDetailVeiw.swift:114)는 그래프 identity를 이름만으로 지정하고, [DependencyGraphView.swift](/Users/wonjae/Swift/Brewery/Brewery/DependencyGraph/DependencyGraphView.swift:20)는 처음 받은 root로 StateObject를 만든다. 같은 패키지의 의존성 정보가 바뀌어도 기존 store가 남는다.

  완료 조건: 같은 이름의 새로운 root metadata를 반영하고 기존 비동기 요청을 정리한다. 새 의존성 표시와 사라진 노드 제거를 mock으로 검증한다. 확대·펼침 상태 보존 범위를 정하고 화면 이동 시 불필요한 조회도 정리한다.

- [ ] **T13 · P2 · 주요 사용자 동작의 회귀 테스트 보강**

  기존 테스트 결과로 확인한 공백이다. 그래프 모델 테스트는 비교적 충분하지만 Discover와 실제 작업 흐름의 검증이 부족하다. XCTest 실행 중 38개의 warning 행이 있었고, 그중 34개는 Swift 6 언어 모드에서 문제가 되는 테스트의 actor 격리 경고였다.

  완료 조건: T01~T06, 설치·삭제·업데이트 실패와 중복 실행을 mock 기반으로 자동 검증한다. Home → Discover → 상세 → 뒤로가기, 검색 포커스, 삭제 취소는 UI 테스트에 추가한다. 테스트 actor 격리 경고를 정리한다. macOS 13/Intel·라이트 모드·접근성·네트워크 실패를 별도 릴리스 QA 행렬에 포함한다.

- [x] **T14 · P2 · Homebrew 미설치 및 연결 문제의 시작 화면 제공**

  코드로 확인한 개발 공백이며 Homebrew가 설치된 현재 환경에서 실패 화면을 재현하지 않았다. 실행 파일을 찾지 못하면 [BreweryCommand.swift](/Users/wonjae/Swift/Brewery/Brewery/util/BreweryCommand.swift:31)가 127 오류를 반환한다. 제품에는 정상 설치 0개와 연결 실패를 구분하는 전용 안내 화면이 없다.

  완료 조건: 실행 파일 확인 후 연결됨·미설치·실행 실패를 구분한다. 공식 설치 안내와 재시도를 제공하며 준비되지 않은 상태에서 패키지 작업을 실행하지 않는다. 지원 경로와 macOS 요구사항을 README와 일치시킨다.

- [x] **T15 · P3 · 사용하지 않는 CLI 검색 코드 제거**

  불필요 코드 후보로 확인했다. Discover가 카탈로그를 직접 검색하고, [BrewViewModel.swift](/Users/wonjae/Swift/Brewery/Brewery/model/BrewViewModel.swift:279)의 search 함수·searchResults·isSearching·출력 파서는 앱 코드에서 호출되지 않는다. SearchResult에는 테스트 참조만 남아 있다.

  완료 조건: 현재 제품에서 사용하지 않는 함수·상태·모델과 해당 기능만 검증하는 테스트를 정리한다. tap 검색 fallback을 제품 기능으로 채택한다면 별도 명시적 요구사항과 UI·테스트로 연결한다. 무조건 두 검색 경로를 유지하지 않는다.

- [x] **T16 · P3 · 중복 내비게이션과 정보 표현 단순화 검토**

  디자인 제안이며 사용률 데이터에 근거한 제거 결정은 아니다. 사이드바와 툴바에 Home/Discover가 반복되고, Discover 아이콘도 safari와 magnifyingglass로 다르다. Home의 총 설치 수와 Formula/Cask 개수는 같은 정보를 큰 카드 여러 개로 표현한다. 설정은 현재 로그 기능만 있다.

  완료 조건: 사이드바는 목적지, 툴바는 검색·새로고침 등 현재 화면 행동을 담당하도록 정리한다. 통계는 간결한 요약으로 줄이고 업데이트 대상에 공간을 배분한다. 로그는 진단 영역으로 명확히 묶는다. More info와 의존성 그래프는 고급 사용자에게 가치가 있으므로 삭제 확정 대상으로 분류하지 않는다. 그래프는 목록/펼치기 기본값을 사용성 검증 후 결정한다.

- [ ] **T17 · P3 · 검색 성능을 계측하고 반복 계산 축소**

  성능 개선 후보다. [DiscoverView.swift](/Users/wonjae/Swift/Brewery/Brewery/View/DiscoverView.swift:11)의 rows 계산은 [DiscoverViewModel.swift](/Users/wonjae/Swift/Brewery/Brewery/Discover/DiscoverViewModel.swift:49)에서 전체 카탈로그 필터·문자 정규화·정렬을 MainActor에서 수행한다. 비최적화 독립 harness에서는 16,249개 대상으로 빈 검색 약 24ms, git/python 약 60ms가 걸렸다. 이 값은 앱의 실제 입력 지연을 측정한 값이 아니다.

  완료 조건: Release 빌드에서 입력과 목록 갱신 지연을 먼저 측정한다. 문제가 확인되면 검색용 정규화 문자열을 미리 만들고 입력·필터·통계 변경 시에만 결과를 재계산한다. 한글·대소문자·악센트·정렬 결과를 유지한다.

**권장 진행 순서**

T01·T02·T04·T05·T06의 정확성 문제와 회귀 테스트를 먼저 처리하고, T03의 데이터 갱신을 완성한다. 이후 T07·T08·T09를 연결해 업데이트 작업 동선을 만들고, T10·T12·T14의 운영 흐름을 보강한다. T11은 작은 독립 수정으로 앞당길 수 있다. T15~T17은 핵심 흐름 안정화 후 진행한다.

**원본 검증 기록**

- [자동 QA 명령과 결과](/private/tmp/brewery-audit-20261003/automated-qa.txt)
- [XCTest 결과 요약](/private/tmp/brewery-audit-20261003/test-summary.json)
- [Xcode 실행 로그](/private/tmp/brewery-audit-20261003/xcode-test-unsandboxed.log)
- [릴리스 스크립트 검증 로그](/private/tmp/brewery-audit-20261003/release-test.log)
- [카탈로그 생성기 검증 로그](/private/tmp/brewery-audit-20261003/catalog-generator-test.log)
- [독립 결함 재현 harness](/private/tmp/brewery-code-audit/Audit.swift)

원본 로그와 빌드 산출물은 임시 디렉터리에 있어 운영체제 정리 시 사라질 수 있다. 이 문서에 결과·재현 절차·근거 파일을 남겼다. 독립 harness는 실제 ViewModel 코드에 mock 서비스와 명령 실행기를 주입했으며, 컴파일 편의를 위해 제품의 네트워크 디코더를 제외했다. 따라서 그 결과를 네트워크·프로세스·화면 전체의 E2E 검증으로 해석하지 않는다.
