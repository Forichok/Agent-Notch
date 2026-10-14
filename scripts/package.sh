#!/bin/sh
# Builds the app and packs it for a release: dist/AgentNotch-<version>.dmg and .zip plus SHA-256 sums.
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

ln -s /Applications dist/stage/Applications
hdiutil create -quiet -volname "Agent Notch $VERSION" -srcfolder dist/stage -fs HFS+ -format UDZO \
  "dist/AgentNotch-$VERSION.dmg"
rm -rf dist/stage

(cd dist && shasum -a 256 AgentNotch-"$VERSION".dmg AgentNotch-"$VERSION".zip > SHA256SUMS.txt)
cat dist/SHA256SUMS.txt
