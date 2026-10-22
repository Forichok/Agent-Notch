#!/bin/sh
# Builds the app and packs it for a release: dist/AgentNotch-<version>.dmg and .zip, the screen saver as
# dist/AgentNotchHouse-<version>.saver.zip, plus SHA-256 sums. The DMG carries the saver beside the app.
# Usage: scripts/package.sh 0.1.0
set -eu
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/package.sh <version>}"
VERSION="${VERSION#v}"
export VERSION

./scripts/build.sh
rm -rf dist && mkdir -p dist/stage
APP="dist/stage/Agent Notch.app"
cp -R build/AgentsNotch.app "$APP"
codesign --force --sign - "$APP/Contents/Helpers/notch-hook"
# Same requirement as build.sh, so Accessibility survives updates.
codesign --force --sign - -r='designated => identifier "com.forichok.agents-notch"' "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/AgentNotch-$VERSION.zip"
SAVER="dist/stage/Agent Notch House.saver"
cp -R "build/Agent Notch House.saver" "$SAVER"
codesign --force --sign - "$SAVER"
ditto -c -k --sequesterRsrc --keepParent "$SAVER" "dist/AgentNotchHouse-$VERSION.saver.zip"

ln -s /Applications dist/stage/Applications
hdiutil create -quiet -volname "Agent Notch $VERSION" -srcfolder dist/stage -fs HFS+ -format UDZO \
  "dist/AgentNotch-$VERSION.dmg"
rm -rf dist/stage

(cd dist && shasum -a 256 AgentNotch-"$VERSION".dmg AgentNotch-"$VERSION".zip AgentNotchHouse-"$VERSION".saver.zip > SHA256SUMS.txt)
cat dist/SHA256SUMS.txt
