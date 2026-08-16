# Brewery Discover Design

**Date:** 2026-08-16
**Status:** Approved for implementation planning

## Summary

Brewery will add a Discover destination that combines a locally searchable Homebrew package catalog with Homebrew's published Formula and Cask install rankings. The screen must render immediately from bundled or cached data, remain useful offline, and refresh stale data in the background without blocking interaction.

The first version intentionally excludes categories. Maintaining a separate category taxonomy would add recurring manual work without being necessary for package discovery.

## Goals

- Let users browse popular Formulae and Casks over 30, 90, and 365 days.
- Search the full package catalog by name and description without spawning `brew search`.
- Show package description, latest version, install count, kind, and installed state in one list.
- Reuse Brewery's existing package preview and install flows.
- Show useful data immediately, including when the network is unavailable.
- Refresh catalog and ranking data safely in the background.

## Non-goals

- Manually curated or automatically inferred package categories.
- Personalized recommendations.
- Historical charts, velocity calculations, or trend sparklines.
- GitHub popularity, ratings, reviews, or third-party package metadata.
- Replacing Homebrew as the authority for installation, removal, or package details.

## User Experience

### Navigation

The sidebar gains fixed `Home` and `Discover` destinations above the installed Cask and Formula sections. Main navigation changes from a nullable package-name string to a typed destination:

```swift
enum AppDestination: Hashable {
    case home
    case discover
    case package(name: String)
}
```

The existing toolbar Search action navigates to Discover and focuses its search field. The standalone Search screen is removed after its behavior is covered by Discover.

### Discover screen

The default state shows the 30-day popularity ranking across all package kinds. Controls provide:

- a local name-and-description search field;
- an `All / Formula / Cask` kind filter;
- a `30 / 90 / 365 days` ranking-window filter.

Each row shows:

- rank when ranking data exists;
- package name and description;
- Formula or Cask kind;
- latest version;
- install count when ranking data exists;
- current installed state;
- `Info`, `Install`, or `View`, depending on state.

An installed package navigates to the existing installed-package detail. An uninstalled package uses the existing `PackagePreviewView`; installation remains available inline. A successful install reloads installed packages and updates the affected row without discarding the current Discover query or filters.

The footer presents a subtle refresh state and the last successful update time. Background refresh never replaces usable content with a blocking spinner.

## Architecture

### Components

#### `CatalogService` actor

Owns catalog and analytics I/O:

- load the normalized bundled catalog;
- load and validate disk caches;
- fetch current Homebrew catalog and analytics data;
- normalize remote payloads into Brewery's internal models;
- write cache files atomically;
- enforce cache time-to-live rules.

The actor does not own view state and does not call `brew`.

#### `DiscoverViewModel`

A `@MainActor ObservableObject` that owns:

- the full normalized catalog returned by `CatalogService`;
- Formula/Cask rankings for each requested time window;
- search query and selected filters;
- refresh and recoverable-error state;
- the derived, sorted rows presented by `DiscoverView`.

The view model receives installed Formula and Cask identifiers from `BreweryViewModel` and derives each row's installed state. It keeps catalog/network concerns out of the existing `BreweryViewModel`.

#### `DiscoverView`

Renders controls, result rows, refresh status, empty states, and package actions. It does not parse network responses or access cache files.

#### Catalog build script

A repository script fetches Homebrew's official `formula.json` and `cask.json` and emits the normalized catalog resource included in the app bundle. The generated resource contains only fields required by Discover, reducing app size and runtime decoding work.

The generated catalog is committed so normal app builds do not require network access. Refreshing the bundled snapshot is an explicit maintainer action, not part of every Xcode build.

### Internal models

```swift
enum PackageKind: String, Codable, Hashable {
    case formula
    case cask
}

struct CatalogPackage: Codable, Identifiable, Hashable {
    let name: String
    let kind: PackageKind
    let description: String?
    let homepage: URL?
    let latestVersion: String?

    var id: String { "\(kind.rawValue):\(name)" }
}

enum RankingWindow: String, CaseIterable, Codable {
    case days30
    case days90
    case days365
}

struct PackageRanking: Codable, Hashable {
    let packageID: String
    let installs: Int
    let rank: Int
}
```

Network response types remain private to `CatalogService`. UI code depends only on normalized internal models.

## Data Sources

### Catalog

- Formulae: `https://formulae.brew.sh/api/formula.json`
- Casks: `https://formulae.brew.sh/api/cask.json`

The bundled snapshot is always the final fallback. A newer valid disk cache takes precedence.

### Popularity

- Formulae use Homebrew's `install-on-request` analytics so dependency-only installs do not dominate the user-facing ranking.
- Casks use Homebrew's `cask-install/homebrew-cask` analytics.
- Each source is requested for 30-day, 90-day, or 365-day windows as selected.

Examples:

- `https://formulae.brew.sh/api/analytics/install-on-request/30d.json`
- `https://formulae.brew.sh/api/analytics/cask-install/homebrew-cask/30d.json`

Formula and Cask rankings are normalized to the same internal type and merged only after their respective package kind is known.

## Loading and Refresh Flow

1. Load the bundled normalized catalog.
2. Validate the disk catalog cache and use it if it is newer than the bundled snapshot.
3. Load cached analytics for the default 30-day window.
4. Publish Discover content immediately.
5. If the catalog cache is older than 24 hours, refresh Formula and Cask catalog sources in the background.
6. If analytics for the selected window is older than 1 hour, refresh both Formula and Cask analytics in the background.
7. Normalize and validate complete responses before publishing them.
8. Write valid data to a temporary file and atomically replace the prior cache.
9. Preserve the current search query, filters, and scroll context when refreshed data arrives.

Selecting a ranking window loads its valid cached analytics immediately when available, then applies the same one-hour refresh policy.

## Cache Storage

Discover cache files live in Brewery's Application Support directory, separate from command logs. Cache metadata records schema version, source timestamp, and successful fetch time.

Cache rules:

- catalog TTL: 24 hours;
- analytics TTL: 1 hour per ranking window;
- unknown schema version: discard and fall back;
- invalid JSON or failed validation: discard and fall back;
- partial catalog refresh: do not replace the previous complete cache;
- failed Formula or Cask analytics refresh: keep the corresponding prior cached ranking.

## Search and Sorting

Search is local, case-insensitive, and diacritic-insensitive. It matches package name first and description second.

- With an empty query, packages with ranking data sort by rank. Unranked catalog packages follow alphabetically.
- With a query, exact-name matches come first, followed by name-prefix matches, remaining name matches, and description-only matches.
- Kind filtering occurs before sorting.
- Installed state changes row actions but does not change rank.

This deterministic ordering is testable and avoids relevance changing because of network timing.

## Command Execution Safety

Discover introduces remote catalog identifiers into an installation path. As a scoped prerequisite, `BreweryCommand` must stop constructing `/bin/zsh -c "brew ..."` strings.

The command runner will resolve the supported Homebrew executable and pass arguments through `Process.executableURL` and `Process.arguments`. Package names remain separate arguments and are never interpreted by a shell. The runner returns a typed result containing stdout, stderr, and termination status so Discover can accurately distinguish install success from failure.

Existing install, uninstall, update, cleanup, and package-info calls migrate to the same typed runner. User-visible behavior stays unchanged except for more accurate errors.

## Error Handling

- **Bundled catalog missing or invalid:** show a blocking Discover-specific error because no usable source remains; other Brewery features continue working.
- **Disk cache invalid:** ignore it, record a diagnostic log entry, and use the bundled resource.
- **Network refresh fails:** keep current data and show a non-blocking refresh message with the last successful timestamp.
- **Only one remote source succeeds:** do not replace a complete catalog with a partial one; analytics may update per kind while the other kind retains stale data.
- **Ranking has no matching catalog entry:** omit the orphan ranking entry and log a diagnostic count.
- **Catalog package has no ranking:** keep it searchable and display no rank or install count.
- **Install fails:** restore the row action, retain the user's filters, and show a concise error derived from stderr.
- **Repeated install request:** disable the action while that package identifier is already in `installingPackages`.
- **Cancellation or app termination during cache write:** the prior cache remains intact because replacement is atomic.

## Testing

### `CatalogService` tests

- bundled catalog decoding;
- valid newer cache precedence;
- corrupt cache fallback;
- unsupported cache schema fallback;
- 24-hour catalog and one-hour analytics TTL boundaries;
- Formula and Cask response normalization;
- partial-refresh protection;
- atomic cache replacement;
- stale data retention after network failure.

Network tests use an injected `URLSession` backed by `URLProtocol` mocks and never call live Homebrew endpoints.

### `DiscoverViewModel` tests

- name and description matching;
- case and diacritic normalization;
- kind filtering;
- ranking-window changes;
- ranking and alphabetical fallback order;
- exact-name and prefix relevance order;
- catalog/ranking merge;
- installed-state merge;
- query and filter preservation after refresh;
- duplicate-install prevention.

### Command runner regression tests

- argument boundaries are preserved without shell interpretation;
- stdout, stderr, and exit status remain distinct;
- existing read and write commands construct the expected argument arrays.

### App verification

- build the macOS app with the supported Xcode toolchain;
- run the unit-test suite;
- manually verify Discover from bundled data while offline;
- manually verify background catalog and analytics refresh;
- manually verify Formula and Cask installation from Discover;
- smoke-test existing package detail, update, cleanup, uninstall, logs, and settings flows.

## Acceptance Criteria

- Discover shows bundled content before any network request completes.
- Users can browse 30-, 90-, and 365-day Formula/Cask rankings.
- Users can search all bundled packages by name or description without executing `brew search`.
- The list accurately reflects packages installed during the current session.
- Network and cache failures never erase a previously usable dataset.
- Category data and category-management UI are absent.
- Package installation does not pass through a shell.
- Existing package-management features continue to work.
