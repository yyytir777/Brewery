#!/usr/bin/env python3
"""Actual, local-only Homebrew QA in an owned temporary prefix (macOS).

No custom prefix, arbitrary commands, external packages, sudo, or zap are accepted.
See docs/qa/qa-isolated-homebrew.md for the isolation contract and limitations.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import pwd
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from string import Template


class IsolationError(RuntimeError):
    pass


class Workspace:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="brewery-qa-", dir="/private/tmp"))
        self.identity = self.root.stat().st_ino
        self.token = secrets.token_hex(32)
        (self.root / ".owner").write_text(self.token)
        self.work = self.root / "work"
        self.work.mkdir()

    def verify_owner(self):
        info = self.root.lstat()
        marker = self.root / ".owner"
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or info.st_ino != self.identity or info.st_mode & 0o022
                or self.root.parent != Path("/private/tmp")
                or not self.root.name.startswith("brewery-qa-")
                or marker.is_symlink() or marker.read_text() != self.token):
            raise IsolationError("Temporary workspace identity changed; refusing to modify or delete it")

    def inside(self, path):
        self.verify_owner()
        path = Path(path)
        resolved = path.resolve()
        if not path.is_absolute() or self.root not in resolved.parents:
            raise IsolationError("Path escapes the owned workspace: " + str(path))
        return resolved

    def clean_work(self):
        self.verify_owner()
        if self.work.is_symlink():
            raise IsolationError("Work directory became a symlink")
        self.inside(self.work)
        if self.work.exists():
            shutil.rmtree(self.work)

    def remove_all(self):
        self.clean_work()
        self.verify_owner()
        shutil.rmtree(self.root)


def isolated_environment(space):
    work = space.work
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(work / "home"),
        "USER": pwd.getpwuid(os.getuid()).pw_name, "LOGNAME": pwd.getpwuid(os.getuid()).pw_name,
        "TMPDIR": str(work / "temp"), "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
        "XDG_CONFIG_HOME": str(work / "config"), "XDG_CACHE_HOME": str(work / "xdg-cache"),
        "XDG_DATA_HOME": str(work / "data"), "HOMEBREW_TEMP": str(work / "temp"),
        "HOMEBREW_CACHE": str(work / "cache"), "HOMEBREW_LOGS": str(work / "logs"),
        "HOMEBREW_CASK_OPTS": "--appdir=" + str(work / "Applications"),
        "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1",
        "HOMEBREW_NO_INSTALL_FROM_API": "1", "HOMEBREW_NO_GITHUB_API": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_ENV_HINTS": "1",
        "HOMEBREW_NO_BOOTSNAP": "1", "HOMEBREW_NO_COLOR": "1",
        "HOMEBREW_NO_EMOJI": "1", "HOMEBREW_DEVELOPER": "1",
        "HOMEBREW_CURLRC": str(work / "local-only.curlrc"),
        "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1", "GIT_ALLOW_PROTOCOL": "file",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0", "NONINTERACTIVE": "1", "SUDO_ASKPASS": "/usr/bin/false",
    }


def expected_configuration(space):
    work, brew = space.work, space.work / "brew"
    return {key: str(value) for key, value in {
        "prefix": brew, "repository": brew, "cellar": brew / "Cellar", "caskroom": brew / "Caskroom",
        "locks": brew / "var/homebrew/locks", "cache": work / "cache", "logs": work / "logs",
        "temp": work / "temp", "home": work / "home", "appdir": work / "Applications",
    }.items()}


def validate_configuration(space, actual):
    expected = expected_configuration(space)
    if actual != expected:
        raise IsolationError("Homebrew configuration does not match the isolated paths: " + json.dumps(actual))
    for path in actual.values():
        resolved = space.inside(Path(path))
        resolved.mkdir(parents=True, exist_ok=True)
        probe = resolved / (".brewery-write-probe-" + secrets.token_hex(8))
        with probe.open("x") as stream:
            stream.write("owned namespace")
        probe.unlink()


def validate_copy_tree(source):
    source = source.resolve()
    for entry in source.rglob("*"):
        if entry.is_symlink() and source not in entry.resolve().parents:
            raise IsolationError("Source contains an escaping symlink: " + str(entry))


def protect_copied_launcher(space):
    launcher = space.work / "brew/bin/brew"
    if launcher.is_symlink():
        raise IsolationError("Copied launcher must not be a symlink")
    space.inside(launcher)
    # The upstream build sandbox allows /private/tmp. Keep its executable
    # read-only so Homebrew's own inherited-sandbox integrity check succeeds.
    # File contents, sandbox implementation, and inheritance descriptors are untouched.
    launcher.chmod(0o555)


def configure_local_downloads(space):
    space.inside(space.work / "local-only.curlrc").write_text('proto = "=file"\nproto-redir = "=file"\n')


def terminate_owned_process(process):
    """Stop children that Homebrew puts in separate process groups as well."""
    def send(pid, sig):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass

    send(process.pid, signal.SIGSTOP)
    owned = {process.pid}
    inspected = False
    for _ in range(10):
        try:
            listing = subprocess.run(["/bin/ps", "-axo", "pid=,ppid="], capture_output=True, text=True)
        except OSError:
            break
        if listing.returncode:
            break
        pairs = [tuple(map(int, line.split())) for line in listing.stdout.splitlines() if line.strip()]
        discovered = {pid for pid, parent in pairs if parent in owned} - owned
        if not discovered:
            inspected = True
            break
        for pid in discovered:
            send(pid, signal.SIGSTOP)
        owned.update(discovered)
    for pid in owned - {process.pid}:
        send(pid, signal.SIGKILL)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()
    return inspected


def fingerprint(path):
    """Metadata-only fingerprint; intentionally excludes atime, never executes normal brew."""
    path = Path(path)
    digest, count = hashlib.sha256(), 0
    paths = [path]
    if path.is_dir() and not path.is_symlink():
        paths.extend(sorted(path.rglob("*")))
    for entry in paths:
        try:
            st = entry.lstat()
            value = [str(entry.relative_to(path)), st.st_mode, st.st_size, st.st_mtime_ns,
                     os.readlink(entry) if entry.is_symlink() else None]
        except FileNotFoundError:
            value = [str(entry), "absent"]
        digest.update(json.dumps(value).encode())
        count += 1
    return {"sha256": digest.hexdigest(), "entries": count}


def size_bytes(path):
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file() and not p.is_symlink())


class Harness:
    def __init__(self, source, keep=False):
        self.space = Workspace()
        self.source, self.keep = source.resolve(), keep
        self.env = isolated_environment(self.space)
        self.brew = self.space.work / "brew/bin/brew"
        self.report = {"status": "running", "root": str(self.space.root), "commands": [], "checks": []}
        self.tap = self.space.work / "brew/Library/Taps/brewery/homebrew-qa"
        self.denied = self.space.work / "temp/permission-target"

    def run(self, args, expected=0, timeout=180):
        self.space.verify_owner()
        args = [str(x) for x in args]
        index = len(self.report["commands"])
        start = time.monotonic()
        log = self.space.root / ("command-%02d.log" % index)
        with log.open("w") as output:
            process = subprocess.Popen(args, cwd=self.space.work, env=self.env, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                if not terminate_owned_process(process):
                    self.keep = True
                code = -signal.SIGKILL
            except BaseException:
                if not terminate_owned_process(process):
                    self.keep = True
                self.report["commands"].append({"argv": args, "exit_code": process.returncode,
                                                "interrupted": True, "log": log.name})
                self.save()
                raise
        text = log.read_text(errors="replace")
        self.report["commands"].append({"argv": args, "exit_code": code, "seconds": round(time.monotonic() - start, 3),
                                        "log": log.name})
        self.save()
        if (expected == 0 and code != 0) or (expected == "failure" and code <= 0):
            raise IsolationError("Command did not have expected exit status: %s\n%s" % (args, text[-6000:]))
        return text

    def command(self, *args, **options):
        # Only the copied executable is ever used, regardless of ambient PATH.
        self.space.inside(self.brew)
        return self.run([self.brew, *args], **options)

    def check(self, condition, message):
        if not condition:
            raise IsolationError(message)
        self.report["checks"].append(message)
        self.save()

    def save(self):
        (self.space.root / "result.json").write_text(json.dumps(self.report, indent=2) + "\n")

    def prepare(self):
        if platform.system() != "Darwin" or os.geteuid() == 0:
            raise IsolationError("Requires a non-root macOS user")
        if Path("/etc/homebrew/brew.env").exists():
            raise IsolationError("System brew.env could override isolation; use a clean macOS VM")
        if not (self.source / "bin/brew").is_file():
            raise IsolationError("Source must be a local Homebrew Git repository with portable Ruby already present")
        for key in ["HOME", "TMPDIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME",
                    "HOMEBREW_CACHE", "HOMEBREW_LOGS"]:
            self.space.inside(Path(self.env[key])).mkdir(parents=True, exist_ok=True)
        configure_local_downloads(self.space)
        # No bypass flag: Homebrew will use its normal sandbox for builds and archive extraction.
        self.run(["/usr/bin/sandbox-exec", "-p", "(version 1) (allow default)", "/usr/bin/true"])
        remote_git = self.run(["/usr/bin/git", "ls-remote", "https://example.invalid/brewery-qa"], expected="failure")
        self.check("transport 'https' not allowed" in remote_git, "Git refuses remote transports before connecting")
        remote_curl = self.run(["/usr/bin/curl", "--disable", "--config", self.env["HOMEBREW_CURLRC"],
                                "https://example.invalid/brewery-qa"], expected="failure")
        self.check("disabled" in remote_curl, "Curl refuses remote protocols before connecting")
        self.report["source_commit"] = self.run(["/usr/bin/git", "-C", self.source, "rev-parse", "HEAD"]).strip()
        self.run(["/usr/bin/git", "clone", "--local", "--no-hardlinks", "--no-checkout", self.source,
                  self.space.work / "brew"])
        self.run(["/usr/bin/git", "-C", self.space.work / "brew", "checkout", "--detach", self.report["source_commit"]])
        vendor = Path("Library/Homebrew/vendor")
        version = (self.space.work / "brew" / vendor / "portable-ruby-version").read_text().strip()
        if not version or "/" in version or version.startswith("."):
            raise IsolationError("Invalid portable Ruby version")
        source_ruby = self.source / vendor / "portable-ruby" / version
        validate_copy_tree(source_ruby)
        if not (source_ruby / "bin/ruby").is_file():
            raise IsolationError("Matching local portable Ruby is missing; downloads are not allowed")
        destination = self.space.work / "brew" / vendor / "portable-ruby" / version
        shutil.copytree(source_ruby, destination, symlinks=True)
        (destination.parent / "current").symlink_to(version)
        validate_copy_tree(self.space.work / "brew")
        protect_copied_launcher(self.space)
        # Every mutable location for the only artifact types in our fixtures is inspected in Ruby.
        query = ('require "json"; require "cask/config"; puts JSON.generate({'
                 'prefix: HOMEBREW_PREFIX.to_s, repository: HOMEBREW_REPOSITORY.to_s,'
                 'cellar: HOMEBREW_CELLAR.to_s, caskroom: HOMEBREW_CASKROOM.to_s,'
                 'locks: HOMEBREW_LOCKS.to_s, cache: HOMEBREW_CACHE.to_s, logs: HOMEBREW_LOGS.to_s,'
                 'temp: HOMEBREW_TEMP.to_s, home: ENV.fetch("HOME"), appdir: Cask::Config.new(explicit: {}).appdir.to_s})')
        config_text = self.command("ruby", "-e", query)
        config = json.loads(next(line for line in reversed(config_text.splitlines()) if line.startswith("{")))
        validate_configuration(self.space, config)
        self.report["configuration"] = config
        self.report["environment"] = self.env
        self.report["homebrew_version"] = self.command("--version").strip()
        for subdir in ["Formula", "Casks"]:
            (self.tap / subdir).mkdir(parents=True)
        # `upgrade` looks up core/pkgconf even for a dependency-free tap Formula.
        # An empty local core tap makes that lookup return absent without fetching GitHub.
        core = self.space.work / "brew/Library/Taps/homebrew/homebrew-core"
        (core / "Formula").mkdir(parents=True)
        self.run(["/usr/bin/git", "init", core])
        self.run(["/usr/bin/git", "init", self.tap])
        self.denied.write_text("permission fixture")
        self.denied.chmod(0o400)
        self.fixtures("1.0")
        self.run(["/usr/bin/git", "-C", self.tap, "add", "."])
        self.run(["/usr/bin/git", "-C", self.tap, "-c", "user.name=Brewery QA", "-c", "user.email=qa@example.invalid",
                  "commit", "-m", "Local disposable fixtures"])
        self.check("brewery/qa" in self.command("tap"), "Qualified local tap is discovered")
        self.save()

    def fixtures(self, version):
        assets = Path(__file__).with_name("fixtures")
        staging = self.space.work / ("assets-" + version)
        staging.mkdir()
        payload = staging / "qa-payload"
        payload.write_text((assets / "qa-payload.sh").read_text().replace("@VERSION@", version))
        payload.chmod(0o755)
        app = staging / "Brewery QA.app/Contents"
        (app / "MacOS").mkdir(parents=True)
        shutil.copy2(payload, app / "MacOS/qa-payload")
        with (app / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "invalid.example.brewery.qa", "CFBundleName": "Brewery QA",
                          "CFBundleExecutable": "qa-payload", "CFBundlePackageType": "APPL",
                          "CFBundleShortVersionString": version, "CFBundleVersion": version}, stream)
        for kind, entry in [("formula", payload), ("cask", app.parent)]:
            archive = self.space.work / (kind + "-" + version + ".tar.gz")
            with tarfile.open(archive, "w:gz") as bundle:
                bundle.add(entry, arcname=entry.name)
            values = {"version": version, "url": archive.as_uri(), "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}
            if kind == "formula":
                for name, class_name in [("qa-formula", "QaFormula"), ("qa-batch", "QaBatch"), ("qa-permission", "QaPermission")]:
                    permission = 'File.write(%s, "retry succeeded")' % json.dumps(str(self.denied)) if name == "qa-permission" else ""
                    template = Template((assets / "formula.rb.in").read_text())
                    (self.tap / "Formula" / (name + ".rb")).write_text(template.substitute(values, name=name, class_name=class_name,
                                                                                         permission_check=permission))
            else:
                (self.tap / "Casks/qa-app.rb").write_text(Template((assets / "cask.rb.in").read_text()).substitute(values))

    def snapshot(self, stage):
        formula = json.loads(self.command("info", "--json=v2", "--installed"))
        state = {"inventory": formula, "cellar_bytes": size_bytes(self.space.work / "brew/Cellar"),
                 "cache_bytes": size_bytes(self.space.work / "cache"),
                 "app_exists": (self.space.work / "Applications/Brewery QA.app").exists()}
        (self.space.root / (stage + ".json")).write_text(json.dumps(state, indent=2) + "\n")
        return state

    def execute(self):
        self.snapshot("before")
        self.command("install", "--formula", "--build-from-source", "brewery/qa/qa-formula")
        self.command("install", "--cask", "brewery/qa/qa-app")
        self.check((self.space.work / "brew/Cellar/qa-formula/1.0/bin/qa-formula").exists(), "Formula 1.0 exists")
        self.check((self.space.work / "Applications/Brewery QA.app").exists(), "Cask 1.0 exists in isolated appdir")
        self.snapshot("installed-1.0")
        self.fixtures("2.0")
        outdated = json.loads(self.command("outdated", "--json=v2"))
        self.check(bool(outdated["formulae"]) and bool(outdated["casks"]), "Formula and Cask upgrades are detected")
        self.command("upgrade", "--formula", "--build-from-source", "brewery/qa/qa-formula")
        self.command("upgrade", "--cask", "brewery/qa/qa-app")
        self.check((self.space.work / "brew/Cellar/qa-formula/2.0/bin/qa-formula").exists(), "Formula upgrades to 2.0")
        with (self.space.work / "Applications/Brewery QA.app/Contents/Info.plist").open("rb") as stream:
            self.check(plistlib.load(stream)["CFBundleVersion"] == "2.0", "Cask upgrades to 2.0")
        partial = self.command("install", "--formula", "--build-from-source", "brewery/qa/qa-batch",
                               "brewery/qa/qa-permission", expected="failure")
        self.check((self.space.work / "brew/Cellar/qa-batch/2.0/bin/qa-batch").exists(), "Successful item remains after partial failure")
        self.check("Permission denied" in partial or "Operation not permitted" in partial,
                   "Failing item reports a real filesystem permission error")
        self.check(not (self.space.work / "brew/Cellar/qa-permission/2.0/bin/qa-permission").exists(),
                   "Failing item is not reported as installed")
        self.denied.chmod(0o600)
        self.command("install", "--formula", "--build-from-source", "brewery/qa/qa-permission")
        self.check(self.denied.read_text() == "retry succeeded", "Permission failure can be retried successfully")
        before = self.snapshot("before-cleanup")
        self.command("cleanup", "--prune=all")
        after = self.snapshot("after-cleanup")
        self.check(after["cellar_bytes"] < before["cellar_bytes"], "Cleanup reduces measured Cellar bytes")
        self.check(not (self.space.work / "brew/Cellar/qa-formula/1.0").exists(), "Cleanup removes the old Formula keg")
        self.command("uninstall", "--cask", "brewery/qa/qa-app")
        self.command("uninstall", "--formula", "brewery/qa/qa-formula", "brewery/qa/qa-batch", "brewery/qa/qa-permission")
        self.command("cleanup", "--prune=all")
        final = self.snapshot("after-uninstall")
        self.check(not final["inventory"]["formulae"] and not final["inventory"]["casks"] and not final["app_exists"],
                   "Uninstall leaves no installed fixture or application")

    def finish(self):
        self.save()
        if self.denied.exists():
            self.denied.chmod(0o600)
        if not self.keep:
            self.space.clean_work()
        self.report["workspace_retained"] = self.keep
        self.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("/opt/homebrew"), help="Read-only local Homebrew repository")
    parser.add_argument("--keep", action="store_true", help="Keep the owned temporary work directory for inspection")
    args = parser.parse_args()
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    harness = Harness(args.source, args.keep)
    # Baseline uses filesystem metadata, never invokes the user's brew or package executables.
    source = args.source.resolve()
    original_prefix = Path("/usr/local") if source == Path("/usr/local/Homebrew") else source
    protected = [original_prefix / x for x in ["Cellar", "Caskroom", "var/homebrew/locks", "etc/homebrew"]]
    protected += [Path.home() / "Library/Caches/Homebrew", Path.home() / "Library/Logs/Homebrew", Path.home() / "Applications"]
    protected += [Path("/Applications/Brewery QA.app"), args.source.resolve() / "bin/brew"]
    before = {str(path): fingerprint(path) for path in protected}
    harness.report["protected_before"] = before
    print("QA evidence: " + str(harness.space.root), flush=True)
    code = 1
    try:
        harness.prepare()
        harness.execute()
        harness.report["status"] = "passed"
        code = 0
    except KeyboardInterrupt:
        harness.report["status"] = "interrupted"
        harness.report["error"] = "Interrupted; direct child reaped. Work retained if descendants could not be inspected."
        code = 130
    except Exception as error:
        harness.report["status"] = "failed"
        harness.report["error"] = str(error)
        print(str(error), file=sys.stderr)
    finally:
        after = {str(path): fingerprint(path) for path in protected}
        harness.report["protected_after"] = after
        harness.report["protected_unchanged"] = before == after
        if before != after:
            harness.report["status"] = "failed"
            harness.report["protected_change"] = "Protected metadata changed; inspect evidence (concurrent changes are possible)"
            code = 1
        harness.finish()
    print("Result: %s; %s" % (harness.report["status"], harness.space.root / "result.json"))
    return code


if __name__ == "__main__":
    sys.exit(main())
