#!/usr/bin/env python3
"""Prepare a disposable native app for actual Homebrew/Activity QA; never launch it.

Keep this process alive. Its stdin accepts only snapshot, advance-to-2.0,
repair-permission, and finish. UI launch and interaction belong to native CUA.
"""
import argparse
import base64
import difflib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import time

from isolated_homebrew import Harness, IsolationError, expected_configuration, fingerprint

FORMULAE = ("brewery/qa/qa-formula", "brewery/qa/qa-batch", "brewery/qa/qa-permission")
CASKS = ("brewery/qa/qa-app",)
ACTIONS = ("snapshot", "advance-to-2.0", "repair-permission", "finish")
WINDOW_LAYOUT_ID = ("SwiftUI._ConditionalContent<SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<"
                    "SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.Text, "
                    "SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>)"
                    ">>, SwiftUI._PaddingLayout>, SwiftUI._FlexFrameLayout>, SwiftUI.AccessibilityAttachmentModifier>, "
                    "BreweryHomebrewQA.MainView>, BreweryHomebrewQA.MainView>-1-AppWindow-1")
WINDOW_LAYOUT_KEY = "NSWindow Frame " + WINDOW_LAYOUT_ID
SPLIT_LAYOUT_KEY = "NSSplitView Subview Frames " + WINDOW_LAYOUT_ID + ", SidebarNavigationSplitView"


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise IsolationError("Source transformation anchor is missing or ambiguous: " + old[:100])
    return source.replace(old, new, 1)


def braced_block(source, anchor):
    if source.count(anchor) != 1:
        raise IsolationError("Source block is missing or ambiguous: " + anchor)
    start = source.index(anchor)
    opening = source.index("{", start)
    depth = 1
    for end in range(opening + 1, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[start:end + 1]
    raise IsolationError("Unterminated source block: " + anchor)


def parse_action(text):
    action = text.strip()
    if action not in ACTIONS:
        raise IsolationError("Only these fixed actions are supported: " + ", ".join(ACTIONS))
    return action


class ControllerLease:
    """An exclusive kernel lease, released even on controller crash; never inherited."""
    def __init__(self, space):
        space.verify_owner()
        self.path = space.root / ".controller-lease"
        self.fd = None
        try:
            self.fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
            os.set_inheritable(self.fd, False)
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            os.write(self.fd, space.token.encode())
            self.identity = os.fstat(self.fd).st_ino
        except OSError as error:
            self.close()
            raise IsolationError("Cannot acquire unique controller lease") from error

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def parse_processes(listing):
    result = {}
    for line in listing.splitlines():
        parts = line.strip().split(maxsplit=3)
        if len(parts) != 4 or not all(value.isdigit() for value in parts[:2]):
            raise IsolationError("Unrecognized process listing; namespace retained")
        # Zombies cannot execute or retain an open cwd/executable. Their parent
        # may not yet have reaped them, so lsof correctly has no paths to inspect.
        if parts[2].startswith("Z"):
            continue
        result[int(parts[0])] = {"parent": int(parts[1]), "command": parts[3]}
    if not result:
        raise IsolationError("Empty process listing; namespace retained")
    return result


def parse_open_paths(listing):
    result, pid, descriptor = {}, None, None
    for line in listing.splitlines():
        if line.startswith("p"):
            if not line[1:].isdigit():
                raise IsolationError("Unrecognized open-file PID; namespace retained")
            pid, descriptor = int(line[1:]), None
            result[pid] = {"cwd": [], "txt": []}
        elif line.startswith("f"):
            descriptor = line[1:]
        elif line.startswith("n") and pid is not None and descriptor in ("cwd", "txt"):
            result[pid][descriptor].append(line[1:])
        else:
            raise IsolationError("Unrecognized open-file listing; namespace retained")
    return result


def require_inspection_complete(before, after, paths):
    # Transient ps/lsof processes may exit between snapshots. Stable processes must
    # have both cwd and executable/mapped-text inspection, or cleanup is refused.
    stable = set(before) & set(after)
    missing = [pid for pid in stable if not paths.get(pid, {}).get("cwd") or not paths.get(pid, {}).get("txt")]
    if missing:
        raise IsolationError("Cannot inspect current-user process paths: " + ", ".join(map(str, sorted(missing))))


def related_processes(space, processes, open_paths, app_pid):
    roots = (str(space.work), str(space.work).replace("/private/tmp/", "/tmp/", 1))
    def inside(value):
        return any(value == root or value.startswith(root + "/") for root in roots)
    related = {pid for pid, process in processes.items()
               if any(root + "/" in process["command"] for root in roots)
               or any(inside(path) for values in open_paths.get(pid, {}).values() for path in values)}
    if app_pid in processes:
        related.add(app_pid)
    while True:
        children = {pid for pid, process in processes.items() if process["parent"] in related}
        if children <= related:
            break
        related |= children
    return {pid: processes[pid] for pid in related}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def owned_preference_path(space, bundle_id, real_home):
    space.verify_owner()
    if bundle_id != "invalid.example.brewery.nativeqa." + space.token[:12]:
        raise IsolationError("Preference bundle does not belong to this controller")
    parent = real_home / "Library/Preferences"
    if not parent.is_dir() or parent.resolve() != parent:
        raise IsolationError("Preference parent is missing or aliases another directory")
    return parent / (bundle_id + ".plist")


def inspect_owned_preference(path, before):
    absent = {"sha256": hashlib.sha256(json.dumps([str(path), "absent"]).encode()).hexdigest(), "entries": 1}
    if before != absent:
        raise IsolationError("Preference existed before this QA namespace; refusing removal")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as error:
        raise IsolationError("Preference is not an inspectable regular file") from error
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_nlink != 1 or stat.S_IMODE(st.st_mode) != 0o600 or st.st_size > 65536:
            raise IsolationError("Unexpected preference ownership, type, mode, links, or size")
        data = os.read(fd, 65537)
        end = os.fstat(fd)
        identity = lambda s: (s.st_dev, s.st_ino, s.st_uid, s.st_mode, s.st_size, s.st_mtime_ns)
        if identity(st) != identity(end) or len(data) != st.st_size:
            raise IsolationError("Preference changed while reading")
    finally:
        os.close(fd)
    try:
        contents = plistlib.loads(data)
        if not isinstance(contents, dict) or set(contents) != {WINDOW_LAYOUT_KEY, SPLIT_LAYOUT_KEY}:
            raise ValueError("Unexpected preference keys")
        def numbers(value, count, delimiter=None):
            return isinstance(value, str) and len(value) < 256 and len(value.split(delimiter)) == count and all(math.isfinite(float(x)) for x in value.split(delimiter))
        if not numbers(contents[WINDOW_LAYOUT_KEY], 8):
            raise ValueError("Unexpected window layout")
        rows = contents[SPLIT_LAYOUT_KEY]
        if not isinstance(rows, list) or not 1 <= len(rows) <= 8:
            raise ValueError("Unexpected split layout")
        for row in rows:
            if not isinstance(row, str) or len(row.split(",")) != 6:
                raise ValueError("Unexpected split row")
            pieces = row.split(",")
            if not numbers(",".join(pieces[:4]), 4, ",") or any(x.strip() not in ("YES", "NO") for x in pieces[4:]):
                raise ValueError("Unexpected split coordinates")
    except (ValueError, TypeError, plistlib.InvalidFileException) as error:
        raise IsolationError("Only the two fixed QA window-layout preferences can be removed") from error
    return {"path": str(path), "before_was_absent": True, "sha256": hashlib.sha256(data).hexdigest(),
            "device": st.st_dev, "inode": st.st_ino, "uid": st.st_uid, "mode": st.st_mode,
            "size": st.st_size, "mtime_ns": st.st_mtime_ns, "contents": contents,
            "exact_bytes_base64": base64.b64encode(data).decode()}


def unlink_verified_preference(space, bundle_id, real_home, before, evidence):
    # This helper has no CLI or reconnect entry point. The only path comes from
    # the live controller's own namespace token and original real home.
    path = owned_preference_path(space, bundle_id, real_home)
    if inspect_owned_preference(path, before) != evidence:
        raise IsolationError("Preference hash/identity/content changed; preserving it")
    directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        current = os.stat(path.name, dir_fd=directory_fd, follow_symlinks=False)
        if (current.st_dev, current.st_ino, current.st_uid, current.st_mode, current.st_size, current.st_mtime_ns) != tuple(evidence[k] for k in ("device", "inode", "uid", "mode", "size", "mtime_ns")):
            raise IsolationError("Preference identity changed before removal")
        os.unlink(path.name, dir_fd=directory_fd)
    finally:
        os.close(directory_fd)


def make_configuration(space, env, bundle_id, lease):
    environment = dict(env)
    environment.update(CFFIXED_USER_HOME=env["HOME"], TERM="dumb", PWD=str(space.work), PYTHONDONTWRITEBYTECODE="1")
    return {"root": str(space.root), "work": str(space.work), "inode": space.identity, "owner": space.token,
            "uid": os.getuid(), "bundle_id": bundle_id, "environment": environment,
            "paths": expected_configuration(space), "brew_sha256": digest(space.work / "brew/bin/brew"),
            "controller_pid": os.getpid(), "lease_inode": lease.identity}


def allowed_commands():
    commands = [["info", "--json=v2", "--installed"], ["outdated", "--json=v2"],
                ["info"], ["--version"], ["cleanup"], ["cleanup", "--dry-run"]]
    for option, packages in [("--formula", FORMULAE), ("--cask", CASKS)]:
        for package in packages:
            commands.extend([[operation, option, package] for operation in ["install", "upgrade", "uninstall", "info"]])
            commands.append(["info", "--json=v2", option, package])
    return commands


def render_guard(config):
    # Values come only from this process's generated namespace, never caller-supplied Swift.
    swift = lambda value: json.dumps(value, ensure_ascii=False)
    env = ",\n        ".join(swift(k) + ": " + swift(v) for k, v in sorted(config["environment"].items()))
    paths = ", ".join(swift(p) for p in config["paths"].values())
    return r'''import Foundation
import CryptoKit
import Darwin

nonisolated enum NativeHomebrewQA {
    static let root = ROOT
    static let work = WORK
    static let expectedBundleID = BUNDLE_ID
    static let environment: [String: String] = [ENVIRONMENT]
    static let allowed: [[String]] = ALLOWED
    static let brew = work + "/brew/bin/brew"
    static let logDirectory = work + "/app-logs"
    static let catalog = work + "/native-catalog.json"

    static func allows(_ arguments: [String]) -> Bool { allowed.contains(arguments) }

    static func controllerIsAlive() -> Bool {
        guard kill(CONTROLLER_PID, 0) == 0 else { return false }
        let path = root + "/.controller-lease"
        let fd = Darwin.open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_ino == LEASE_INODE, info.st_uid == EXPECTED_UID,
              info.st_mode & 0o777 == 0o600,
              (try? String(contentsOfFile: path, encoding: .utf8)) == OWNER else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    static func realPath(_ path: String) -> String? {
        guard let pointer = Darwin.realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    static func pathsAreValid() -> Bool {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        guard rootURL.deletingLastPathComponent().path == "/private/tmp",
              rootURL.lastPathComponent.hasPrefix("brewery-qa-"),
              realPath(root) == root,
              let attrs = try? fm.attributesOfItem(atPath: root),
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == EXPECTED_UID,
              (attrs[.systemFileNumber] as? NSNumber)?.uint64Value == EXPECTED_INODE,
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0,
              realPath(root + "/.owner") == root + "/.owner",
              (try? String(contentsOfFile: root + "/.owner", encoding: .utf8)) == OWNER else { return false }
        let paths = [PATHS]
        guard paths.allSatisfy({ path in
            path.hasPrefix(root + "/work/") && realPath(path) == path
        }), realPath(brew) == brew,
            fm.isExecutableFile(atPath: brew), let bytes = try? Data(contentsOf: URL(fileURLWithPath: brew)),
            SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == BREW_SHA else { return false }
        return true
    }

    static func foundationPaths() -> [String: String] {
        let fm = FileManager.default
        return ["nsHome": NSHomeDirectory(), "fileManagerHome": fm.homeDirectoryForCurrentUser.path,
                "library": fm.urls(for: .libraryDirectory, in: .userDomainMask).first?.path ?? "",
                "caches": fm.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? "",
                "applicationSupport": fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? "",
                "environmentHome": ProcessInfo.processInfo.environment["HOME"] ?? "",
                "posixHome": getenv("HOME").map { String(cString: $0) } ?? "",
                "fixedHome": ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? ""]
    }

    private static func expectedFoundationPaths() -> [String: String] {
        let home = environment["HOME"]!
        return ["nsHome": home, "fileManagerHome": home,
            "library": home + "/Library", "caches": home + "/Library/Caches",
            "applicationSupport": home + "/Library/Application Support",
            "environmentHome": home, "posixHome": home, "fixedHome": home]
    }

    static func foundationPathsAreValid() -> Bool {
        let actual = foundationPaths()
        return expectedFoundationPaths().allSatisfy { key, value in
            guard let path = actual[key], let resolved = realPath(path) else { return false }
            return resolved == value
        }
    }

    static func normalizeStartupHome() -> Bool {
        // Launch Services may replace HOME while CFFIXED_USER_HOME and actual
        // Foundation paths remain isolated. Never normalize a Foundation failure.
        guard pathsAreValid(), controllerIsAlive() else { return false }
        let actual = foundationPaths()
        let alreadyIsolated = expectedFoundationPaths().filter { key, _ in
            key != "environmentHome" && key != "posixHome"
        }.allSatisfy { key, value in
            guard let path = actual[key], let resolved = realPath(path) else { return false }
            return resolved == value
        }
        guard alreadyIsolated, setenv("HOME", environment["HOME"]!, 1) == 0 else { return false }
        return foundationPathsAreValid()
    }

    static func writeJSON(_ value: [String: Any], name: String) {
        guard pathsAreValid(), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: root + "/" + name), options: .atomic)
    }

    static func requireValidStartup() {
        let before = foundationPaths()
        let normalized = Bundle.main.bundleIdentifier == expectedBundleID && normalizeStartupHome()
        let valid = normalized && pathsAreValid() && controllerIsAlive() && foundationPathsAreValid()
        writeJSON(["status": valid ? "passed" : "failed", "pid": ProcessInfo.processInfo.processIdentifier,
                   "bundleID": Bundle.main.bundleIdentifier ?? "", "foundationPaths": foundationPaths(),
                   "foundationPathsBeforeHomeNormalization": before, "homeNormalizationSucceeded": normalized,
                   "brew": brew, "brewSHA256": BREW_SHA, "environment": environment,
                   "controllerPID": CONTROLLER_PID, "controllerLeaseValid": controllerIsAlive(),
                   "allowedCommands": allowed], name: "native-startup.json")
        guard valid, FileManager.default.changeCurrentDirectoryPath(work) else {
            fputs("Native Homebrew QA isolation failed; no ViewModel or Homebrew process started.\n", stderr)
            exit(78)
        }
    }

    static func record(arguments: [String], stdout: String, stderr: String, exitCode: Int32, duration: Double) {
        guard pathsAreValid() else { return }
        let object: [String: Any] = ["arguments": arguments, "stdout": stdout, "stderr": stderr,
            "exitCode": exitCode, "duration": duration, "time": Date().timeIntervalSince1970, "executable": brew]
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(10)
        let url = URL(fileURLWithPath: root + "/native-command-events.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else { try? data.write(to: url, options: .atomic) }
    }
}
'''.replace("ROOT", swift(config["root"])).replace("WORK", swift(config["work"])).replace("BUNDLE_ID", swift(config["bundle_id"])).replace("ENVIRONMENT", env).replace("ALLOWED", swift(allowed_commands())).replace("EXPECTED_UID", str(config["uid"])).replace("EXPECTED_INODE", str(config["inode"])).replace("OWNER", swift(config["owner"])).replace("PATHS", paths).replace("BREW_SHA", swift(config["brew_sha256"])).replace("CONTROLLER_PID", str(config["controller_pid"])).replace("LEASE_INODE", str(config["lease_inode"]))


CATALOG_SWIFT = r'''
@MainActor
final class NativeHomebrewQACatalog: CatalogServing {
    private func snapshot() throws -> CatalogSnapshot {
        guard NativeHomebrewQA.pathsAreValid() else { throw PackageInfoError.unavailable("QA namespace validation failed") }
        let data = try Data(contentsOf: URL(fileURLWithPath: NativeHomebrewQA.catalog))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let catalog = try decoder.decode(CatalogSnapshot.self, from: data)
        let expected: Set<String> = ["formula:brewery/qa/qa-formula", "formula:brewery/qa/qa-batch",
                                     "formula:brewery/qa/qa-permission", "cask:brewery/qa/qa-app"]
        guard Set(catalog.packages.map { $0.id.id }) == expected, catalog.packages.count == 4 else {
            throw PackageInfoError.unavailable("QA catalog contains unexpected packages")
        }
        return catalog
    }
    func loadLocalData(for window: RankingWindow) async throws -> DiscoverLocalData {
        DiscoverLocalData(catalog: try snapshot(), rankings: nil)
    }
    func refreshCatalogIfNeeded() async throws -> CatalogSnapshot? { try snapshot() }
    func refreshRankingsIfNeeded(for window: RankingWindow) async -> RankingRefreshResult {
        RankingRefreshResult(snapshot: nil, messages: [])
    }
}
'''


def source_hashes(repository):
    return {str(p.relative_to(repository)): digest(p) for base in ["Brewery", "Brewery.xcodeproj"]
            for p in sorted((repository / base).rglob("*")) if p.is_file() and "xcuserdata" not in p.parts}


class NativeSession:
    def __init__(self, repository, source):
        self.repository = repository.resolve()
        self.harness = Harness(source, keep=True)
        self.space = self.harness.space
        self.lease = ControllerLease(self.space)
        self.bundle_id = "invalid.example.brewery.nativeqa." + self.space.token[:12]
        self.phase = "1.0"
        self.snapshots = 0
        self.built_app = self.space.work / "derived/Build/Products/Debug/BreweryHomebrewQA.app"
        original_prefix = Path("/usr/local") if source.resolve() == Path("/usr/local/Homebrew") else source.resolve()
        home = Path.home()
        self.real_home = home
        self.owned_preference = owned_preference_path(self.space, self.bundle_id, home)
        self.protected = [original_prefix / x for x in ["Cellar", "Caskroom", "var/homebrew/locks", "etc/homebrew"]]
        self.protected += [home / "Library/Caches/Homebrew", home / "Library/Logs/Homebrew", home / "Applications",
                           Path("/Applications/Brewery QA.app"), source.resolve() / "bin/brew",
                           home / "Library/Logs/Brewery", home / "Library/Caches/Brewery",
                           home / "Library/Preferences/yyytir777.Brewery.plist",
                           home / ("Library/Preferences/" + self.bundle_id + ".plist"),
                           home / ("Library/Saved Application State/" + self.bundle_id + ".savedState")]
        self.before = {str(p): fingerprint(p) for p in self.protected}
        self.original_hashes = source_hashes(self.repository)
        (self.space.root / "native-product-source-hashes.json").write_text(json.dumps(self.original_hashes, indent=2, sort_keys=True))
        self.harness.report["protected_before"] = self.before
        self.harness.report["native_bundle_id"] = self.bundle_id
        self.harness.save()

    def write_catalog(self):
        packages = []
        for kind, names in [("formula", FORMULAE), ("cask", CASKS)]:
            for name in names:
                packages.append({"id": kind + ":" + name, "name": name, "kind": kind,
                                 "description": "Actual local Homebrew QA " + name.rsplit("/", 1)[1],
                                 "latestVersion": self.phase})
        (self.space.work / "native-catalog.json").write_text(json.dumps({"schemaVersion": 1,
            "generatedAt": time.time(), "packages": packages}, indent=2))

    def stage_sources(self, config):
        stage = self.space.work / "app-source"
        stage.mkdir()
        for name in ["Brewery", "Brewery.xcodeproj", "BreweryTests", "BreweryUITests"]:
            if (self.repository / name).exists():
                shutil.copytree(self.repository / name, stage / name, ignore=shutil.ignore_patterns("xcuserdata", ".DS_Store"))
        # These root files are explicit resources in the existing Xcode project.
        for name in ["README.md", ".gitignore"]:
            shutil.copy2(self.repository / name, stage / name)
        changes = {}
        command = stage / "Brewery/util/BreweryCommand.swift"
        original = command.read_text()
        changed = replace_once(original, '''    private nonisolated static let brewCandidatePaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew"
    ]''', '''    private nonisolated static let brewCandidatePaths = [NativeHomebrewQA.brew]''')
        changed = replace_once(changed, "            let start = Date()", '''            let start = Date()
            guard NativeHomebrewQA.allows(arguments), NativeHomebrewQA.pathsAreValid(), NativeHomebrewQA.controllerIsAlive(), NativeHomebrewQA.foundationPathsAreValid() else {
                return BreweryCommandResult(arguments: arguments, stdout: "", stderr: "Isolated QA command or namespace rejected; no fallback.", exitCode: 64)
            }''')
        anchor = "    private nonisolated static func resolveBrewURL() -> URL?"
        changed = replace_once(changed, braced_block(changed, anchor), anchor + ''' {
        guard NativeHomebrewQA.pathsAreValid(), NativeHomebrewQA.controllerIsAlive() else { return nil }
        return URL(fileURLWithPath: NativeHomebrewQA.brew)
    }''')
        anchor = "    private nonisolated static func makeEnvironment() -> [String: String]"
        changed = replace_once(changed, braced_block(changed, anchor), anchor + ''' {
        NativeHomebrewQA.environment
    }''')
        for anchor in ["    nonisolated static func makeProcess(", "    private nonisolated static func readOutput(",
                       "    nonisolated static func executeProcess(", "    private nonisolated static func drainOutput("]:
            if braced_block(original, anchor) != braced_block(changed, anchor):
                raise IsolationError("Core Process/output implementation changed")
        changes[command] = (original, changed)

        logger = stage / "Brewery/util/BreweryLogger.swift"
        original = logger.read_text()
        changed = replace_once(original, '''        let logsDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/Brewery", isDirectory: true)''',
                               '''        let logsDir = URL(fileURLWithPath: NativeHomebrewQA.logDirectory, isDirectory: true)''')
        changed = replace_once(changed, r'''        append(lines.joined(separator: "\n") + "\n")''', r'''        append(lines.joined(separator: "\n") + "\n")
        NativeHomebrewQA.record(arguments: result.arguments, stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode, duration: duration)''')
        changes[logger] = (original, changed)

        app = stage / "Brewery/BreweryApp.swift"
        original = app.read_text()
        changed = replace_once(original, braced_block(original, "    init() {"), '''    init() {
        NativeHomebrewQA.requireValidStartup()
        #if DEBUG
        uiTestFixture = nil
        #endif
        catalogService = NativeHomebrewQACatalog()
        _breweryViewModel = StateObject(wrappedValue: BreweryViewModel())
    }''')
        changed = replace_once(changed, braced_block(changed, "        Settings {"), '''        Settings {
            Text("Diagnostics controls are disabled in this isolated QA app.").padding(32)
        }''')
        changes[app] = (original, changed)
        diffs = []
        for path, (old, new) in changes.items():
            path.write_text(new)
            relative = str(path.relative_to(stage))
            diffs.extend(difflib.unified_diff(old.splitlines(True), new.splitlines(True), fromfile="original/" + relative,
                                            tofile="temporary/" + relative))
        (stage / "Brewery/NativeHomebrewQA.swift").write_text(render_guard(config) + CATALOG_SWIFT)
        (self.space.root / "native-source-transform.diff").write_text("".join(diffs))
        preserved = ["Brewery/model/BrewViewModel.swift", "Brewery/model/PackageOperation.swift",
                     "Brewery/View/OperationsView.swift", "Brewery/View/MainView.swift", "Brewery/Testing/BreweryUITestScenario.swift"]
        for name in preserved:
            self.harness.check(digest(stage / name) == digest(self.repository / name), "Unchanged native QA source: " + name)
        return stage

    def prepare(self):
        self.harness.prepare()
        self.write_catalog()
        config = make_configuration(self.space, self.harness.env, self.bundle_id, self.lease)
        self.harness.env = config["environment"]
        for name in ["Library/Caches", "Library/Application Support", "Library/Preferences", "Library/Saved Application State"]:
            (self.space.work / "home" / name).mkdir(parents=True, exist_ok=True)
        (self.space.root / "native-configuration.json").write_text(json.dumps(config, indent=2))
        stage = self.stage_sources(config)
        # Console-only Foundation probe: this executable has no AppKit/SwiftUI entry point.
        probe = self.space.work / "foundation-probe.swift"
        probe.write_text(render_guard(config) + '\nlet result: [String: Any] = ["valid": NativeHomebrewQA.foundationPathsAreValid() && NativeHomebrewQA.pathsAreValid() && NativeHomebrewQA.controllerIsAlive(), "controllerLeaseValid": NativeHomebrewQA.controllerIsAlive(), "paths": NativeHomebrewQA.foundationPaths()]\nprint(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)\n')
        executable = self.space.work / "foundation-probe"
        self.harness.run(["/usr/bin/xcrun", "swiftc", "-module-cache-path", self.space.work / "swift-module-cache", probe, "-o", executable])
        output = self.harness.run([executable])
        probe_result = json.loads(output.strip())
        self.harness.check(probe_result["valid"] is True, "Console Foundation HOME/library/cache/application-support paths are isolated")
        (self.space.root / "foundation-probe.json").write_text(json.dumps(probe_result, indent=2))
        self.harness.run(["/usr/bin/xcodebuild", "-project", stage / "Brewery.xcodeproj", "-scheme", "Brewery",
                          "-configuration", "Debug", "-derivedDataPath", self.space.work / "derived",
                          "-disableAutomaticPackageResolution", "-skipPackageUpdates", "CODE_SIGNING_ALLOWED=NO",
                          "PRODUCT_NAME=BreweryHomebrewQA", "PRODUCT_BUNDLE_IDENTIFIER=" + self.bundle_id,
                          "CLANG_MODULE_CACHE_PATH=" + str(self.space.work / "clang-module-cache"),
                          "SWIFT_MODULECACHE_PATH=" + str(self.space.work / "swift-module-cache"), "build"], timeout=300)
        plist_path = self.built_app / "Contents/Info.plist"
        with plist_path.open("rb") as stream:
            plist = plistlib.load(stream)
        plist["LSEnvironment"] = config["environment"]
        plist["CFBundleDisplayName"] = "Brewery Actual Homebrew QA"
        plist["NSQuitAlwaysKeepsWindows"] = False
        plist.pop("BreweryUITestScenario", None)
        with plist_path.open("wb") as stream:
            plistlib.dump(plist, stream)
        self.harness.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", self.built_app])
        self.harness.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", self.built_app])
        self.ensure_idle(allow_app=False)
        self.harness.check(source_hashes(self.repository) == self.original_hashes, "Repository product/project files unchanged by QA preparation")
        self.harness.report["native_status"] = "ready_for_cua_launch"
        self.harness.report["native_app"] = str(self.built_app)
        self.harness.save()
        result = {"status": "ready_for_cua_launch", "app": str(self.built_app), "bundle_id": self.bundle_id,
                  "root": str(self.space.root), "actions": ACTIONS,
                  "required_before_ui_mutation": "Read native-startup.json after CUA launch; status must be passed"}
        (self.space.root / "native-ready.json").write_text(json.dumps(result, indent=2))
        return result

    def process_listing(self):
        result = subprocess.run(["/bin/ps", "-U", str(os.getuid()), "-o", "pid=,ppid=,stat=,command="],
                                capture_output=True, text=True, check=True, timeout=15)
        if result.stderr:
            raise IsolationError("Process inspection warning; namespace retained")
        return parse_processes(result.stdout)

    def ensure_idle(self, allow_app=True):
        before = self.process_listing()
        result = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-u", str(os.getuid()), "-d", "cwd,txt", "-F", "pfn"],
                                capture_output=True, text=True, check=True, timeout=15)
        if result.stderr:
            raise IsolationError("Open-file inspection warning; namespace retained")
        paths = parse_open_paths(result.stdout)
        after = self.process_listing()
        require_inspection_complete(before, after, paths)
        startup = self.space.root / "native-startup.json"
        app_pid = json.loads(startup.read_text()).get("pid") if startup.exists() else None
        processes = related_processes(self.space, after, paths, app_pid)
        app_executable = str(self.built_app / "Contents/MacOS/BreweryHomebrewQA")
        app_aliases = (app_executable, app_executable.replace("/private/tmp/", "/tmp/", 1))
        unexpected = [pid for pid, process in processes.items()
                      if not (allow_app and pid == app_pid and process["command"] in app_aliases
                              and any(path in app_aliases for path in paths.get(pid, {}).get("txt", [])))]
        if unexpected:
            raise IsolationError("Wait for related processes to finish (PIDs): " + ", ".join(map(str, sorted(unexpected))))

    def action(self, action):
        action = parse_action(action)
        self.space.verify_owner()
        self.ensure_idle(allow_app=action != "finish")
        startup = self.space.root / "native-startup.json"
        if not startup.exists() or json.loads(startup.read_text()).get("status") != "passed":
            raise IsolationError("CUA app launch has not produced a passing native-startup.json")
        if action == "advance-to-2.0":
            if self.phase != "1.0":
                raise IsolationError("Fixture version is already 2.0")
            self.harness.fixtures("2.0")
            self.harness.denied.chmod(0o400)
            self.phase = "2.0"
            self.write_catalog()
        elif action == "repair-permission":
            self.space.inside(self.harness.denied)
            self.harness.denied.chmod(0o600)
        elif action == "snapshot":
            self.snapshots += 1
            self.harness.snapshot("native-snapshot-%02d" % self.snapshots)
        elif action == "finish":
            final = self.harness.snapshot("native-final")
            if final["inventory"]["formulae"] or final["inventory"]["casks"] or final["app_exists"]:
                raise IsolationError("Uninstall fixtures through the app before finish; namespace retained")
            strict = [p for p in self.protected if p != self.owned_preference]
            if any(fingerprint(p) != self.before[str(p)] for p in strict):
                raise IsolationError("Existing protected paths changed; namespace and preference retained")
            removed_preference = self.remove_own_window_preference()
            self.harness.report["real_home_preference_side_effect"] = (
                "Task-created window-layout preference was verified and removed; see native-preference-cleanup.jsonl"
                if removed_preference else "No task preference existed at finish")
            after = {str(p): fingerprint(p) for p in self.protected}
            self.harness.report["protected_after"] = after
            self.harness.report["protected_unchanged"] = self.before == after
            if after != self.before:
                raise IsolationError("Protected paths changed; namespace retained for inspection")
            self.ensure_idle(allow_app=False)
            self.harness.report["native_status"] = "namespace_verified"
            self.harness.report["native_scenarios"] = "not_assessed; root must correlate actual command/files and CUA evidence"
            self.harness.report["status"] = "namespace_verified"
            self.harness.keep = False
            self.harness.finish()
        return {"action": action, "phase": self.phase, "root": str(self.space.root), "status": "ok"}

    def remove_own_window_preference(self):
        path = owned_preference_path(self.space, self.bundle_id, self.real_home)
        if not os.path.lexists(path):
            return False
        self.ensure_idle(allow_app=False)
        evidence = inspect_owned_preference(path, self.before[str(path)])
        time.sleep(1)
        if inspect_owned_preference(path, self.before[str(path)]) != evidence:
            raise IsolationError("Preference has not stopped changing; preserving it")
        audit = self.space.root / "native-preference-cleanup.jsonl"
        def record(event):
            with audit.open("a") as stream:
                stream.write(json.dumps({"time": time.time(), **event}, sort_keys=True) + "\n")
        record({"action": "verified_before_removal", "evidence": evidence})
        self.ensure_idle(allow_app=False)
        unlink_verified_preference(self.space, self.bundle_id, self.real_home, self.before[str(path)], evidence)
        record({"action": "removed_task_created_window_preference", "path": str(path), "sha256": evidence["sha256"]})
        time.sleep(1)
        absent = not os.path.lexists(path)
        record({"action": "absence_recheck", "absent": absent})
        if not absent:
            raise IsolationError("Preference was recreated; preserving namespace and regenerated file")
        return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("/opt/homebrew"), help="Read-only local Homebrew source")
    args = parser.parse_args()
    session = NativeSession(Path(__file__).resolve().parents[2], args.source)
    print(json.dumps({"status": "preparing", "root": str(session.space.root)}), flush=True)
    try:
        print(json.dumps(session.prepare()), flush=True)
        for line in sys.stdin:
            try:
                result = session.action(line)
                print(json.dumps(result), flush=True)
                if result["action"] == "finish":
                    return 0
            except (IsolationError, OSError, ValueError) as error:
                print(json.dumps({"status": "refused", "error": str(error)}), flush=True)
        raise IsolationError("Controller stdin closed; preserving namespace because app may still be alive")
    except BaseException as error:
        session.harness.report["native_status"] = "interrupted_or_failed"
        session.harness.report["native_error"] = str(error)
        session.harness.save()
        print(json.dumps({"status": "preserved", "root": str(session.space.root), "error": str(error)}), flush=True)
        return 1
    finally:
        session.lease.close()


if __name__ == "__main__":
    sys.exit(main())
