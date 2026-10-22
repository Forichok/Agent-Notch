from pathlib import Path
import shutil
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class LocalReleaseChecks(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.root = Path(self.workspace.name)
        for folder in ["scripts", "packaging"]:
            (self.root / folder).mkdir()
        for name in ["prepare-release.sh", "release-notes.py"]:
            source = ROOT / "scripts" / name
            if source.exists():
                shutil.copy2(source, self.root / "scripts" / name)
        shutil.copy2(ROOT / "packaging/agent-notch.rb", self.root / "packaging/agent-notch.rb")
        (self.root / "packaging/install-notes.md").write_text("Installation note.\n")
        (self.root / "CHANGELOG.md").write_text("## [Unreleased]\nfuture\n## [0.5.0] - 2026-10-15\n\n### Added\n\n- Signed in-app updates.\n\n## [0.4.0]\nold notes\n")
        (self.root / ".gitignore").write_text("dist/\n")
        self.script("test.sh", "exit 0")
        # Compile/package/sign commands are the expensive subprocess boundary; preserve their artifacts and errors.
        self.script("package.sh", "rm -rf dist; mkdir dist; printf hello > dist/AgentNotch-0.5.0.zip; printf dmg > dist/AgentNotch-0.5.0.dmg; printf saver > dist/AgentNotchHouse-0.5.0.saver.zip; printf checksums > dist/SHA256SUMS.txt")
        self.script("appcast.sh", "test -s dist/notes.md; printf signed-feed > dist/appcast.xml")
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        self.commit()

    def tearDown(self):
        self.workspace.cleanup()

    def script(self, name, contents):
        file = self.root / "scripts" / name
        file.write_text("#!/bin/sh\nset -eu\n" + contents + "\n")
        file.chmod(0o755)

    def commit(self):
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(["git", "-c", "user.name=Checks", "-c", "user.email=checks@example.invalid", "commit", "-qm", "fixture"], cwd=self.root, check=True)

    def prepare(self, version="0.5.0", **overrides):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("UPDATE_", "SPARKLE_"))}
        env.update(overrides)
        return subprocess.run(["sh", "scripts/prepare-release.sh", version], cwd=self.root, env=env, capture_output=True, text=True)

    def test_prepares_signed_assets_and_cask_without_publishing(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        notes = (self.root / "dist/notes.md").read_text()
        self.assertIn("Signed in-app updates.", notes)
        self.assertIn("Installation note.", notes)
        self.assertNotIn("old notes", notes)
        self.assertNotIn("future", notes)
        cask = (self.root / "dist/agent-notch.rb").read_text()
        self.assertIn('version "0.5.0"', cask)
        self.assertIn('sha256 "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"', cask)
        self.assertEqual(subprocess.check_output(["git", "tag"], cwd=self.root, text=True), "")

    def test_signing_failure_stops_before_release_is_ready(self):
        self.script("appcast.sh", "exit 11")
        self.commit()
        result = self.prepare()
        self.assertEqual(result.returncode, 11, result.stderr)
        self.assertFalse((self.root / "dist/agent-notch.rb").exists())

    def test_failed_checks_stop_before_packaging(self):
        self.script("test.sh", "exit 12")
        self.commit()
        result = self.prepare()
        self.assertEqual(result.returncode, 12, result.stderr)
        self.assertFalse((self.root / "dist").exists())

    def test_missing_changelog_stops_before_packaging(self):
        result = self.prepare("0.5.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CHANGELOG.md", result.stderr)
        self.assertFalse((self.root / "dist").exists())

    def test_dirty_sources_are_not_released(self):
        (self.root / "CHANGELOG.md").write_text("changed")
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean", result.stderr)
        self.assertFalse((self.root / "dist").exists())

    def test_prerelease_cannot_enter_stable_release(self):
        result = self.prepare("0.5.0-beta.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stable X.Y.Z", result.stderr)
        self.assertFalse((self.root / "dist").exists())

    def test_test_configuration_cannot_be_released(self):
        result = self.prepare(UPDATE_TEST_BUNDLE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("test updater overrides", result.stderr)
        self.assertFalse((self.root / "dist").exists())

    def test_unversioned_sources_are_not_released(self):
        shutil.rmtree(self.root / ".git")
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "dist").exists())

    def test_checksum_failure_stops_before_cask_is_written(self):
        tools = self.root / "tools"
        tools.mkdir()
        checksum = tools / "shasum"
        checksum.write_text("#!/bin/sh\nexit 13\n")
        checksum.chmod(0o755)
        self.commit()
        result = self.prepare(PATH=str(tools) + os.pathsep + os.environ["PATH"])
        self.assertEqual(result.returncode, 13, result.stderr)
        self.assertFalse((self.root / "dist/agent-notch.rb").exists())
