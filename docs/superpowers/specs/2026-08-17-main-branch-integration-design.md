# Main Branch Integration Design

## Goal

Remove anonymous app-launch analytics, preserve the completed work on every local `codex/*` branch and `refactor`, and integrate that work into local `main` with a buildable, tested result.

## Scope

The integration includes:

- The uncommitted Formula dependency graph implementation, its `BreweryTests` coverage, Xcode test target, existing design document, and implementation plan.
- The uncommitted Brewery release automation scripts and their repository-local `brewery-release` skill, committed separately from the dependency graph.
- All committed changes from `refactor`, `codex/formula-dependency-graph`, and `codex/discover`.
- Complete removal of the anonymous launch analytics introduced by commit `ad8dc9e`, including Aptabase integration, launch tracking, opt-out settings UI, analytics documentation, package resolution, and analytics-only entitlements.

The integration excludes:

- `.superpowers/brainstorm` runtime state and generated browser artifacts. The `.superpowers/` directory will be ignored rather than committed or deleted.
- A duplicate untracked copy of `docs/superpowers/plans/2026-07-27-findings-remediation.md`; the tracked copy will arrive from `refactor`.
- Remote pushes, tags, releases, branch deletion, and worktree deletion.

## Commit Boundaries

Before switching away from `codex/formula-dependency-graph`, preserve its uncommitted work in focused commits:

1. Commit the interactive Formula dependency graph, test target, tests, design, and implementation plan.
2. Commit the release scripts, release-script tests, repository-local release skill, and related ignore rules.
3. Commit this integration design and its implementation plan separately from product code.

Temporary `.superpowers/` files remain local and ignored.

## Analytics Removal

On `main`, revert the dedicated analytics commit `ad8dc9e` instead of manually deleting individual fragments. This keeps the removal auditable and removes the Aptabase dependency, `BreweryTelemetry`, launch event dispatch, settings toggle, README disclosure, package lock entry, and analytics-only entitlement changes as one coherent operation.

Later branch merges must not restore those analytics files or project references. Conflict resolution will treat the analytics-free state as authoritative.

## Merge Strategy

Use explicit non-fast-forward merges so the origin of each body of work remains visible:

1. Start from local `main` and remove analytics.
2. Merge `refactor`, preserving its safe Homebrew command execution, error reporting, package identity, parsing, outdated-state, tests, and UI improvements.
3. Merge `codex/formula-dependency-graph`, preserving the dependency graph and release automation commits.
4. Merge `codex/discover`, preserving the Discover catalog and rankings.

When conflicts occur, resolve them by composing behavior rather than choosing one branch wholesale. The final application must retain `refactor` reliability improvements, the dependency graph, and Discover while remaining analytics-free.

## Verification

Before declaring the integration complete:

- Confirm no Aptabase package reference, telemetry source file, analytics setting, launch event, or analytics documentation remains.
- Run the Brewery Xcode test suite on macOS.
- Build the Brewery application with the shared scheme.
- Run `scripts/tests/release_test.sh` for the release automation.
- Inspect `git status`, the final branch graph, and the diff from the pre-integration `main` commit.

The final state is a local, clean `main`. No push is performed without a separate user request.
