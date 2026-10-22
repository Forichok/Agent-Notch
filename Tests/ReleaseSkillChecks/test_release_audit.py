import base64
import hashlib
import html
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".agents/skills/release-agent-notch/scripts/release_audit.py"
spec = importlib.util.spec_from_file_location("release_audit", SCRIPT)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
VERSION = "0.5.0"
REVISION = "a" * 40

class ReleaseAuditChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory()
        cls.temp = Path(cls.workspace.name)
        signer = cls.temp / "sign.swift"
        signer.write_text("""
import CryptoKit
import Foundation
let path = URL(fileURLWithPath: CommandLine.arguments[1])
let key: Curve25519.Signing.PrivateKey
if let data = try? Data(contentsOf: path) {
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
} else {
    key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
}
if CommandLine.arguments.count == 2 {
    print(key.publicKey.rawRepresentation.base64EncodedString())
} else {
    print(try key.signature(for: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))).base64EncodedString())
}
""")
        cls.signer, cls.verifier = cls.temp / "sign", cls.temp / "verify"
        for source, output in [(signer, cls.signer), (ROOT / "scripts/verify-update-signature.swift", cls.verifier)]:
            subprocess.run(["xcrun", "swiftc", str(source), "-o", str(output)], check=True)
        cls.seed = cls.temp / "seed"
        cls.key = subprocess.check_output([str(cls.signer), str(cls.seed)], text=True).strip()

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(dir=self.temp))
        self.info = dict(CFBundleIdentifier="com.forichok.agents-notch",
            CFBundleVersion=VERSION, CFBundleShortVersionString=VERSION,
            AgentNotchSourceRevision=REVISION, AgentNotchBaseRevision=REVISION,
            AgentNotchSourceDirty=False, SUPublicEDKey=self.key, SUFeedURL=audit.FEED,
            SUEnableAutomaticChecks=False, SUAllowsAutomaticUpdates=False,
            SUAutomaticallyUpdate=False, SUVerifyUpdateBeforeExtraction=True,
            LSMinimumSystemVersion="14.0")
        self.saver = dict(CFBundleIdentifier="com.forichok.agents-notch.house-saver", CFBundleVersion=VERSION,
            CFBundleShortVersionString=VERSION, AgentNotchSourceRevision=REVISION, NSPrincipalClass="AgentNotchHouseView")
        self.fixture()

    def fixture(self):
        archive = self.directory / ("AgentNotch-" + VERSION + ".zip")
        with zipfile.ZipFile(archive, "w") as zipped:
            zipped.writestr("Agent Notch.app/Contents/Info.plist", plistlib.dumps(self.info))
            zipped.writestr("Agent Notch.app/Contents/MacOS/AgentsNotch", b"test payload")
        signature = subprocess.check_output([str(self.signer), str(self.seed), str(archive)], text=True).strip()
        (self.directory / ("AgentNotch-" + VERSION + ".dmg")).write_bytes(b"test dmg")
        with zipfile.ZipFile(self.directory / audit.saver_name(VERSION), "w") as zipped:
            zipped.writestr("Agent Notch House.saver/Contents/Info.plist", plistlib.dumps(self.saver))
            zipped.writestr("Agent Notch House.saver/Contents/MacOS/Agent Notch House", b"test saver")
        self.checksums()
        rss = ET.Element("rss")
        item = ET.SubElement(ET.SubElement(rss, "channel"), "item")
        for key, value in [("version", VERSION), ("shortVersionString", VERSION),
                           ("minimumSystemVersion", "14.0"), ("hardwareRequirements", "arm64")]:
            ET.SubElement(item, audit.NS + key).text = value
        ET.SubElement(item, "enclosure", {"url": audit.PREFIX + "/v" + VERSION + "/" + archive.name,
            "length": str(archive.stat().st_size), audit.NS + "edSignature": signature})
        ET.SubElement(item, "description").text = "<pre>" + html.escape("Release notes\n") + "</pre>"
        ET.ElementTree(rss).write(self.directory / "appcast.xml", encoding="utf-8")
        (self.directory / "notes.md").write_text("Release notes\n")
        (self.directory / "agent-notch.rb").write_text('cask "agent-notch" do\n  version "' + VERSION +
            '"\n  sha256 "' + hashlib.sha256(archive.read_bytes()).hexdigest() +
            '"\n  url "https://github.com/Forichok/Agent-Notch/releases/download/v#{version}/AgentNotch-#{version}.zip"\nend\n')

    def checksums(self):
        lines = []
        for name in ["AgentNotch-" + VERSION + ".zip", "AgentNotch-" + VERSION + ".dmg", audit.saver_name(VERSION)]:
            lines.append(hashlib.sha256((self.directory / name).read_bytes()).hexdigest() + "  " + name)
        (self.directory / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n")

    def check(self):
        return audit.audit_metadata(self.directory, VERSION, REVISION, self.key, self.verifier, local=True)

    def test_signed_consistent_release_passes(self):
        self.assertEqual(self.check()["revision"], REVISION)

    def test_signed_old_source_or_automatic_policy_is_rejected(self):
        for key, value in [("AgentNotchSourceRevision", "b" * 40), ("SUEnableAutomaticChecks", True),
                           ("SUAllowsAutomaticUpdates", True), ("AgentNotchSourceDirty", True),
                           ("SUFeedURL", "https://example.org/appcast.xml")]:
            original = self.info[key]
            self.info[key] = value
            self.fixture()
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check()
            self.info[key] = original

    def test_screen_saver_from_other_source_or_missing_is_rejected(self):
        for key, value in [("AgentNotchSourceRevision", "b" * 40), ("CFBundleVersion", "0.4.9")]:
            original = self.saver[key]
            self.saver[key] = value
            self.fixture()
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check()
            self.saver[key] = original
        self.fixture()
        (self.directory / audit.saver_name(VERSION)).unlink()
        with self.assertRaises(ValueError):
            self.check()

    def test_tampering_is_rejected_even_with_updated_checksums(self):
        archive = self.directory / ("AgentNotch-" + VERSION + ".zip")
        with zipfile.ZipFile(archive, "a") as zipped:
            zipped.writestr("extra.txt", b"tampered")
        self.checksums()
        path = self.directory / "appcast.xml"
        tree = ET.parse(path)
        tree.find("./channel/item/enclosure").set("length", str(archive.stat().st_size))
        tree.write(path)
        cask = self.directory / "agent-notch.rb"
        import re
        cask.write_text(re.sub(r'sha256 "[^"]+"', 'sha256 "' + hashlib.sha256(archive.read_bytes()).hexdigest() + '"', cask.read_text()))
        with self.assertRaises(subprocess.CalledProcessError):
            self.check()

    def test_pinned_key_must_match_archive(self):
        self.info["SUPublicEDKey"] = base64.b64encode(bytes(32)).decode()
        self.fixture()
        with self.assertRaises(ValueError):
            self.check()

    def test_wrong_feed_version_or_download_url_is_rejected(self):
        for target, value in [(audit.NS + "version", "0.4.9"), ("enclosure", "https://example.org/update.zip")]:
            self.fixture()
            path = self.directory / "appcast.xml"
            tree = ET.parse(path)
            element = tree.find("./channel/item/" + target)
            if target == "enclosure": element.set("url", value)
            else: element.text = value
            tree.write(path)
            with self.subTest(target=target), self.assertRaises(ValueError):
                self.check()

    def test_changed_dmg_or_missing_cask_blocks_local_release(self):
        (self.directory / ("AgentNotch-" + VERSION + ".dmg")).write_bytes(b"changed")
        with self.assertRaises(ValueError): self.check()
        self.fixture()
        (self.directory / "agent-notch.rb").unlink()
        with self.assertRaises(ValueError): self.check()

    def test_dmg_bundle_must_match_signed_zip(self):
        signed = self.directory / "signed"
        mounted = self.directory / "mounted"
        for name in ["Contents/Info.plist", "Contents/MacOS/AgentsNotch", "Contents/Helpers/notch-hook"]:
            path = signed / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
        shutil.copytree(signed, mounted)
        audit.compare_bundles(signed, mounted)
        for name in ["Contents/Info.plist", "Contents/MacOS/AgentsNotch", "Contents/Helpers/notch-hook"]:
            path = mounted / name
            original = path.read_bytes()
            path.write_bytes(b"older app")
            with self.subTest(name=name), self.assertRaises(ValueError):
                audit.compare_bundles(signed, mounted)
            path.write_bytes(original)

    def test_404_is_a_failure_not_an_empty_feed(self):
        error = urllib.error.HTTPError(audit.FEED, 404, "Not Found", {}, None)
        with patch.object(audit.urllib.request, "urlopen", side_effect=error):
            with self.assertRaises(ValueError):
                audit.download(audit.FEED, self.directory / "feed.xml")

if __name__ == "__main__":
    unittest.main()
