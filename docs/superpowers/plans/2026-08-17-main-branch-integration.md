# Main Branch Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove anonymous launch analytics and integrate `refactor` plus every local `codex/*` branch into a clean, tested local `main`.

**Architecture:** Preserve the current uncommitted work in focused commits before changing branches, revert the dedicated analytics commit on `main`, then merge each branch with explicit merge commits. Resolve conflicts by composing the reliability, dependency graph, and Discover behavior while treating the analytics-free state as authoritative.

**Tech Stack:** Git, Swift 5, SwiftUI, XCTest, Xcode/macOS, zsh release automation

## Global Constraints

- Do not push, tag, publish a release, delete branches, or delete worktrees.
- Do not commit `.superpowers/` runtime artifacts.
- Keep the dependency graph and release automation in separate commits.
- Preserve all `refactor` reliability changes, Formula dependency graph behavior, and Discover behavior.
- The final `main` must contain no Aptabase dependency, telemetry source, analytics setting, launch event, or analytics documentation.

---

### Task 1: Preserve the Formula Dependency Graph

**Files:**
- Modify: `Brewery.xcodeproj/project.pbxproj`
- Modify: `Brewery.xcodeproj/xcshareddata/xcschemes/Brewery.xcscheme`
- Modify: `Brewery/View/BreweryDetailVeiw.swift`
- Modify: `Brewery/model/BrewViewModel.swift`
- Create: `Brewery/DependencyGraph/DependencyGraphModels.swift`
- Create: `Brewery/DependencyGraph/DependencyGraphStore.swift`
- Create: `Brewery/DependencyGraph/DependencyGraphView.swift`
- Create: `Brewery/DependencyGraph/DependencyNodeView.swift`
- Create: `Brewery/DependencyGraph/DependencyTreeLayout.swift`
- Create: `Brewery/DependencyGraph/DependencyViewport.swift`
- Create: `BreweryTests/DependencyGraphFixtures.swift`
- Create: `BreweryTests/DependencyGraphStoreTests.swift`
- Create: `BreweryTests/DependencyTreeLayoutTests.swift`
- Create: `BreweryTests/DependencyViewportTests.swift`
- Create: `docs/superpowers/specs/2026-08-16-dependency-graph-design.md`
- Create: `docs/superpowers/plans/2026-08-16-formula-dependency-graph.md`

**Interfaces:**
- Consumes: `BreweryFormula`, `BreweryViewModel.fetchPackageInfo(name:isCask:)`, and `BreweryDetailView.onNavigate`.
- Produces: `DependencyGraphView.init(root:loader:onNavigate:)` and `BreweryViewModel.resolveFormulaForDependencyGraph(name:) async throws -> BreweryFormula`.

- [ ] **Step 1: Run the focused dependency graph tests**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/DependencyGraphStoreTests -only-testing:BreweryTests/DependencyTreeLayoutTests -only-testing:BreweryTests/DependencyViewportTests
```

Expected: exit 0 with all focused tests passing. If this pre-existing uncommitted implementation fails, stop and diagnose before committing it.

- [ ] **Step 2: Check the graph diff and stage only graph-related files**

Run:

```bash
git diff --check
git add Brewery.xcodeproj/project.pbxproj Brewery.xcodeproj/xcshareddata/xcschemes/Brewery.xcscheme Brewery/View/BreweryDetailVeiw.swift Brewery/model/BrewViewModel.swift Brewery/DependencyGraph BreweryTests/DependencyGraphFixtures.swift BreweryTests/DependencyGraphStoreTests.swift BreweryTests/DependencyTreeLayoutTests.swift BreweryTests/DependencyViewportTests.swift docs/superpowers/specs/2026-08-16-dependency-graph-design.md docs/superpowers/plans/2026-08-16-formula-dependency-graph.md
git diff --cached --check
```

Expected: the staged diff contains no release scripts, `.agents`, `.superpowers`, or duplicate remediation plan.

- [ ] **Step 3: Commit the graph**

```bash
git commit -m "feat: add interactive formula dependency graph"
```

Expected: one focused feature commit on `codex/formula-dependency-graph`.

### Task 2: Preserve Release Automation Separately

**Files:**
- Modify: `.gitignore`
- Create: `.agents/skills/brewery-release/SKILL.md`
- Create: `.agents/skills/brewery-release/agents/openai.yaml`
- Create: `scripts/release.sh`
- Create: `scripts/release_lib.sh`
- Create: `scripts/tests/release_test.sh`

**Interfaces:**
- Consumes: clean local `main`, semantic version input, Xcode signing identity, `brewery-notary` Keychain profile, and authenticated `gh` CLI.
- Produces: `zsh scripts/release.sh prepare <VERSION>` and `zsh scripts/release.sh publish <VERSION>`.

- [ ] **Step 1: Ignore local runtime artifacts**

Add this exact entry to `.gitignore` next to the local AI/release entries:

```gitignore
.superpowers/
```

- [ ] **Step 2: Run release-script tests**

```bash
zsh scripts/tests/release_test.sh
```

Expected: exit 0 and zero failed assertions.

- [ ] **Step 3: Stage only release automation and ignore rules**

```bash
git add .gitignore .agents/skills/brewery-release scripts/release.sh scripts/release_lib.sh scripts/tests/release_test.sh
git diff --cached --check
```

Expected: `.superpowers/` is ignored and no runtime artifact or duplicate remediation document is staged.

- [ ] **Step 4: Commit release automation**

```bash
git commit -m "chore: add verified Brewery release workflow"
```

Expected: one focused release-tooling commit.

### Task 3: Commit This Implementation Plan

**Files:**
- Create: `docs/superpowers/plans/2026-08-17-main-branch-integration.md`

**Interfaces:**
- Consumes: `docs/superpowers/specs/2026-08-17-main-branch-integration-design.md`.
- Produces: the exact integration and verification sequence used by Tasks 4-7.

- [ ] **Step 1: Self-review the plan**

Run:

```bash
rg -n 'T''BD|T''ODO|implement lat''er|fill in det''ails|Similar to Ta''sk' docs/superpowers/plans/2026-08-17-main-branch-integration.md
git diff --check -- docs/superpowers/plans/2026-08-17-main-branch-integration.md
```

Expected: `rg` finds no placeholders and `git diff --check` exits 0.

- [ ] **Step 2: Commit the plan only**

```bash
git add docs/superpowers/plans/2026-08-17-main-branch-integration.md
git commit -m "docs: plan main branch integration"
```

Expected: the plan is committed separately from product and release automation.

### Task 4: Remove Anonymous Analytics from Main

**Files:**
- Delete: `Brewery/util/BreweryTelemetry.swift`
- Delete: `Brewery.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` if it contains only Aptabase resolution introduced by `ad8dc9e`
- Modify through revert: `Brewery.xcodeproj/project.pbxproj`
- Modify through revert: `Brewery/Brewery.entitlements`
- Modify through revert: `Brewery/BreweryApp.swift`
- Modify through revert: `Brewery/View/SettingsView.swift`
- Modify through revert: `README.md`

**Interfaces:**
- Consumes: dedicated analytics commit `ad8dc9e`.
- Produces: an analytics-free `main` without changing unrelated app behavior.

- [ ] **Step 1: Confirm the current feature branch is clean except ignored artifacts**

```bash
git status --short --branch
git worktree prune --dry-run
```

Expected: no tracked or non-ignored feature work remains; the stale `refactor` worktree metadata may be reported as prunable.

- [ ] **Step 2: Switch to local main and record its original head**

```bash
git switch main
git rev-parse HEAD
```

Expected: the original head is `faed1c9` unless another in-scope commit has advanced it.

- [ ] **Step 3: Revert the analytics commit**

```bash
git revert ad8dc9e
```

Expected: a new revert commit removes the full Aptabase integration without touching the Discover design commits that follow it.

- [ ] **Step 4: Prove analytics are absent**

```bash
test ! -e Brewery/util/BreweryTelemetry.swift
rg -n -i 'Aptabase|BreweryTelemetry|app_started|analyticsEnabled|anonymous launch analytics' Brewery Brewery.xcodeproj README.md
```

Expected: the file test succeeds and `rg` returns no matches.

### Task 5: Merge Refactor Reliability Work

**Files:**
- Merge and resolve as reported by Git, primarily `Brewery.xcodeproj/project.pbxproj`, `Brewery.xcodeproj/xcshareddata/xcschemes/Brewery.xcscheme`, `Brewery/model/BrewViewModel.swift`, and affected SwiftUI views.

**Interfaces:**
- Consumes: branch `refactor` at `59b0e4f`.
- Produces: safe direct Homebrew process execution, structured command failures, Formula/Cask identities, crash-safe parsing, accurate outdated state, UI polish, and associated tests.

- [ ] **Step 1: Remove only stale worktree administration if required**

```bash
git worktree prune
```

Expected: only the already-missing `/private/tmp/brewery-refactor-review` registration is pruned; no branch or live worktree is deleted.

- [ ] **Step 2: Merge refactor explicitly**

```bash
git merge --no-ff refactor -m "merge: integrate refactor reliability improvements"
```

Expected: either a merge commit or conflicts limited to overlapping project, model, and UI files.

- [ ] **Step 3: Resolve conflicts compositionally and validate the merge**

For every conflict, retain the analytics-free `main` state and preserve every `refactor` behavior listed in the task interface. Then run:

```bash
git diff --check
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS'
```

Expected: all tests pass before continuing.

### Task 6: Merge Formula Graph and Discover

**Files:**
- Merge and resolve as reported by Git, primarily the Xcode project/scheme, `Brewery/model/BrewViewModel.swift`, `Brewery/View/BreweryDetailVeiw.swift`, navigation views, and Discover files.

**Interfaces:**
- Consumes: `codex/formula-dependency-graph` and `codex/discover`.
- Produces: the tested Formula dependency graph plus Homebrew Discover catalog and rankings on top of refactor reliability behavior.

- [ ] **Step 1: Merge the Formula dependency graph branch**

```bash
git merge --no-ff codex/formula-dependency-graph -m "merge: integrate formula dependency graph"
```

Expected: preserve the graph, release workflow, and integration documentation without restoring analytics.

- [ ] **Step 2: Merge Discover**

```bash
git merge --no-ff codex/discover -m "merge: integrate Homebrew Discover"
```

Expected: preserve Discover UI/data behavior while keeping the refactored command API and Formula graph integration.

- [ ] **Step 3: Validate composed behavior after conflict resolution**

```bash
git diff --check
rg -n -i 'Aptabase|BreweryTelemetry|app_started|analyticsEnabled|anonymous launch analytics' Brewery Brewery.xcodeproj README.md
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS'
```

Expected: no analytics matches and all tests pass.

### Task 7: Final Verification

**Files:**
- Verify only; no additional production changes unless a failing check reveals an integration defect.

**Interfaces:**
- Consumes: fully merged local `main`.
- Produces: evidence that the final result is clean, buildable, tested, analytics-free, and contains all requested branch heads.

- [ ] **Step 1: Build the app**

```bash
xcodebuild build -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS'
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Run every test suite**

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS'
zsh scripts/tests/release_test.sh
```

Expected: Xcode tests and release-script tests both exit 0.

- [ ] **Step 3: Verify ancestry and repository state**

```bash
git merge-base --is-ancestor refactor main
git merge-base --is-ancestor codex/formula-dependency-graph main
git merge-base --is-ancestor codex/discover main
git status --short --branch
git log --oneline --decorate --graph -20
```

Expected: all ancestry checks exit 0 and local `main` is clean, with only expected divergence from `origin/main`.
