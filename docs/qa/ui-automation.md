# UI regression automation

The `BreweryUI` shared scheme includes only `BreweryUITests`; `Brewery` remains the unit-test scheme. `Brewery.app` still targets macOS 13. Both test bundles target macOS 14 because current Xcode's XCTest framework has that minimum runtime. Running these suites on a newer Mac does not validate macOS 13 or Intel behavior.

## Isolation and coverage

Every test launches a fresh Debug app with `--brewery-ui-testing <scenario>`. The fixture owns an in-memory inventory and catalog, so commands cannot reach the user's Homebrew installation. Release builds ignore the fixture entry point. Launch arguments intentionally contain exactly the flag and scenario because the fixture rejects malformed input. The UI currently ships English labels; execute with an English system language for system-provided confirmation buttons.

| Test | Scenario | Expected observable result |
|---|---|---|
| Home → Discover → git detail → Back → Home | standard | Correct destinations restored |
| First ⌘F | standard | Typing at application level changes Discover query without clicking the field |
| Installed filters and detail round trip | standard | Query, Cask type, and updates-only filter retained |
| Select Available Updates | standard | git and qa-app become 2.0; gettext stays 1.0; both operations complete |
| Cancel waiting update | queue | qa-app stays 1.0 after git finishes; cancellation remains in Activity |
| Cancel Formula uninstall | standard | git remains installed; Activity remains empty |
| Cancel Cask data deletion | standard | qa-app remains installed; Activity remains empty |
| Missing Homebrew retry | missing-homebrew | Setup recovers to the three-package inventory |
| Package information retry | info-failure | jq popover keeps the error inline and recovers to version information without a global command-error dialog |
| Offline refresh | offline | Local catalog remains searchable after a failed refresh |

The queue fixture holds its first mutation until the Debug-only `fixture.completeOperation` button in Activity is pressed. The suite asserts Waiting, cancels the second operation, confirms the first is still Running, and then explicitly releases it before checking inventory. This avoids dependence on runner speed. The offline fixture includes a refresh attempt counter: the suite must observe attempt 1 become attempt 2 after Refresh, so an inert button cannot pass the test. Tests use bounded condition waits instead of sleeps. Failures attach a screenshot and accessibility hierarchy to the `.xcresult`.

## Commands

Compile without controlling the desktop:

```sh
xcodebuild -project Brewery.xcodeproj -scheme BreweryUI \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/brewery-qa-completion/ui-DD \
  -only-testing:BreweryUITests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build-for-testing
```

Execute on an unlocked, dedicated Mac desktop with Xcode UI automation enabled. Do not run while another user or agent is controlling the desktop. Use the same build settings and DerivedData as the build step. Pick a new result path for each run:

```sh
xcodebuild -project Brewery.xcodeproj -scheme BreweryUI \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/brewery-qa-completion/ui-DD \
  -resultBundlePath /private/tmp/brewery-qa-completion/ui-run.xcresult \
  -only-testing:BreweryUITests -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 90 \
  -maximum-test-execution-time-allowance 120 \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  test-without-building
```

Ad-hoc signing keeps the macOS UI runner signed without using a distribution identity. Unsigned universal Release builds are a separate CI job.

## CI contract and verification sources

`.github/workflows/qa.yml` has independent unit, UI, and universal Release jobs. The UI job builds and then executes `BreweryUITests` explicitly with parallel testing disabled, checks all 10 tests passed with zero skips, and uploads results even when a step fails. Per-step timeouts leave room for artifact upload before the job budget expires. Each upload keeps logs and `.xcresult` bundles for 14 days, including XCTest failure attachments. A cancelled workflow or unavailable runner can still prevent artifact upload.

Official sources checked on 2026-10-03:

- [GitHub-hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) lists `macos-15` as ARM64.
- [macOS 15 ARM64 image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md) includes Xcode 26.3 at `/Applications/Xcode_26.3.app`, while default Xcode is 16.4. CI explicitly selects 26.3.
- [Official runner provisioning](https://github.com/actions/runner-images/blob/main/images/macos/scripts/build/configure-machine.sh) enables developer mode and Xcode automation mode without authentication, then verifies that setting. This supports selecting the hosted Mac for XCUITest; it is not evidence that this particular suite has executed successfully. CI checks both the GUI launch session and automation-mode status and fails visibly if that assumption no longer holds. It does not modify TCC databases.
- [Checkout v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1) and [upload-artifact v7.0.1](https://github.com/actions/upload-artifact/releases/tag/v7.0.1) are verified released action versions used by this workflow.

## Execution evidence

The current retained verification on 2026-10-03 includes the process-completion and installed-keg selection fixes that followed the Discover performance changes. The evidence below separates executed unit tests, compiled UI tests, and the Release build. Compilation does not establish a UI-runner pass.

### Current unit, UI compile, and Release results

| Check | Retained result | Evidence directory under `/private/tmp/brewery-qa-completion/` |
|---|---|---|
| Full `Brewery` unit suite | 141 passed, 0 failed, 0 skipped; exit 0 | `multi-keg-regression/` |
| `BreweryUI` build-for-testing | `TEST BUILD SUCCEEDED`; exit 0; UI tests not executed | `installed-version-final/` |
| Universal Release | `BUILD SUCCEEDED`; exit 0; ad-hoc signed ARM64 + x86_64 | `installed-version-final/` |

All three used `SWIFT_STRICT_CONCURRENCY=complete` and `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`. The final logs contain zero Swift compiler warnings or errors. The only metadata notices were skipped AppIntents extraction: unit suite 2, UI compile 2, final incremental Release 0. The unit run was on macOS 26.6.2 ARM64; these results do not validate Intel execution or the macOS 13 runtime.

The 141-test result supersedes the earlier 133-test run. Eight JSON-decoding regressions cover the real multi-keg inventory shape, linked-keg precedence, absent/null/dangling links, nullable receipt times, timestamp ties, and an empty installed array. Before the model fix, the targeted parsing run recorded seven failed test methods (16 failure records, including three null-time decoding errors). After the fix, the full suite passed in 5.980 seconds. This verifies model selection behavior, not the retained multi-keg scenario in the native UI.

Unit evidence in `multi-keg-regression/`:

- `full-strict-green.log`, `full-strict-green.exit`, and `full-strict-green.xcresult`: the full strict unit run.
- `full-strict-green-summary.json`: 141 passed, 0 failed, 0 skipped.
- `verification.json`, `green-source-inputs.json`, and `final-hashes.sha256`: RED/GREEN history and 51 unchanged product/test/project/scheme input hashes.
- `red-nullable.log`, `red-nullable.xcresult`, and `red-BreweryData.swift`: the pre-fix failures and model source retained for comparison.

The strict UI compile first exposed actor-isolation errors in synchronous teardown: accessing the app, capturing its screenshot, terminating it, and clearing the app reference crossed the main-actor boundary. That failed compile is preserved as `installed-version-final/ui-strict-red.{log,exit,xcresult}` (exit 65). The teardown correction changed only `BreweryUITests.swift` between those build-input manifests. The subsequent `ui-final` compile passed strict checks. This is compile-time verification of the correction; failure-attachment capture and teardown have not been exercised by the UI runner.

Current build evidence in `installed-version-final/`:

- `ui-final.log`, `ui-final.exit`, and `ui-final.xcresult`: final strict UI compile, exit 0.
- `ui-DD/Build/Products/BreweryUI_BreweryUI_macosx26.5-arm64.xctestrun`: exactly one UI test target, `BreweryUITests`, with `UITargetAppPath` pointing to `Brewery.app`.
- `release-final.log`, `release-final.exit`, and `release-final.xcresult`: final strict Universal Release build, exit 0.
- `release-DD/Build/Products/Release/Brewery.app`: the ad-hoc-signed Universal Release artifact for native QA; CI's Release job remains unsigned.
- `artifact-validation.log` and `release-signature.log`: strict deep signature verification of the UI runner and Release app, architecture checks, deployment floors, and fixture exclusion.
- `source-manifest.json`, `ui-inputs-before.json`, `ui-inputs-after.json`, `release-inputs-before.json`, and `release-inputs-after.json`: the same 35 source/project/scheme hashes across the final UI and Release builds.
- `release-executable-sha256.txt`: current Release executable SHA-256, `5d089548feb0c8af185b883aa7f85aa846f27e3c993aa07d7810155b5fa3d297`.

The current model SHA-256 is `559e2804f9434f4b5eec9cd116d35b52833ef749a24656bca8c7e65756d22bf2`; the compiled UI test source SHA-256 is `440bf195bc110e48aff358018d70fbba1fb8e1c6d87a99b0910f06eef4bb650e`. Both are recorded in the current build manifests.

Recorded deployment floors remain macOS 13.0 for the app and 14.0 for the UI bundle. Both Release slices were checked separately for seven fixture markers: `BreweryUITestFixture`, `BreweryUITestScenario`, `BreweryUITestLaunchConfiguration`, `--brewery-ui-testing`, `fixture.completeOperation`, `UI Test Fixture Error`, and `Brewery UI fixture`. None were present. The Debug code contained the launch flag and queue-completion gate as positive controls, and built bundles had no fixture-scenario plist override.

### Historical performance and separate manual QA

The `index-list-final/` strict-setter builds and Release executable `98d38ad3604d1a59b736bffcb8606101e27fb7d7fb0c21ac0cd743af7ae07ca7` are historical performance-stage artifacts. They predate the process-completion and installed-keg fixes and are not the current Release artifact. Their logs, source manifests, earlier revision-guard/setter manifests, and `final-hashes.sha256` remain available for tracing that measurement stage.

`installed-version-final/performance-scope-verification.json` compares the measured and current inputs. The Discover view model, Discover view, and catalog service hashes remain identical across those builds, but the complete Release binary changed from `98d…` to `5d089…`. The retained performance capture belongs to the earlier executable; no new performance trace of the current executable is recorded in that evidence. Source equivalence for those three files is not a fresh whole-app performance measurement.

`installed-version-final/release-runtime-observations.json` separately records a read-only manual smoke check of the current `5d089…` Release: Home inventory, Installed search, first Command-F to Discover search, and Back navigation. It records no package mutation, no new performance trace, and no native retained-multi-keg verification. Broader native QA and environment-matrix results belong to the main QA report. Earlier manual observations of combined accessibility text in confirmation dialogs, Homebrew setup, and the Home update summary informed the UI test matchers.

Local configuration checks parsed workflow YAML, checked embedded shell steps with `bash -n`, validated the project with `plutil`, and confirmed each shared scheme contains only its intended test bundle. The retained results are in `/private/tmp/brewery-qa-completion/final-verification/ci-validation.log`.

The UI suite has not been run locally during this implementation; native manual QA used the same desktop. CI configuration is authored locally only: no workflow dispatch, push, PR, or remote CI run was performed. Treat UI-runner coverage and the first hosted run as pending until an `.xcresult` reports all 10 UI tests executed and passed. These temporary artifact paths are not committed evidence bundles.
