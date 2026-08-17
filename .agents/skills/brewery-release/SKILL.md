---
name: brewery-release
description: Use when preparing, signing, notarizing, packaging, verifying, or publishing a Brewery macOS DMG release, including version bumps, GitHub release notes, Apple notarytool, stapling, and release recovery.
---

# Brewery Release

## Core contract

Use the repository scripts as the deterministic boundary. Keep judgment in
release-note drafting, and stop for explicit user approval before any commit,
tag, push, or GitHub Release mutation.

Read `RELEASE_AI.md` completely before acting. It is a local, gitignored
runbook containing fixed project values, credential setup, verification
requirements, and recovery rules. Never request, print, persist, or pass an
Apple password; use only Keychain profile `brewery-notary`.

## Workflow

1. Inspect the current branch, worktree, `origin`, project version/build, tags,
   and GitHub releases. Require clean `main`. If versions or release tags have
   gaps, stop and resolve the intended target instead of guessing.
2. Find the latest semantic release tag. Review both its GitHub Release notes
   and `git log` plus `git diff` from that tag to `HEAD`.
3. Create a fresh `.release/<VERSION>/release-notes.md` containing exactly:

   ```markdown
   ## What Implemented
   - Concise user-visible change
   ```

   Match prior Brewery release tone. Include only committed changes present in
   the diff; omit merge noise, secrets, and unrelated internal chores.
4. Run `zsh scripts/release.sh prepare <VERSION>`. Do not bypass a failed
   identity, GitHub authentication, archive, signature, notarization, staple,
   Gatekeeper, manifest, or checksum check.
5. Present the complete prepare preview: source/base, version/build, README
   diff, release body, notarization ID/status, verification results, absolute
   DMG path, byte size, SHA-256, and proposed mutation commands.
6. Ask the user whether to publish. Do not infer approval from an earlier
   request to prepare or automate.
7. After explicit approval, run `zsh scripts/release.sh publish <VERSION>` and
   enter the script's exact `PUBLISH v<VERSION>` confirmation.
8. Return the verified release URL. If a partial state is reported, follow only
   the safe inspection/retry command printed by the script; never force-push,
   delete a release tag, or blindly rerun `publish`.

## Quick checks

```zsh
security find-identity -v -p codesigning
xcrun notarytool history --keychain-profile brewery-notary --output-format json
gh auth status
zsh scripts/tests/release_test.sh
```

Treat failed readiness checks as blockers for a real release, not as reasons to
weaken the workflow.
