"""Safety contracts for the generated native QA app; never launches an app."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import isolated_homebrew as isolated

SCRIPT = Path(__file__).with_name("native_homebrew_app.py")
native = None
if SCRIPT.exists():
    spec = importlib.util.spec_from_file_location("native_homebrew_app", SCRIPT)
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)


class NativeHomebrewSafetyTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(native, "Native QA preparation tool is missing")
        self.space = isolated.Workspace()
        self.addCleanup(self.space.remove_all)

    def test_source_patch_rejects_missing_or_ambiguous_anchors(self):
        self.assertEqual(native.replace_once("abc def", "def", "xyz"), "abc xyz")
        for original in ["abc", "def def"]:
            with self.assertRaises(isolated.IsolationError):
                native.replace_once(original, "def", "xyz")

    def test_cleanup_cannot_run_while_any_work_process_is_alive(self):
        listing = "123 1 S /opt/homebrew/bin/brew info\n456 1 S %s/app/Brewery\n789 456 S /bin/sleep 60\n900 1 S /bin/sleep 60\n999 1 Z <defunct>\n" % self.space.work
        processes = native.parse_processes(listing)
        self.assertNotIn(999, processes)
        paths = native.parse_open_paths("p900\nfcwd\nn%s\nftxt\nn/bin/sleep\n" % self.space.work)
        self.assertEqual(set(native.related_processes(self.space, processes, paths, 456)), {456, 789, 900})
        aliases = native.parse_processes(listing.replace("/private/tmp/", "/tmp/"))
        self.assertIn(456, native.related_processes(self.space, aliases, {}, None))
        with self.assertRaises(isolated.IsolationError):
            native.require_inspection_complete(processes, processes, paths)
        with self.assertRaises(isolated.IsolationError):
            native.parse_processes("unexpected output")

    def test_controller_lease_is_exclusive_and_not_inherited(self):
        with native.ControllerLease(self.space) as lease:
            self.assertFalse(os.get_inheritable(lease.fd))
            with self.assertRaises(isolated.IsolationError):
                native.ControllerLease(self.space)

    def test_actual_owned_sleep_with_only_cwd_in_namespace_blocks_idle(self):
        # No app or Homebrew invocation. Only this test's child is terminated.
        child = subprocess.Popen(["/bin/sleep", "60"], cwd=self.space.work, start_new_session=True)
        try:
            session = native.NativeSession.__new__(native.NativeSession)
            session.space = self.space
            session.built_app = self.space.work / "unused.app"
            with self.assertRaisesRegex(isolated.IsolationError, str(child.pid)):
                session.ensure_idle(allow_app=False)
        finally:
            child.terminate()
            child.wait(timeout=10)

    def test_control_rejects_arbitrary_commands_paths_and_arguments(self):
        for value in ["rm -rf /", "snapshot /opt/homebrew", "advance-to-3.0", "finish --force", "repair-permission /tmp/x"]:
            with self.subTest(value=value), self.assertRaises(isolated.IsolationError):
                native.parse_action(value)
        self.assertEqual(native.parse_action("snapshot\n"), "snapshot")
        self.assertEqual(native.parse_action("advance-to-2.0"), "advance-to-2.0")

    def test_preference_cleanup_accepts_only_new_exact_layout_file(self):
        home = self.space.work / "test-home"
        (home / "Library/Preferences").mkdir(parents=True)
        bundle = "invalid.example.brewery.nativeqa." + self.space.token[:12]
        path = native.owned_preference_path(self.space, bundle, home)
        before = isolated.fingerprint(path)
        payload = {native.WINDOW_LAYOUT_KEY: "0 0 900 600 0 0 1920 1080 ",
                   native.SPLIT_LAYOUT_KEY: ["0.000000, 0.000000, 198.000000, 600.000000, NO, NO"]}
        path.write_bytes(plistlib.dumps(payload))
        path.chmod(0o600)
        evidence = native.inspect_owned_preference(path, before)
        self.assertEqual(evidence["contents"], payload)
        self.assertEqual(evidence["inode"], path.stat().st_ino)
        with self.assertRaises(isolated.IsolationError):
            native.owned_preference_path(self.space, "yyytir777.Brewery", home)
        with self.assertRaises(isolated.IsolationError):
            native.inspect_owned_preference(path, isolated.fingerprint(path))
        payload["UserSetting"] = True
        path.write_bytes(plistlib.dumps(payload))
        with self.assertRaises(isolated.IsolationError):
            native.inspect_owned_preference(path, before)
        path.unlink()
        path.symlink_to(self.space.root / ".owner")
        with self.assertRaises(isolated.IsolationError):
            native.inspect_owned_preference(path, before)

    def test_preference_unlink_rechecks_exact_hash_inode_and_keys(self):
        home = self.space.work / "test-home"
        (home / "Library/Preferences").mkdir(parents=True)
        bundle = "invalid.example.brewery.nativeqa." + self.space.token[:12]
        path = native.owned_preference_path(self.space, bundle, home)
        before = isolated.fingerprint(path)
        payload = {native.WINDOW_LAYOUT_KEY: "0 0 900 600 0 0 1920 1080 ",
                   native.SPLIT_LAYOUT_KEY: ["0, 0, 198, 600, NO, NO"]}
        path.write_bytes(plistlib.dumps(payload)); path.chmod(0o600)
        evidence = native.inspect_owned_preference(path, before)
        payload[native.WINDOW_LAYOUT_KEY] = "1 1 900 600 0 0 1920 1080 "
        path.write_bytes(plistlib.dumps(payload))
        with self.assertRaises(isolated.IsolationError):
            native.unlink_verified_preference(self.space, bundle, home, before, evidence)
        self.assertTrue(path.exists())
        evidence = native.inspect_owned_preference(path, before)
        replacement = path.with_suffix(".replacement")
        replacement.write_bytes(path.read_bytes()); replacement.chmod(0o600)
        replacement.replace(path)
        with self.assertRaises(isolated.IsolationError):
            native.unlink_verified_preference(self.space, bundle, home, before, evidence)
        evidence = native.inspect_owned_preference(path, before)
        native.unlink_verified_preference(self.space, bundle, home, before, evidence)
        self.assertFalse(path.exists())

    def test_recreated_preference_is_preserved_and_audited(self):
        home = self.space.work / "test-home"
        (home / "Library/Preferences").mkdir(parents=True)
        session = native.NativeSession.__new__(native.NativeSession)
        session.space, session.real_home = self.space, home
        session.bundle_id = "invalid.example.brewery.nativeqa." + self.space.token[:12]
        path = native.owned_preference_path(self.space, session.bundle_id, home)
        session.before = {str(path): isolated.fingerprint(path)}
        session.ensure_idle = lambda **_: None  # Only an inert temporary file exists in this test.
        payload = {native.WINDOW_LAYOUT_KEY: "0 0 900 600 0 0 1920 1080 ",
                   native.SPLIT_LAYOUT_KEY: ["0, 0, 198, 600, NO, NO"]}
        original = plistlib.dumps(payload)
        path.write_bytes(original); path.chmod(0o600)
        pauses = []
        def recreate_after_removal(_):
            pauses.append(True)
            if len(pauses) == 2:
                path.write_bytes(original); path.chmod(0o600)
        with mock.patch.object(native.time, "sleep", side_effect=recreate_after_removal):
            with self.assertRaisesRegex(isolated.IsolationError, "recreated"):
                session.remove_own_window_preference()
        self.assertTrue(path.exists(), "A recreated file must not be repeatedly removed")
        audit = [json.loads(line) for line in (self.space.root / "native-preference-cleanup.jsonl").read_text().splitlines()]
        self.assertEqual([item["action"] for item in audit], ["verified_before_removal", "removed_task_created_window_preference", "absence_recheck"])
        self.assertFalse(audit[-1]["absent"])

    def test_generated_swift_guard_enforces_command_and_path_boundary(self):
        launcher = self.space.work / "brew/bin/brew"
        launcher.parent.mkdir(parents=True)
        launcher.write_text("#!/bin/sh\nexit 0\n")
        launcher.chmod(0o555)
        env = isolated.isolated_environment(self.space)
        for path in isolated.expected_configuration(self.space).values():
            Path(path).mkdir(parents=True, exist_ok=True)
        lease = native.ControllerLease(self.space)
        self.addCleanup(lease.close)
        config = native.make_configuration(self.space, env, "invalid.example.brewery.qa.tests", lease)
        for name in ["Library/Caches", "Library/Application Support"]:
            (self.space.work / "home" / name).mkdir(parents=True, exist_ok=True)
        source = self.space.work / "Guard.swift"
        source.write_text(native.render_guard(config) + r'''
if CommandLine.arguments.contains("normalize-home") {
    let before = NativeHomebrewQA.foundationPaths()
    let normalized = NativeHomebrewQA.normalizeStartupHome()
    let result: [String: Any] = ["normalized": normalized, "before": before,
        "after": NativeHomebrewQA.foundationPaths(), "valid": NativeHomebrewQA.foundationPathsAreValid()]
    print(String(data: try! JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
    exit(0)
}
if CommandLine.arguments.contains("lease-only") {
    print(NativeHomebrewQA.controllerIsAlive() ? "alive" : "revoked")
    exit(0)
}
precondition(NativeHomebrewQA.controllerIsAlive())
let valid = [["info", "--json=v2", "--installed"], ["cleanup"],
             ["install", "--formula", "brewery/qa/qa-formula"],
             ["upgrade", "--cask", "brewery/qa/qa-app"]]
let invalid = [["update"], ["uninstall", "--cask", "--zap", "brewery/qa/qa-app"],
               ["install", "--formula", "git"], ["install", "--formula", "qa-formula"],
               ["install", "--cask", "brewery/qa/qa-formula"],
               ["install", "--formula", "brewery/qa/qa-formula", "brewery/qa/qa-batch"]]
precondition(valid.allSatisfy(NativeHomebrewQA.allows))
precondition(!invalid.contains(where: NativeHomebrewQA.allows))
if !NativeHomebrewQA.pathsAreValid() {
    FileHandle.standardError.write(Data("Invalid paths: \(NativeHomebrewQA.root), canonical \(URL(fileURLWithPath: NativeHomebrewQA.root).resolvingSymlinksInPath().path), \(try! FileManager.default.attributesOfItem(atPath: NativeHomebrewQA.root)); brew \(NativeHomebrewQA.brew) canonical \(URL(fileURLWithPath: NativeHomebrewQA.brew).resolvingSymlinksInPath().path)\n".utf8))
}
precondition(NativeHomebrewQA.pathsAreValid())
let cache = NativeHomebrewQA.work + "/cache"
try! FileManager.default.moveItem(atPath: cache, toPath: cache + "-saved")
try! FileManager.default.createSymbolicLink(atPath: cache, withDestinationPath: "/opt/homebrew")
precondition(!NativeHomebrewQA.pathsAreValid())
try! FileManager.default.removeItem(atPath: cache)
try! FileManager.default.moveItem(atPath: cache + "-saved", toPath: cache)
precondition(NativeHomebrewQA.pathsAreValid())
precondition(!NativeHomebrewQA.foundationPathsAreValid())
try! "replacement".write(toFile: NativeHomebrewQA.root + "/.owner", atomically: true, encoding: .utf8)
precondition(!NativeHomebrewQA.pathsAreValid())
print("guard checks passed")
''')
        executable = self.space.work / "guard-tests"
        result = subprocess.run(["/usr/bin/xcrun", "swiftc", "-module-cache-path", str(self.space.work / "module-cache"),
                                 str(source), "-o", str(executable)], env=env, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr)
        mismatched = dict(config["environment"], HOME=str(Path.home()))
        result = subprocess.run([str(executable), "normalize-home"], env=mismatched, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        normalized = json.loads(result.stdout)
        self.assertTrue(normalized["normalized"])
        self.assertTrue(normalized["valid"])
        self.assertEqual(normalized["before"]["environmentHome"], str(Path.home()))
        self.assertEqual(normalized["after"]["environmentHome"], env["HOME"])
        outside = dict(mismatched, CFFIXED_USER_HOME=str(Path.home()))
        result = subprocess.run([str(executable), "normalize-home"], env=outside, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        rejected = json.loads(result.stdout)
        self.assertFalse(rejected["normalized"])
        self.assertFalse(rejected["valid"])
        self.assertEqual(rejected["before"]["environmentHome"], rejected["after"]["environmentHome"])
        try:
            result = subprocess.run([str(executable)], env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "guard checks passed")
        finally:
            (self.space.root / ".owner").write_text(self.space.token)
        lease.close()
        result = subprocess.run([str(executable), "lease-only"], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "revoked", "Same controller PID stays alive, but closing the lease must revoke commands")


if __name__ == "__main__":
    unittest.main()
