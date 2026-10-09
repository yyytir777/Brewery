# 표시 조건별 네이티브 QA

2026-10-03 · Apple M5 Pro / macOS 26.6.2. 제품 소스를 복사한 Debug 앱을 CUA로 직접 조작했다. 화면·모델 소스는 그대로 두고 복사본의 App 구성에서만 모의 데이터와 표시 조건을 주입했다. 사용자 시스템 설정은 변경하지 않았다.

## 결과와 검증 범위

| 조건 | 실제 환경값 / 관찰 | 판정 범위 |
|---|---|---|
| 라이트 | SwiftUI `light / standard / large`, 진단 일치. Home 화면, 첫 ⌘F의 검색 포커스, `jq` 검색 결과 확인 | 확인한 화면에서 겹침·잘림 미관찰 |
| 큰 글자 값 | `light / standard / accessibility3`, 진단 일치. Home·Discover·`git` 검색, ⌘[로 Home 복귀·⌘]로 검색 조건 유지 복귀 | 환경값 수신과 배치 확인. macOS에서 실제 글꼴 크기가 확대됐다는 근거는 확보하지 못했으므로 OS 글자 확대 QA 통과로 간주하지 않음 |
| 공개 AppKit 고대비 설정 | App 초기화와 창 생성 후 재적용을 각각 시도했으나 실제 `NSAppearanceNameAqua`, SwiftUI `standard` | 두 시도 모두 고대비 미적용. 통과 근거에서 제외 |
| SwiftUI 고대비 주입 | 복사본 App에만 `\._colorSchemeContrast = .increased` 적용. 진단 `light / increased / large` 일치. Discover의 검색 포커스, Cask·365일 필터, `qa-app` 1건과 기간 헤더 일치 확인 | 화면 요소 구분 가능, 겹침 미관찰. 내부 환경키를 사용한 QA 분기 확인이며 실제 OS/AppKit 고대비·VoiceOver 검증이 아님 |
| 정보 조회 실패 | 최신 제품 코드의 `info-failure`에서 `jq` Info 오류·Try Again 유지, 전역 alert 없음 | 동일 팝오버의 Try Again 성공 전환은 미확인. 좌표 입력 후 포인터는 버튼 위에 있었지만 상태가 바뀌지 않았고, Tab 포커스도 부모 목록에 남았다. UI 도구의 팝오버 입력 전달 제한이 의심되며 제품 결함으로 단정하지 않음 |

스크린샷은 도구 출력으로 직접 검토했다. 팝오버 일부가 부모 창의 캡처 경계 밖에 있는 것은 실제 팝오버 잘림의 증거로 사용하지 않았다. 이 검사는 색상 대비 비율 측정이나 키보드만으로 모든 기능을 수행한 검사가 아니다.

## 빌드 및 증거

- 제품·프로젝트 입력 69개 파일의 해시가 준비 전후 동일했다. 복사본은 App 구성만 달라졌다.
- Debug 빌드 3회 성공, Swift 경고 0. QA 앱 6개의 strict ad-hoc 서명과 바이너리 해시를 확인했다.
- 각 앱은 고유 bundle ID를 사용하며 모의 시나리오 키가 없거나 잘못되면 실제 Homebrew로 넘어가지 않는다.
- `/private/tmp/brewery-qa-completion/display-qa/README.md`: 앱 경로, 구성 변경 diff, 빌드와 실행 범위.
- `final-preparation-validation.json`, `source-manifest.json`, `apps-manifest*.json`: 입력·앱 검증.
- `diagnostics/light.json`, `diagnostics/light-accessibility3.json`: 라이트·큰 글자 환경값.
- `diagnostics/light-increased-contrast.json`, `diagnostics/public-window/light-increased-contrast.json`: 공개 AppKit 고대비 시도의 미적용 결과.
- `diagnostics/swiftui-injected/light-increased-contrast.json`: 최종 SwiftUI 고대비 환경값. `constructedHighContrastAppearance`도 Aqua였으며 앱·창의 실제 appearance는 Aqua로 유지됐다.

임시 파일은 시스템 정리 시 사라질 수 있다. 위 판정과 미검증 범위는 이 문서에 보존한다. 실제 OS 고대비·글자 확대, VoiceOver, 전체 키보드 동선은 별도 인수 Task다.
