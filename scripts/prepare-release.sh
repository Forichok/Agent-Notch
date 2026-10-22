#!/bin/sh
# Prepare a complete signed release locally. Never create tags, push, or publish.
set -eu
cd "$(dirname "$0")/.."
[ "$#" -eq 1 ] || { echo "usage: scripts/prepare-release.sh X.Y.Z" >&2; exit 1; }
version="${1#v}"
source_status=$(git status --porcelain)
[ -z "$source_status" ] || { echo "release preparation requires a clean working tree; commit changes first" >&2; exit 1; }
if [ "${UPDATE_TEST_BUNDLE:-}" = 1 ] || [ "${UPDATE_PUBLIC_KEY+x}" = x ] || [ "${UPDATE_FEED_URL+x}" = x ]; then
  echo "unset test updater overrides before preparing a production release" >&2
  exit 1
fi
# The release key stays in this Mac's Keychain, regardless of the caller's environment.
unset SPARKLE_PRIVATE_KEY
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT HUP INT TERM
python3 scripts/release-notes.py "$version" > "$notes"
./scripts/test.sh
./scripts/package.sh "$version"
cp "$notes" dist/notes.md
./scripts/appcast.sh "$version"
for file in "dist/AgentNotch-$version.zip" "dist/AgentNotch-$version.dmg" "dist/AgentNotchHouse-$version.saver.zip" dist/SHA256SUMS.txt dist/appcast.xml dist/notes.md; do
  [ -s "$file" ] || { echo "missing release artifact: $file" >&2; exit 1; }
done
checksum_result=$(shasum -a 256 "dist/AgentNotch-$version.zip")
checksum=${checksum_result%% *}
sed -e "s/__VERSION__/$version/" -e "s/__SHA256__/$checksum/" packaging/agent-notch.rb > dist/agent-notch.rb
printf 'Prepared %s in dist/: signed ZIP, DMG, screen saver ZIP, checksums, appcast, notes and Homebrew cask. No tags or releases published.\n' "$version"
