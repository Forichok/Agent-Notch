#!/bin/sh
# Builds build/AgentsNotch.app with plain swiftc (no SwiftPM, no Xcode project).
# Needs a working toolchain: Xcode selected via xcode-select (or DEVELOPER_DIR), license accepted.
set -eu
VERSION="${VERSION:-0.4.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
cd "$(dirname "$0")/.."
SOURCE_REVISION=$(git rev-parse HEAD 2>/dev/null || echo unversioned)
BASE_REVISION=$(git rev-parse origin/HEAD 2>/dev/null || echo unknown)
SOURCE_DIRTY=true
if [ -z "$(git status --porcelain 2>/dev/null)" ]; then SOURCE_DIRTY=false; fi
TARGET="arm64-apple-macos14.0"
OUT=build
APP="$OUT/AgentsNotch.app"
rm -rf "$OUT/obj" "$APP"
mkdir -p "$OUT/obj" "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

xcrun swiftc -O -target "$TARGET" -parse-as-library -module-name NotchCore \
  -emit-module -emit-module-path "$OUT/obj/NotchCore.swiftmodule" \
  -emit-library -static -o "$OUT/obj/libNotchCore.a" Sources/NotchCore/*.swift

xcrun swiftc -O -target "$TARGET" -module-name AgentsNotch -I "$OUT/obj" -L "$OUT/obj" -lNotchCore \
  -o "$APP/Contents/MacOS/AgentsNotch" Sources/AgentsNotch/*.swift

xcrun swiftc -O -target "$TARGET" -module-name NotchHook -I "$OUT/obj" -L "$OUT/obj" -lNotchCore \
  -o "$APP/Contents/Helpers/notch-hook" Sources/NotchHook/main.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.forichok.agents-notch</string>
  <key>CFBundleName</key><string>Agent Notch</string>
  <key>CFBundleDisplayName</key><string>Agent Notch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>AgentsNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>AgentNotchSourceRevision</key><string>$SOURCE_REVISION</string>
  <key>AgentNotchBaseRevision</key><string>$BASE_REVISION</string>
  <key>AgentNotchSourceDirty</key><$SOURCE_DIRTY/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Nikita Udalov. MIT License.</string>
</dict></plist>
PLIST

[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP/Contents/Helpers/notch-hook"
# An ad-hoc signature is pinned by its hash, and macOS ties Accessibility to that hash: every new build would
# lose the permission while System Settings keeps showing it on. Requiring only the bundle id keeps it.
codesign --force --sign - -r='designated => identifier "com.forichok.agents-notch"' "$APP"
sh scripts/test-app-features.sh
echo "built $APP"
