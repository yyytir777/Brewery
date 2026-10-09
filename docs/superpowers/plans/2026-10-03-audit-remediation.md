# Brewery Audit Remediation Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement and verify this plan. Independent Discover and graph work may follow dispatching-parallel-agents; the main agent integrates the user-facing flows.

**Goal:** Implement the accepted service audit Tasks and verify the changed macOS user flows.

**Architecture:** Preserve SwiftUI and the current typed Homebrew command boundary. Discover owns dated catalog/ranking caches and request identity. A shared app-level BreweryViewModel owns canonical installed package identity, connection/loading state, and serialized mutation history. Views consume this state and expose retry, filtered inventory, selected upgrades, and cleanup preview.

**Tech Stack:** Swift 5 language mode, SwiftUI, Foundation Process/URLSession, XCTest, macOS 13 minimum, no added dependencies.

**Spec:** docs/qa/2026-10-03-service-audit.md, accepted by the user's “진행해”; existing Discover and dependency graph specs supply cache TTL and graph constraints.

**Global Constraints**

- Preserve the six existing uncommitted navigation/audit files copied from the original workspace.
- No real install/uninstall/upgrade/cleanup during QA; use injected command runners and disposable cache fixtures.
- No publish, push, release, or merge requested. Return reviewable local edits and test evidence.
- Keep diagnostic details in diagnostics; show concise status/actions in the app.
- Cache TTL: catalog 24 hours, rankings one hour per source and period; preserve successful data during failures.

**Review Focus**

- Obsolete analytics responses must never replace the latest selected period (Task 1).
- Corrupt or partial data must not erase valid inventory/cache (Tasks 1–2).
- Qualified tap identities and Formula/Cask collisions must remain distinct (Task 2).
- Concurrent windows and repeated actions must not run conflicting package mutations (Task 2).
- Selection removal, first search focus, narrow windows, and failed command recovery must remain usable (Task 3).

- [x] **Task 1 — Discover correctness, persistence, and search cost (T01–03, T06, T17).** Own `Brewery/Discover/*` and corresponding tests. Retain the public service methods, add optional injected cache directory/clock, validate schemas and catalog identity, implement atomic cache writes and partial-source preservation. ViewModel uses request generation and per-window snapshots, recomputes cross-kind rank before search, and pre-normalizes searchable fields. Write delayed-response/partial-failure/cache TTL/offline tests, observe failures, implement, run the focused suite. Measure Release row evaluation before deciding optimization depth.

- [x] **Task 2 — Inventory identity, loading, operations, cleanup, and onboarding state (T04–05, T09–10, T14–15).** Own `Brewery/model/BrewViewModel.swift`, data/identity and command operation types plus tests. Formula `packageID` uses canonical full_name; all maps/actions use PackageID. Expose inventoryError, hasLoadedInventory, isHomebrewAvailable, activeOperation, operation history, `isOperating(_:)`, `upgradePackages(_:)`, `previewCleanup()` and cleanup output. Preserve prior inventory on decode failure, coalesce reloads, serialize mutations across a shared app model, allow cancellation of queued work only. Existing two-argument command runner remains injectable. Remove dead CLI search after its callers/test coverage are checked. Write malformed/tap/collision/duplicate/batch/cleanup tests before implementation.

- [x] **Task 3 — User flows and UI (T07–08, T10–11, T14, T16).** Own `Brewery/View/*`, app shared model, navigation model/tests. Add installed destination, search/filter/type controls, selection upgrades and explicit refresh; make Home counters link to it. Keep sidebar destinations and toolbar contextual search/refresh plus navigation history. Provide connection/retry state, command history, cleanup preview and result. Discover first focus and ⌘F, adaptive filters and metric labels. Preview has retry/error state. Real UI QA covers each flow; UI fixtures must never invoke real mutations.

- [x] **Task 4 — Graph metadata refresh (T12).** Own graph store/view and graph tests. Add `updateRoot(_:)` which replaces metadata and cancels/invalidate stale loads when dependency metadata changes. Reuse unchanged root state; reset viewport only when content changes. Test updated dependencies and stale load completion.

- [x] **Task 5 — Verification and delivery (T13).** Resolve test actor warnings, run complete XCTest and script suites, build Release, review the whole implementation with a fresh reviewer, fix actionable findings. Perform direct UI QA and record limitations (hardware/runtime unavailable). Update the audit checklist with completed/partial evidence. Integrate changes to original workspace only after comparing baseline hashes; preserve concurrent edits.

**Verification command**

`xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/brewery-implementation/DerivedData CODE_SIGNING_ALLOWED=NO test`

Expected: TEST SUCCEEDED, no failed tests. Focused red runs use `-only-testing:BreweryTests/<suite>` and a distinct log. Script checks use the existing 125 release assertions and 2 Python generator tests.

**Execution decisions**

- Native implementation with independent workers for disjoint Discover/graph work, followed by one whole-change reviewer. The accepted audit already states concrete behavior and completion criteria; repeated approval would add no new decision.
- Active Homebrew mutations cannot safely be interrupted at arbitrary installation phases. Show phase/output and permit removing waiting batch items; explain active completion rather than exposing an unsafe stop button.
- Keep the existing graph and raw information as advanced features. Consolidate navigation and Home stats; do not delete useful diagnostics.
