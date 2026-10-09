<p align="center">
  <img src="Brewery/Assets.xcassets/AppIcon.appiconset/256.png" width="128" />
</p>

# Brewery

A macOS GUI app for managing Homebrew packages.

<p align="center">
  <img width="500" alt="image" src="https://github.com/user-attachments/assets/89799551-1e5e-46bb-9878-e8ef100d82ad" />
</p>

## Features

- **Package management** — Search and filter installed Formula and Cask packages, view package details, and install or uninstall packages.
- **Search** — Find new packages with popularity rankings, period filters, and offline access to cached catalog data.
- **Updates** — Review available package updates and upgrade selected packages, with configurable update checks and exclusions.
- **Dependency graph** — Explore formula dependencies in an interactive graph.
- **Activity** — Track package operations, inspect command output, and cancel waiting tasks.
- **Homebrew maintenance** — Refresh package definitions and preview cleanup before removing cached files.
- **Personalization** — Customize appearance, startup behavior, notifications, and language (English or Korean), and manage logs and diagnostics in Settings (`⌘,`).

<p align="center">
  <img width="500" alt="image" src="https://github.com/user-attachments/assets/4905c3de-1818-4f4b-b4e1-89c0fd70b31b" />
</p>

## Brewery app updates

Use **Brewery → Check for Brewery Updates…** or **Settings → Updates** to
check, download, install, and relaunch through Sparkle. The existing automatic
Brewery release-check setting checks daily while the app is open. Installing
an update requires a user action. Relaunch waits for queued Homebrew operations;
new mutations are blocked once relaunch begins.

Older releases without Sparkle must be replaced manually once with the first
Sparkle-enabled release. Subsequent releases can update in the app. The update
feed becomes available when that first release is published; development code
alone does not publish it.

Release preparation generates `appcast.xml` from the notarized, stapled DMG,
signs the update with the `brewery-sparkle` Keychain account, and verifies it.
The public key lives in `Configuration/Brewery-Info.plist`; never commit or
export the private key. Publication uploads both the DMG and `appcast.xml` to
the same GitHub Release. The stable feed URL uses
`releases/latest/download/appcast.xml`. Keep build numbers increasing for every
release, and preserve the signing key for future updates.

## Requirements

- macOS 13.0+
- [Homebrew](https://brew.sh) installed at `/opt/homebrew/bin/brew` (Apple Silicon) or `/usr/local/bin/brew` (Intel)

## Changelog

### 1.0.5
- Added confirmation dialog before uninstalling Formula and Cask packages
- Added Settings window (Cmd+,) with log file management (view size, open, clear)
- Fixed layout issues on smaller screens (13-inch and below)
