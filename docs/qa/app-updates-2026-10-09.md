# Brewery in-app updates — 2026-10-09

## Implemented

- Pinned Sparkle 2.10.0 via Swift Package Manager, embedded in Brewery.
- Settings and app menu open Sparkle's check/download/install/relaunch flow.
- Existing opt-in daily release scheduler now invokes Sparkle instead of the
  GitHub JSON version check. Sparkle's independent scheduler is disabled.
- Downloads/installations require user action. Standard Sparkle UI handles
  progress, errors, skipped releases, cancellation, permissions and replacement.
- Pending Homebrew operations postpone relaunch; a synchronous admission
  reservation prevents new mutations after restart is requested. Abort clears
  the reservation. Test/UI fixture launches do not start the updater.
- Public key and HTTPS feed in Configuration/Brewery-Info.plist. Private key
  generated in macOS Keychain under brewery-sparkle; never exported.
- Release prepare validates source/export public keys, signs the final stapled
  DMG and generates appcast.xml. Both assets enter the strict preparation
  manifest, publication preview, tamper checks, upload and readback validation.

## Verification

- New postponement tests failed before implementation; now pass.
- Relaunch admission race regression failed before its guard; now passes.
- Full Brewery unit suite: 167 passing tests. Strict Swift concurrency and
  warnings-as-errors enabled. Xcode emitted only its usual AppIntents metadata
  notice (app does not use AppIntents).
- Release shell suite: 150 tests, zero failures. Includes mismatched/missing
  keys, generation/signature failure, changed feed and reordered asset checks.
- Real temporary DMG: official generate_appcast succeeded with the Keychain
  key; release helper accepted generated metadata; sign_update accepted the
  original bytes and rejected the altered DMG.
- Built bundle contains Sparkle.framework and all expected SU configuration.
- Info.plist and English/Korean strings pass plutil; git diff --check passes.
- Independent review: initial P2 relaunch admission race fixed and re-reviewed;
  no remaining P0/P1/P2 findings.

## Release boundary

No commit, tag, push, GitHub release, notarization submission, or replacement
of the user's installed app was performed. The temporary DMG is an ad-hoc test
artifact, not a release. End-to-end installation between two Developer ID
signed/notarized releases remains a release acceptance check. Publish the first
Sparkle-enabled release with both DMG and appcast.xml, install it manually once,
then verify its upgrade to the following signed build (including cancel/error
and busy-queue cases). Existing installed versions cannot gain an updater
without that initial manual replacement.
