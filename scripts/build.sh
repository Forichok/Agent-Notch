#!/bin/sh
# Builds build/AgentsNotch.app with plain swiftc (no SwiftPM, no Xcode project).
# Needs a working toolchain: Xcode selected via xcode-select (or DEVELOPER_DIR), license accepted.
set -eu
VERSION="${VERSION:-0.6.0}"
BUILD_NUMBER="$VERSION"
cd "$(dirname "$0")/.."
SOURCE_REVISION=$(git rev-parse HEAD 2>/dev/null || echo unversioned)
BASE_REVISION=$(git rev-parse origin/HEAD 2>/dev/null || echo unknown)
SOURCE_DIRTY=true
if [ -z "$(git status --porcelain 2>/dev/null)" ]; then SOURCE_DIRTY=false; fi
SPARKLE=$(./scripts/fetch-sparkle.sh)
TARGET="arm64-apple-macos14.0"
OUT=build
APP="$OUT/AgentsNotch.app"
rm -rf "$OUT/obj" "$APP"
mkdir -p "$OUT/obj" "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

xcrun swiftc -O -target "$TARGET" -parse-as-library -module-name NotchCore \
  -emit-module -emit-module-path "$OUT/obj/NotchCore.swiftmodule" \
  -emit-library -static -o "$OUT/obj/libNotchCore.a" Sources/NotchCore/*.swift

ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

xcrun swiftc -O -target "$TARGET" -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -module-name AgentsNotch -I "$OUT/obj" -L "$OUT/obj" -lNotchCore \
  -o "$APP/Contents/MacOS/AgentsNotch" Sources/AgentsNotch/*.swift

xcrun swiftc -O -target "$TARGET" -module-name NotchHook -I "$OUT/obj" -L "$OUT/obj" -lNotchCore \
  -o "$APP/Contents/Helpers/notch-hook" Sources/NotchHook/main.swift

# The agents' house screen saver: a loadable bundle with its own copy of the page, fed by the app (HouseSnapshot).
SAVER="$OUT/Agent Notch House.saver"
rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources/room"
xcrun swiftc -O -target "$TARGET" -parse-as-library -module-name AgentNotchHouse -I "$OUT/obj" -L "$OUT/obj" -lNotchCore \
  -framework ScreenSaver -framework WebKit -Xlinker -bundle \
  -o "$SAVER/Contents/MacOS/Agent Notch House" Sources/AgentNotchSaver/*.swift
cp room/index.html "$SAVER/Contents/Resources/room/index.html"
for t in thumbnail.png thumbnail@2x.png; do [ -f "assets/saver/$t" ] && cp "assets/saver/$t" "$SAVER/Contents/Resources/$t"; done
cat > "$SAVER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.forichok.agents-notch.house-saver</string>
  <key>CFBundleName</key><string>Agent Notch House</string>
  <key>CFBundleDisplayName</key><string>Agent Notch House</string>
  <key>CFBundleExecutable</key><string>Agent Notch House</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>AgentNotchSourceRevision</key><string>$SOURCE_REVISION</string>
  <key>NSPrincipalClass</key><string>AgentNotchHouseView</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Nikita Udalov. MIT License.</string>
</dict></plist>
PLIST
codesign --force --sign - "$SAVER"

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
  <key>NSAppleEventsUsageDescription</key><string>Agent Notch selects the terminal tab for the session you open.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Nikita Udalov. MIT License.</string>
</dict></plist>
PLIST

python3 scripts/update-config.py "$APP/Contents/Info.plist"

[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/room" && cp room/index.html "$APP/Contents/Resources/room/index.html"
# The app installs the saver from its own bundle (Settings → Desktop house).
ditto "$SAVER" "$APP/Contents/Resources/Agent Notch House.saver"

codesign --force --sign - "$APP/Contents/Helpers/notch-hook"
# An ad-hoc signature is pinned by its hash, and macOS ties Accessibility to that hash: every new build would
# lose the permission while System Settings keeps showing it on. Requiring only the bundle id keeps it.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
codesign --force --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
sh scripts/test-app-features.sh
echo "built $APP and $SAVER"
