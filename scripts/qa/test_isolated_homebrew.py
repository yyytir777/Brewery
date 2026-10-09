"""Behavioral safety tests. These never invoke Homebrew or change its installation."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import threading
import time
import unittest

SCRIPT = Path(__file__).with_name("isolated_homebrew.py")
spec = importlib.util.spec_from_file_location("isolated_homebrew", SCRIPT)
qa = None
if SCRIPT.exists():
    qa = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(qa)


class IsolationTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(qa, "isolated Homebrew safety harness is missing")
        self.space = qa.Workspace()
        self.addCleanup(self.space.remove_all)

    def test_generated_workspace_is_private_and_outside_normal_brew(self):
        self.assertEqual(self.space.root.parent, Path("/private/tmp"))
        self.assertEqual(self.space.root.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.space.inside(self.space.work / "brew"), self.space.work / "brew")

    def test_root_and_sibling_cannot_be_cleanup_targets(self):
        for path in [self.space.root, Path("/opt/homebrew"), Path("/usr/local"),
                     Path.home(), self.space.root.parent / (self.space.root.name + "-other")]:
            with self.subTest(path=path), self.assertRaises(qa.IsolationError):
                self.space.inside(path)

    def test_symlink_escape_is_rejected_before_write(self):
        (self.space.work / "escape").symlink_to("/opt")
        with self.assertRaises(qa.IsolationError):
            self.space.inside(self.space.work / "escape" / "homebrew" / "anything")

    def test_cleanup_refuses_replaced_ownership_marker(self):
        marker = self.space.root / ".owner"
        original = marker.read_text()
        marker.write_text("unrelated workspace")
        with self.assertRaises(qa.IsolationError):
            self.space.clean_work()
        self.assertTrue(self.space.work.exists())
        marker.write_text(original)

    def test_cleanup_deletes_only_generated_work_and_preserves_evidence(self):
        (self.space.work / "fixture").write_text("disposable")
        (self.space.root / "result.json").write_text("evidence")
        self.space.clean_work()
        self.assertFalse(self.space.work.exists())
        self.assertEqual((self.space.root / "result.json").read_text(), "evidence")

    def test_environment_does_not_inherit_user_configuration(self):
        os.environ["HOMEBREW_PREFIX"] = "/opt/homebrew"
        os.environ["HOMEBREW_CASK_OPTS"] = "--appdir=/Applications"
        os.environ["RUBYOPT"] = "-r/injected.rb"
        self.addCleanup(os.environ.pop, "RUBYOPT", None)
        self.addCleanup(os.environ.pop, "HOMEBREW_PREFIX", None)
        self.addCleanup(os.environ.pop, "HOMEBREW_CASK_OPTS", None)
        env = qa.isolated_environment(self.space)
        self.assertNotIn("HOMEBREW_PREFIX", env)
        self.assertNotIn("RUBYOPT", env)
        self.assertNotIn("HOMEBREW_AVOID_NESTED_SANDBOXING", env)
        self.assertEqual(env["HOME"], str(self.space.work / "home"))
        self.assertEqual(env["HOMEBREW_CASK_OPTS"], "--appdir=" + str(self.space.work / "Applications"))
        for key in ["HOME", "TMPDIR", "HOMEBREW_CACHE", "HOMEBREW_LOGS", "HOMEBREW_TEMP",
                    "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"]:
            self.space.inside(Path(env[key]))

    def test_homebrew_configuration_escape_aborts(self):
        config = qa.expected_configuration(self.space)
        config["cache"] = str(Path.home() / "Library/Caches/Homebrew")
        with self.assertRaises(qa.IsolationError):
            qa.validate_configuration(self.space, config)

    def test_homebrew_configuration_mismatch_inside_workspace_aborts(self):
        config = qa.expected_configuration(self.space)
        config["prefix"] = str(self.space.work / "unexpected")
        with self.assertRaises(qa.IsolationError):
            qa.validate_configuration(self.space, config)

    def test_source_asset_link_escape_is_rejected(self):
        source = self.space.work / "source"
        source.mkdir()
        (source / "runtime").symlink_to("/bin/sh")
        with self.assertRaises(qa.IsolationError):
            qa.validate_copy_tree(source)

    def test_copied_launcher_is_read_only_and_keeps_its_contents(self):
        self.assertTrue(hasattr(qa, "protect_copied_launcher"), "Copied launcher must be read-only before Homebrew starts")
        launcher = self.space.work / "brew/bin/brew"
        launcher.parent.mkdir(parents=True)
        launcher.write_text("#!/bin/bash\nprintf fixture\n")
        launcher.chmod(0o755)
        qa.protect_copied_launcher(self.space)
        self.assertEqual(launcher.read_text(), "#!/bin/bash\nprintf fixture\n")
        self.assertEqual(launcher.stat().st_mode & 0o777, 0o555)

    def test_copied_launcher_symlink_is_rejected_before_chmod(self):
        self.assertTrue(hasattr(qa, "protect_copied_launcher"), "Copied launcher guard is missing")
        launcher = self.space.work / "brew/bin/brew"
        launcher.parent.mkdir(parents=True)
        launcher.symlink_to("/opt/homebrew/bin/brew")
        with self.assertRaises(qa.IsolationError):
            qa.protect_copied_launcher(self.space)

    def test_network_tools_reject_remote_protocol_before_connecting(self):
        self.assertTrue(hasattr(qa, "configure_local_downloads"), "Remote downloads must be refused")
        env = qa.isolated_environment(self.space)
        qa.configure_local_downloads(self.space)
        git = subprocess.run(["/usr/bin/git", "ls-remote", "https://example.invalid/brewery-qa"], env=env,
                             capture_output=True, text=True, timeout=5)
        self.assertIn("transport 'https' not allowed", git.stderr)
        curl = subprocess.run(["/usr/bin/curl", "--disable", "--config", env["HOMEBREW_CURLRC"],
                               "https://example.invalid/brewery-qa"], env=env, capture_output=True, text=True, timeout=5)
        self.assertNotEqual(curl.returncode, 0)
        self.assertIn("disabled", curl.stderr)

    def test_interrupt_terminates_child_before_cleanup(self):
        harness = qa.Harness(Path("/opt/homebrew"))
        self.addCleanup(harness.space.remove_all)
        marker = harness.space.work / "child.pid"
        interrupted = threading.Event()

        def interrupt():
            for _ in range(200):
                if marker.exists():
                    interrupted.set()
                    os.kill(os.getpid(), signal.SIGINT)
                    return
                time.sleep(0.01)

        thread = threading.Thread(target=interrupt, daemon=True)
        thread.start()
        try:
            with self.assertRaises(KeyboardInterrupt):
                harness.run(["/usr/bin/python3", "-c", "import os,time; open(%r,'w').write(str(os.getpid())); time.sleep(10)" % str(marker)])
            child = int(marker.read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
        finally:
            thread.join(timeout=3)
            if marker.exists():
                try:
                    os.killpg(int(marker.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    unittest.main()
