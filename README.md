<p align="center">
  <img src="Brewery/Assets.xcassets/AppIcon.appiconset/256.png" width="128" />
</p>

# Brewery

A macOS GUI app for managing Homebrew packages.

<p align="center">
  <img width="500" alt="image" src="https://github.com/user-attachments/assets/89799551-1e5e-46bb-9878-e8ef100d82ad" />
</p>


## Features

- Manage and update installed packages
- Search for new packages
- Install and uninstall packages
- Homebrew self-update support

<p align="center">
  <img width="500" alt="image" src="https://github.com/user-attachments/assets/4905c3de-1818-4f4b-b4e1-89c0fd70b31b" />
</p>

## Requirements

- macOS 13.0+
- [Homebrew](https://brew.sh) installed at `/opt/homebrew/bin/brew`


## Privacy

Brewery sends one anonymous event, `app_started`, each time it launches. That's the only
event it sends — it exists so I can tell how many people use the app and which versions of
macOS to keep supporting.

Each event includes:

- the event name and timestamp
- Brewery's version and build number
- the OS name and version (e.g. `macOS 15.3.1`)
- the Mac model identifier (e.g. `Mac14,9`)
- the language code (e.g. `ko`)
- the Aptabase SDK version
- a random session ID that is regenerated after an hour of inactivity

The event carries no name, email, IP address, or persistent identifier, and nothing at
all about the packages you install, search for, or remove.

Events go to [Aptabase](https://aptabase.com), an open source, privacy-first analytics
service. Like any HTTP request, the upload itself reveals your IP address to their
servers; their [privacy policy](https://aptabase.com/legal/privacy) covers what they do
with it.

**To turn it off:** Settings (⌘,) ▸ Privacy ▸ uncheck *Send anonymous usage statistics*.
It takes effect on the next launch.

## Changelog

### 1.0.6
- Added anonymous launch analytics, with an opt-out in Settings ▸ Privacy

### 1.0.5
- Added confirmation dialog before uninstalling Formula and Cask packages
- Added Settings window (Cmd+,) with log file management (view size, open, clear)
- Fixed layout issues on smaller screens (13-inch and below)
