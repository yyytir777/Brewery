# Native Activity QA with actual isolated Homebrew

This complements `qa-isolated-homebrew.md`. It prepares a separate app that runs actual Homebrew through Brewery's real `Process`, streamed output, operation queue, inventory parser, and Activity UI. Repository product files and the existing mock UI-testing contract are not changed.

## Prepare and keep the controller alive

```sh
/usr/bin/python3 -B -m unittest discover -s scripts/qa -p 'test_*.py'
/usr/bin/python3 -B scripts/qa/native_homebrew_app.py
```

Run preparation from an ordinary terminal, or an approval-reviewed process outside a containing agent sandbox so Homebrew can apply its own sandbox. A PTY keeps controller stdin available. It clones only the local Homebrew source, creates local fixtures, validates Homebrew's resolved paths/network restrictions, probes Foundation's HOME/cache/library/application-support paths in a **console-only** executable, and builds/codesigns a uniquely identified Debug app under its newly owned `/private/tmp/brewery-qa-<random>/work/` directory. It does not launch the app or install packages.

The output `ready_for_cua_launch` supplies the app path and evidence directory. Keep this controller process alive: it retains the workspace inode, token, ownership object, and an exclusive kernel `flock` lease on a uniquely created mode-0600 file. The descriptor is close-on-exec and is not inherited by child processes. Native startup and every command check controller PID, lease inode/owner/token, and that the exclusive lease is still held. Closing the controller releases the lease and rejects subsequent commands even if the original PID is reused. An already-running command may finish inside the preserved namespace. There is no arbitrary-prefix resume or arbitrary-command interface. EOF, interruption, or preparation failure preserves the namespace; it never automatically deletes files while a native app may still be running.

Only root CUA should launch the supplied app and operate its UI. After launch, read `native-startup.json` and require `status: passed` **before any install/update/uninstall/cleanup interaction**. A console Foundation probe proves how the environment resolves, but does not prove Launch Services applied it to the app. Launch Services may replace the HOME string while CFFIXED_USER_HOME and all actual Foundation paths remain isolated. Startup first verifies bundle, ownership, lease, CFFIXED_USER_HOME, and actual Foundation paths; only then it sets HOME inside this process to the already-validated temporary home. It records before/after POSIX and ProcessInfo HOME values, and requires the full final path guard. It never normalizes a failing Foundation path or changes system/shell environment settings. If native startup fails, the app exits before creating `BreweryViewModel` or running Homebrew; no normal-prefix fallback exists.

## What is changed in the disposable source copy

- `BreweryCommand`: one fixed executable; a complete fixed environment; exact argv/package allowlist; guard failure returns code 64 before `Process`. The original process construction, pipe reads, streaming callback, wait/exit handling, and result construction are preserved.
- `BreweryLogger`: explicit temporary log directory plus a JSONL command-result audit for correlating Activity output with actual stdout/stderr/exit code.
- `BreweryApp`: guard first, then the original default `BreweryViewModel()` (no injected command runner, so `usesLiveCommands` and the real streaming path remain active). A local-file-only `CatalogServing` lists exactly four qualified fixture IDs; it creates no URLSession/API/cache service. Settings controls are disabled in this disposable app.
- One generated Swift guard/catalog source file, unique bundle ID, and a temporary bundle Info.plist with `LSEnvironment`. HOME, CFFIXED_USER_HOME, TMPDIR, and all Homebrew paths are set before Launch Services starts the app. Startup checks Foundation's actual resolved paths, not just environment strings.

The controller saves the exact `native-source-transform.diff`, configuration, build logs, code-sign verification, source hashes, and console probe. It checks `makeProcess`, `readOutput`, `executeProcess`, and `drainOutput` bodies, ViewModel, operation model, MainView, Activity UI, and existing mock fixture source stay unchanged. It also verifies the repository product/project files are byte-identical after preparation. No product Release setting is changed.

Apple documents [LSEnvironment](https://developer.apple.com/documentation/bundleresources/information-property-list/lsenvironment) for launch-time environment variables. Apple's [CoreFoundation implementation](https://github.com/apple-oss-distributions/CF/blob/main/CFPlatform.c) uses CFFIXED_USER_HOME for home-directory resolution. The live probe/startup checks remain mandatory because source documentation alone does not establish the current OS/launch context.

## Command boundary

Formula IDs: `brewery/qa/qa-formula`, `brewery/qa/qa-batch`, `brewery/qa/qa-permission`. Cask ID: `brewery/qa/qa-app`.

Permitted commands are the app's fixed inventory/outdated/version/size queries, typed info for those exact IDs, single-package typed install/upgrade/uninstall for the matching kind, `cleanup --dry-run`, and `cleanup`. Short names, other packages, extra arguments, `update`, `--zap`, and arbitrary commands are refused. Native command execution checks the workspace owner/inode/token, live controller lease, canonical paths, Foundation paths, and copied launcher's SHA-256 every time. Git and curl are restricted to file transport by the underlying harness. The local catalog has no external homepage links.

## Fixed controller actions

Send one exact line to the original controller stdin; these are not shell commands.

| Action | Effect |
|---|---|
| `snapshot` | While Homebrew is idle, collect real inventory, Cellar/cache bytes, and app existence in a numbered JSON file. |
| `repair-permission` | Make only the fixture's task-owned permission target writable, enabling UI retry. |
| `advance-to-2.0` | Once only: regenerate local 2.0 Formula/Cask definitions/assets and the local catalog, and make the permission target read-only again for a real upgrade failure. |
| `finish` | Requires the QA app and every related subprocess to be gone, fixtures uninstalled, and existing protected paths unchanged. It may remove its own newly created window-layout preference under the strict contract below, rechecks all fourteen protected fingerprints, then removes the owned work directory and preserves evidence. |

Every action requires the original workspace identity and passing native startup record. Version/permission/snapshot actions refuse while a Homebrew child is running. Read-only `ps` parent relationships and `lsof` cwd/executable/mapped-text paths identify descendants, processes using the work namespace, and orphaned children whose argv contains no owned path. Both `/private/tmp` and macOS's `/tmp` alias are checked. Only the verified main app PID/executable may remain during non-finish actions; `finish` permits none. Stable current-user processes missing cwd/text inspection, inspection errors, and inspection warnings refuse cleanup. Zombies are already terminated and hold no such paths. The controller does not kill unrelated processes. If this controller is interrupted, leave the preserved namespace alone until all owned processes are stopped and it can be inspected.

Successful `finish` records `status: namespace_verified` and `native_scenarios: not_assessed`. It verifies empty fixture inventory, process absence, protected fingerprints, and owned cleanup; it does not judge whether the UI scenarios were executed. Root must assess that separately from CUA, command events, and snapshots. Launching and immediately quitting cannot count as a scenario pass.

## Root CUA sequence

1. Launch the exact prepared app path, verify native startup, and capture Home/Discover showing the four local qualified package IDs and empty installed inventory.
2. Install the Formula and Cask through Discover. Capture actual Activity Completed status/output and take a controller snapshot.
3. Install `qa-permission`; verify the real permission failure in Activity. Send `repair-permission`, retry from the UI, and confirm Completed plus installed inventory. This is a real retry, not a simulated success.
4. Send `advance-to-2.0`, refresh inventory/catalog through the UI, then update the installed fixtures. The permission Formula should fail while other queued updates succeed. Capture the mixed Activity results. Send `repair-permission` and retry the failed update.
5. Use the normal cleanup preview and confirmation UI. Compare Activity output, real inventory and Cellar byte snapshots. The app invokes plain `cleanup`, so do not require its fresh download cache to drop to zero as with the CLI harness's `--prune=all`.
6. Uninstall all fixtures through the UI with Cask data deletion unchecked. Capture Completed entries and empty inventory. Quit the app through CUA, then send `finish`.

`native-command-events.jsonl` records actual command arguments/results; `native-startup.json` records actual native app paths/PID; CUA captures establish what Activity displayed. Queue/status/output matches must be checked against these files and real package/file snapshots. Merely building the app or reading console logs does not complete Activity UI QA.

Protected fingerprints include the original nine Homebrew/app paths plus the normal Brewery log/cache/preferences and the unique QA app's possible preferences/saved-state paths in the real home. Thirteen paths must remain strictly unchanged. Although HOME and Foundation directories resolve inside the temporary namespace, macOS's preferences daemon can persist this app's window layout under its unique bundle domain in the real home; this happened in the initial live run. Home-directory path checks therefore do not prove that every OS-mediated write stays in the namespace.

Only the new controller's `finish` may remove that one task-created preference. The path is derived from its original real home and `invalid.example.brewery.nativeqa.<owner-token-prefix>`; there is no path argument, arbitrary reconnect, or new control action. Removal requires recorded pre-launch absence, empty inventory, no app/descendants/cwd/text users, unchanged other thirteen protected paths, a regular non-symlink single-link mode-0600 file owned by this UID, and exactly the two observed SwiftUI window/split-layout keys with numeric layout values. Stable complete content, SHA-256, inode/device, owner, mode, size, and modification time must match before removal. Changed or unfamiliar content is preserved and refused.

`native-preference-cleanup.jsonl` records exact bytes (base64), parsed content and identity before deletion, the single-file removal, and a delayed absence check. The original fourteen fingerprints are then checked again. A recreated preference is retained and finish fails; the controller never deletes it repeatedly or changes the running preferences daemon. This is an audited creation-and-removal side effect, not evidence that no real-home write occurred. Older failed namespaces are retained with their evidence and are never reconnected for cleanup by this tool.

Fingerprints and the bounded absence check are corroborating checks, not an OS-wide write audit or a promise that a system daemon can never recreate a cached domain later. Unrelated concurrent edits can also cause a failure requiring inspection.

## Actual native execution on 2026-10-03

The run at `/private/tmp/brewery-qa-5cq8e5hl` completed the actual Homebrew lifecycle through root CUA and the production Process/queue/Activity path: qualified Formula/Cask installation, a real permission installation failure and successful retry, a four-item upgrade with three successes and one permission failure, successful upgrade retry, cleanup preview/confirmation, and four successful uninstalls. The Cask uninstall did not use `--zap`. The command audit contains 80 native command results: 15 mutations, one cleanup preview, and 64 read queries. Controller/preparation evidence separately records 25 commands.

| Snapshot | Actual package state | Cellar bytes | Cache bytes |
|---|---|---:|---:|
| 01 | Three packages at 1.0; permission Formula absent | 7,136 | 1,049 |
| 02 | Four packages at 1.0 after install retry | 10,849 | 1,143 |
| 03 | Three active versions at 2.0; permission Formula at 1.0 | 17,985 | 2,196 |
| 04 | Four active versions at 2.0; three old Formula kegs retained | 21,698 | 2,290 |
| 05 | Cleanup removed all three old kegs; four packages remain at 2.0 | 10,849 | 1,148 |
| 06 | Empty Formula/Cask inventory; fixture app absent | 0 | 875 |

This app copied the verified Process fix (`BreweryCommand.swift` SHA-256 `e4e09eaad4b321ba6befbb1b530f3679734eb5eddca27e97b1808d41afc7976b`). The four Process/output function bodies were checked unchanged in the copy. The later linked-keg version-display model fix is outside this app's source snapshot; its separate tests/build evidence must not be attributed to this native run.

Final cleanup was **refused and the namespace retained**. After the app and related processes exited, `native-final.json` confirmed empty inventory, zero Cellar bytes, and no fixture app. However, the pre-launch fingerprint for `/Users/wonjae/Library/Preferences/yyytir777.Brewery.plist` differed, in addition to the expected new QA-domain preference. The other twelve protected paths were unchanged. The controller refused before the task-owned preference removal step, so neither the QA preference nor the work directory was deleted. The fingerprint alone does not attribute the normal Brewery preference change to this native app or another concurrent app/test run. No baseline was reset and no existing user preference was altered to make cleanup pass. This run therefore has actual lifecycle/UI evidence but does **not** have `namespace_verified` completion.

Evidence remains under `/private/tmp/brewery-qa-5cq8e5hl`: `native-ui-observations.json` records root CUA observations; `native-command-events.jsonl` contains actual results; `native-snapshot-01.json` through `native-snapshot-06.json` and `native-final.json` contain real inventory/bytes; `native-startup.json`, `native-configuration.json`, `native-product-source-hashes.json`, `native-process-body-preservation.json`, and `native-source-transform.diff` establish the source/runtime boundary. `native-finish-refusal-evidence.json` records the exact final refusal and all fourteen before/after fingerprints. The final 22 safety-test run and source hashes are separately preserved in `/private/tmp/brewery-qa-completion/native-safety-final/tests-approved.log` and `verification-approved.json`.

## Successful final run with the latest model

A separate run at `/private/tmp/brewery-qa-io0m6z92` completed on 2026-10-03 with `status: namespace_verified`. Normal Brewery, test hosts, other QA app variants, and parallel tests/builds remained stopped while root operated this app through CUA. The app used the same verified Command SHA above and the latest `BreweryData.swift` SHA-256 `559e2804f9434f4b5eec9cd116d35b52833ef749a24656bca8c7e65756d22bf2`. Product/project/tests/tool/docs files matched between the worktree and primary checkout before preparation, and the four safety-test inputs still matched the recorded 22-test passing run; tests were not rerun concurrently with native QA.

The full real lifecycle was repeated: Formula/Cask install, permission install failure/retry, selected upgrades with partial failure, permission upgrade retry, cleanup, and four uninstalls without Cask data deletion. Root also verified the latest Installed version display through accessibility text and screenshots before cleanup: updated Formulae displayed 2.0 while their 1.0 and 2.0 kegs both remained installed. After retry, all four displayed 2.0 and Updates was empty. The evidence contains 80 native command results (15 mutations, one cleanup preview, 64 read queries), 25 preparation/controller commands, and eight root UI scenario observations.

| Snapshot | Actual package state | Cellar bytes | Cache bytes |
|---|---|---:|---:|
| 01 | Three packages at 1.0; permission Formula absent | 7,136 | 1,047 |
| 02 | Four packages at 1.0 after retry | 10,849 | 1,141 |
| 03 | Three active versions at 2.0; permission Formula at 1.0 | 17,985 | 2,190 |
| 04 | Four active versions at 2.0; three old Formula kegs retained | 21,698 | 2,284 |
| 05 | Four packages at 2.0; all three old kegs removed | 10,849 | 1,144 |
| 06 | Empty inventory; fixture app absent | 0 | 871 |

After CUA quit the app, process/descendant/cwd/text inspection confirmed no related live process. Final inventory remained empty. All fourteen protected fingerprints matched their original values after the narrowly validated removal of this run's task-created window-layout preference. The normal Brewery preference file's bytes also matched its read-only pre-run backup and SHA-256 before build, before mutation, before finish, and after finish. The backup is retained with mode `0600`; no normal preference was restored, rewritten, or used as a new baseline. The controller removed its owned work directory, exited successfully, and released its kernel lease. The final absence recheck confirmed that this run's QA preference had not reappeared; the documented daemon/recreation limitation still applies.

Final evidence is retained under `/private/tmp/brewery-qa-io0m6z92`: `result.json` contains `namespace_verified`, all fourteen before/after fingerprints, and the explicit task-created preference side-effect note. `native-finish-verification.json` independently confirms source-independent cleanup facts, command counts, unchanged normal preference bytes, work removal, and lease release. `native-preference-cleanup.jsonl` preserves the exact task-created preference content/identity and removal audit. `native-preflight.json` and the private `native-normal-preference-before.plist` preserve the original baseline; `native-before-finish-check.json` confirms app termination and unchanged bytes. `native-ui-observations.json`, actual command JSONL, six snapshots, final inventory, startup/configuration, source manifests, and transformation diff retain the UI/runtime/source evidence after work deletion. The controller deliberately leaves UI scenario judgment to root's observations rather than inferring it from successful namespace cleanup.

The earlier failed namespaces, their preferences, and their evidence remain preserved. This successful run neither reused those namespaces nor waived their failures. Validation remained local; no commit, push, pull request, or CI dispatch was performed by this workflow.
