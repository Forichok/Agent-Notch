#!/usr/bin/env python3
"""Read-only release gate: exact artifacts, pinned signature and public availability."""
import argparse
import base64
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[4]
PREFIX = "https://github.com/Forichok/Agent-Notch/releases/download"
FEED = "https://github.com/Forichok/Agent-Notch/releases/latest/download/appcast.xml"
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
CASK_URL = PREFIX + '/v#{version}/AgentNotch-#{version}.zip'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def download(url, destination):
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "Agent-Notch-release-audit"})
        with urllib.request.urlopen(request, timeout=30) as response:
            require(response.status == 200 and response.url.startswith("https://"), "download requires HTTPS 200")
            data = response.read()
    except (urllib.error.URLError, OSError) as error:
        raise ValueError("download failed: " + url + ": " + str(error)) from error
    partial = destination.with_suffix(destination.suffix + ".partial")
    partial.write_bytes(data)
    partial.replace(destination)


def check_cask(text, version, checksum):
    fields = {}
    for name in ["version", "sha256", "url"]:
        match = re.search(r'^\s*' + name + r'\s+"([^"]+)"', text, re.MULTILINE)
        require(match is not None, "cask is missing " + name)
        fields[name] = match.group(1)
    require(fields == dict(version=version, sha256=checksum, url=CASK_URL),
            "cask version, checksum or download URL does not match")


def saver_name(version):
    return "AgentNotchHouse-" + version + ".saver.zip"


def audit_saver(archive, version, revision):
    """The screen saver ships beside the app and must come from the same source and version."""
    with zipfile.ZipFile(archive) as zipped:
        plists = [name for name in zipped.namelist()
                  if name.endswith(".saver/Contents/Info.plist") and len(name.split("/")) == 3]
        require(plists == ["Agent Notch House.saver/Contents/Info.plist"], "unexpected screen saver layout")
        require(zipped.getinfo(plists[0]).file_size < 1_048_576, "oversized screen saver metadata")
        info = plistlib.loads(zipped.read(plists[0]))
    expected = dict(CFBundleIdentifier="com.forichok.agents-notch.house-saver", CFBundleVersion=version,
                    CFBundleShortVersionString=version, AgentNotchSourceRevision=revision,
                    NSPrincipalClass="AgentNotchHouseView")
    require(all(info.get(key) == value for key, value in expected.items()),
            "screen saver identity, version or source does not match")


def audit_metadata(directory, version, revision, trusted_key, verifier, local=False):
    require(re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version),
            "version must be stable X.Y.Z")
    require(re.fullmatch(r"[0-9a-f]{40}", revision), "revision must be a full commit SHA")
    require(len(base64.b64decode(trusted_key, validate=True)) == 32, "invalid pinned public key")
    names = ["AgentNotch-" + version + suffix for suffix in [".zip", ".dmg"]] + [saver_name(version)]
    required = names + ["SHA256SUMS.txt", "appcast.xml"]
    if local:
        required += ["notes.md", "agent-notch.rb"]
    require(all((directory / name).is_file() and (directory / name).stat().st_size > 0 for name in required),
            "release artifact set is incomplete")
    actual = {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in names}
    declared = {}
    for line in (directory / "SHA256SUMS.txt").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64}) [ *](.+)", line)
        require(match is not None and match.group(2) not in declared, "invalid or duplicate checksum entry")
        declared[match.group(2)] = match.group(1)
    require(actual == declared, "ZIP/DMG/screen saver checksums do not match")
    audit_saver(directory / saver_name(version), version, revision)
    archive = directory / names[0]
    with zipfile.ZipFile(archive) as zipped:
        plists = [name for name in zipped.namelist()
                  if name.endswith(".app/Contents/Info.plist") and len(name.split("/")) == 3]
        require(plists == ["Agent Notch.app/Contents/Info.plist"], "unexpected app bundle layout")
        require(zipped.getinfo(plists[0]).file_size < 1_048_576, "oversized app metadata")
        info = plistlib.loads(zipped.read(plists[0]))
    expected = dict(CFBundleIdentifier="com.forichok.agents-notch", CFBundleVersion=version,
                    CFBundleShortVersionString=version, AgentNotchSourceRevision=revision,
                    SUPublicEDKey=trusted_key, SUFeedURL=FEED)
    require(all(info.get(key) == value for key, value in expected.items()),
            "archive identity, version, source, feed or pinned key does not match")
    require(re.fullmatch(r"[0-9a-f]{40}", info.get("AgentNotchBaseRevision", "")),
            "archive has no base revision")
    require(all(info.get(key) is False for key in ["AgentNotchSourceDirty", "SUEnableAutomaticChecks",
                "SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate"]), "archive permits automatic updates or has dirty source")
    require(info.get("SUVerifyUpdateBeforeExtraction") is True, "pre-extraction signature validation is disabled")
    items = ET.parse(directory / "appcast.xml").findall("./channel/item")
    require(len(items) == 1, "feed must describe exactly one stable release")
    item = items[0]
    for key in ["version", "shortVersionString"]:
        require(item.findtext(NS + key) == version, "feed version does not match")
    require(item.findtext(NS + "minimumSystemVersion") == info.get("LSMinimumSystemVersion"),
            "feed minimum macOS does not match")
    require(item.findtext(NS + "hardwareRequirements") == "arm64", "feed must require arm64")
    enclosure = item.find("enclosure")
    require(enclosure is not None, "missing feed enclosure")
    require(enclosure.get("url") == PREFIX + "/v" + version + "/" + names[0], "unexpected feed download URL")
    require(enclosure.get("length") == str(archive.stat().st_size), "feed archive length does not match")
    signature = enclosure.get(NS + "edSignature", "")
    require(len(base64.b64decode(signature, validate=True)) == 64, "missing or invalid update signature")
    subprocess.run([str(verifier), trusted_key, signature, str(archive)], check=True, capture_output=True)
    if local:
        require(item.findtext("description") == "<pre>" + html.escape((directory / "notes.md").read_text()) + "</pre>",
                "feed release notes differ from notes.md")
        check_cask((directory / "agent-notch.rb").read_text(), version, actual[names[0]])
    return dict(version=version, revision=revision, base_revision=info["AgentNotchBaseRevision"],
                zip_sha256=actual[names[0]], feed=FEED, artifacts=str(directory.resolve()))



def compare_bundles(signed, mounted):
    require(signed.is_dir() and mounted.is_dir() and not signed.is_symlink() and not mounted.is_symlink(),
            "missing or redirected app bundle")
    def manifest(bundle):
        result = {}
        for path in bundle.rglob("*"):
            name = str(path.relative_to(bundle))
            if path.is_symlink():
                result[name] = ("link", os.readlink(path))
            elif path.is_file():
                result[name] = ("file", hashlib.sha256(path.read_bytes()).hexdigest())
        return result
    require(manifest(signed) == manifest(mounted), "DMG app differs from the signed ZIP")


def verify_disk_image(directory, version):
    """Mount only read-only; never launch either downloaded app."""
    def quiet(*command):
        return subprocess.run(command, check=True, capture_output=True)
    archive = directory / ("AgentNotch-" + version + ".zip")
    image = directory / ("AgentNotch-" + version + ".dmg")
    quiet("hdiutil", "verify", str(image))
    with tempfile.TemporaryDirectory(prefix="notch-release-bundles-") as temporary:
        extracted = Path(temporary) / "zip"
        quiet("ditto", "-x", "-k", str(archive), str(extracted))
        signed = extracted / "Agent Notch.app"
        quiet("codesign", "--verify", "--deep", "--strict", str(signed))
        attached = plistlib.loads(quiet("hdiutil", "attach", "-readonly", "-nobrowse", "-plist", str(image)).stdout)
        entities = attached.get("system-entities", [])
        device = next((entry["dev-entry"] for entry in entities if "dev-entry" in entry), None)
        require(device is not None, "cannot identify attached DMG device")
        try:
            mounts = [Path(entry["mount-point"]) for entry in entities if "mount-point" in entry]
            require(len(mounts) == 1, "DMG must mount exactly one volume")
            mounted = mounts[0] / "Agent Notch.app"
            compare_bundles(signed, mounted)
            quiet("codesign", "--verify", "--deep", "--strict", str(mounted))
        finally:
            quiet("hdiutil", "detach", device)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--revision", required=True, help="expected full source commit SHA")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--local-dist", type=Path, help="validate all seven prepared local outputs")
    mode.add_argument("--output-dir", type=Path, help="download and validate public release files here")
    parser.add_argument("--check-tap", action="store_true", help="also check published default-branch cask")
    args = parser.parse_args()
    # Validate before using user-supplied values in download paths.
    require(re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", args.version),
            "version must be stable X.Y.Z")
    require(re.fullmatch(r"[0-9a-f]{40}", args.revision), "revision must be a full commit SHA")
    require(not args.check_tap or args.output_dir is not None, "--check-tap requires public mode")
    directory = (args.local_dist or args.output_dir).resolve()
    if args.output_dir is not None:
        directory.mkdir(parents=True, exist_ok=True)
        for name in ["AgentNotch-" + args.version + ".zip", "AgentNotch-" + args.version + ".dmg",
                     saver_name(args.version), "SHA256SUMS.txt"]:
            download(PREFIX + "/v" + args.version + "/" + name, directory / name)
        download(FEED, directory / "appcast.xml")
    key = (ROOT / "packaging/updates-public-key.txt").read_text().strip()
    with tempfile.TemporaryDirectory(prefix="notch-release-audit-") as temporary:
        verifier = Path(temporary) / "verify"
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=temporary + "/clang", SWIFT_MODULECACHE_PATH=temporary + "/swift")
        subprocess.run(["xcrun", "swiftc", str(ROOT / "scripts/verify-update-signature.swift"), "-o", str(verifier)],
                       check=True, env=env)
        result = audit_metadata(directory, args.version, args.revision, key, verifier, local=args.local_dist is not None)
    verify_disk_image(directory, args.version)
    result["dmg_matches_signed_zip"] = True
    if args.check_tap:
        metadata = directory / "tap-metadata.json"
        download("https://api.github.com/repos/Forichok/homebrew-tap/contents/Casks/agent-notch.rb", metadata)
        cask = base64.b64decode(json.loads(metadata.read_text())["content"], validate=False).decode()
        check_cask(cask, args.version, result["zip_sha256"])
        result["tap_verified"] = True
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, ET.ParseError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        detail = error.stderr.decode(errors="replace").strip() if isinstance(error, subprocess.CalledProcessError) and isinstance(error.stderr, bytes) else ""
        sys.exit("release audit: " + str(error) + (": " + detail if detail else ""))
