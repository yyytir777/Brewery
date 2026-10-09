# Isolated Homebrew command QA

`scripts/qa/isolated_homebrew.py` exercises actual Homebrew against task-authored local Formula and Cask assets. It does not launch Brewery or substitute a fake `brew` executable.

## Run

```sh
/usr/bin/python3 -B -m unittest discover -s scripts/qa -p 'test_*.py'
/usr/bin/python3 -B scripts/qa/isolated_homebrew.py
```

Run from the repository on macOS as a non-root user with an existing Homebrew checkout and its matching portable Ruby. The source defaults to `/opt/homebrew`; Intel users can pass `--source /usr/local/Homebrew` (or their actual repository). The source is read-only. No dependency download, OS setting change, account creation, `sudo`, Docker image pull, or Homebrew installation is required.

Homebrew's standard build/archive sandbox must be able to start. A containing agent sandbox can prevent this (`sandbox-exec: sandbox_apply: Operation not permitted`); the script fails before package installation. In that case run the same script from an ordinary terminal or a disposable macOS VM. Do not disable Homebrew's sandbox. Codex execution in the recorded run used approval-reviewed unsandboxed process launch so Homebrew could apply its own sandbox.

The script prints a new `/private/tmp/brewery-qa-<random>/` evidence path. It automatically removes only that run's `work/` directory, retaining logs and JSON evidence. `--keep` retains the work directory for inspection. There is deliberately no caller-supplied installation prefix, cleanup path, command, or package name.

## Isolation contract

- `mkdtemp` creates a mode-0700 namespace. Before operations and cleanup, the script verifies its owner, inode, marker, mode, and canonical path. Escaping symlinks and replacement markers abort cleanup.
- It clones the local Homebrew repository with `--no-hardlinks`, copies only the matching local portable Ruby, and never executes the original `brew`. It rejects runtime symlinks pointing outside their copy boundary and refuses system `/etc/homebrew/brew.env` overrides.
- A new subprocess environment redirects HOME, XDG config/cache/data, Homebrew cache/logs/temp, and the Cask app directory. Ruby reports prefix, repository, Cellar, Caskroom, locks, cache, logs, temp, HOME, and appdir; each must exactly match the expected temporary target and pass a write probe before package commands run.
- Git permits only `file` transport. Homebrew's absolute curl configuration permits only `file` URLs. Both restrictions are tested against an HTTPS URL and must reject its protocol before connecting. Auto-update, analytics, API installation, issue lookup, automatic cleanup, and installed-dependent upgrades are disabled. An empty local core tap satisfies Homebrew's unconditional `pkgconf` lookup after upgrade without fetching the real core tap.
- The only fixture artifacts are a shell text payload and an inert `.app` directory. They have no dependencies, package installers, launch agents, uninstall/zap hooks, postflight code, or outside paths. The application is installed but never launched. The permission fixture writes only a specified file inside the run's temporary directory.
- The copied launcher is chmod 0555; its bytes are unchanged. Homebrew 7.0.7 allows `/private/tmp` in its build sandbox after adding its executable deny rule. A writable launcher in that prefix triggers `Inherited sandbox permits writes`; Homebrew's own inherited-sandbox check explicitly accepts its internally supplied descriptor when ordinary permissions already prohibit writing the executable. No sandbox source, inheritance descriptor, group membership, or bypass flag is modified.
- On timeout, Ctrl-C, or SIGTERM, the runner stops and kills its owned child process tree (including Homebrew children that create a separate process group) before cleanup. It retains work if process enumeration is unavailable. SIGKILL or machine shutdown can leave disposable files behind.
- Metadata fingerprints before/after cover the original Cellar, Caskroom, locks, configuration directory, Homebrew cache/logs, user Applications, the original launcher, and the possible `/Applications/Brewery QA.app` destination. Any change makes the run fail; unrelated concurrent changes may require inspection. Fingerprints are corroboration, not an OS-wide write audit.

This is source-audited namespace isolation for these fixed fixtures, with Homebrew's normal sandbox. It is not a general-purpose sandbox for arbitrary third-party formulae or Casks. Do not add outside URLs, installer scripts, other Cask artifact types, or arbitrary user input without revisiting that contract.

## Scenario and evidence

The script records every argv, exit code, elapsed duration, and combined command log in `result.json` plus `command-*.log`. `before.json`, `installed-1.0.json`, `before-cleanup.json`, `after-cleanup.json`, and `after-uninstall.json` contain real `brew info --json=v2 --installed` data and measured Cellar/cache bytes.

1. Install `brewery/qa/qa-formula` and `brewery/qa/qa-app` at 1.0.
2. Change only the local tap's definitions/assets to 2.0; assert `outdated --json=v2` detects both, then upgrade and inspect installed files/Info.plist.
3. Install `qa-batch` and `qa-permission` in one command. The first succeeds; the second encounters a genuine filesystem permission error. Check the failed item is absent, make its task-owned permission target writable, and retry successfully.
4. Run cleanup; verify the 1.0 keg is removed and measured Cellar bytes decrease.
5. Uninstall the Cask and all Formula fixtures, cleanup again, and assert empty installed inventory and no app.

### 2026-10-03 execution

Homebrew **7.0.7**, repository commit `8e858db5584704dcd469b8e826228c0d5a5a94f6`, Apple Silicon macOS. Full real-command scenario passed twice: **29 commands, 15 assertions** per run. Final evidence: `/private/tmp/brewery-qa-pdyipla7/result.json` (previous passing run: `/private/tmp/brewery-qa-3gv8gi6h/result.json`). The owned work directories were removed; all protected metadata fingerprints were identical. `-B` prevents Python from creating bytecode in the caller's cache.

| Measurement | Before cleanup | After cleanup | After uninstall |
|---|---:|---:|---:|
| Cellar file bytes | 14,430 | 10,849 | 0 |
| Download cache file bytes | 2,116 | 0 | 0 |
| Fixture app present | yes | yes | no |

Guard tests: **13 passed**, including outside path/symlink rejection, marker replacement, cleanup scope, isolated environment/config, launcher protection, network protocol refusal, and real child-process interruption. Two initial investigations remain in temporary logs: `/private/tmp/brewery-qa-_dkuvmno` (writable-launcher failure), `/private/tmp/brewery-qa-cwsandag` (removed `--no-quarantine` option). A third run, `/private/tmp/brewery-qa-d2h1qq6d`, discovered the implicit core-tap clone; its owned processes were stopped and no external package was installed. The final script prevents this with the local core tap and tested transport restrictions.

This command evidence does **not** certify Brewery's Activity UI against the real runner, network reconnect behavior, macOS 13/Intel, or interactions with arbitrary installed packages. Activity/queue assertions use the separate deterministic UI fixture suite. Correlating actual command outcomes with Brewery's Activity display requires a separately isolated app launch configuration or a disposable VM; do not point Brewery at the user's normal prefix to fill that gap.

## Disposable macOS VM follow-up

Provision a macOS VM through your existing provider with a normal non-root account and supported Command Line Tools/Homebrew; bring this checkout and matching local portable Ruby into it. Run the same commands above and retain the output JSON/log directory. For actual Activity correlation, configure a test-only Brewery runner to the script-created prefix while keeping its HOME, appdir, cache, and logs isolated, then reproduce install/upgrade/failure/retry/cleanup before destroying the VM. The current script intentionally accepts no external prefix reuse, so a separate app integration adapter must keep the same guards.

Docker 29.5.2 was available locally during investigation, but Linux containers cannot execute macOS Casks. Existing local `ruby:3.4` also does not satisfy this Homebrew checkout's Ruby 4.0 requirement; no container or image was started/pulled for this task.

## Primary implementation references

The implementation was checked against the local Homebrew checkout at the recorded commit: `bin/brew` (prefix/config loading), `Library/Homebrew/startup/config.rb` (Cellar/locks/temp), `env_config.rb` and `utils/curl.rb` (environment/curl controls), `sandbox.rb` and `extend/os/mac/sandbox.rb` (sandbox/inheritance), `cask/config.rb`, `cask/artifact/app.rb`, `cask/artifact/moved.rb` (app targets), `cleanup.rb` (cleanup targets), and `extend/os/mac/pkgconf.rb` plus `cmd/upgrade.rb` (implicit core lookup). These source files are not changed by the script.
