#!/bin/bash
# Builds an Apple silicon (arm64) app and packs it into a DMG for
# sharing: app, Applications shortcut, 使用说明.txt, LICENSE.txt.
# Ad-hoc signed only (no Developer ID), so recipients follow the Gatekeeper
# steps in 使用说明.txt on first launch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT"
VERSION="${1:-1.1}"
APP_NAME="Trackpad Studio 手写"
OUT="$ROOT/dist/TrackpadStudio-Handwriting-$VERSION.dmg"

swift build --package-path "$SRC" -c release --arch arm64
BIN="$(swift build --package-path "$SRC" -c release --arch arm64 --show-bin-path)/TrackpadStudio"

STAGE="$(mktemp -d /tmp/mac-writing-dmg.XXXXXX)"
APP="$STAGE/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto --norsrc --noextattr "$BIN" "$APP/Contents/MacOS/TrackpadStudio"
ditto --norsrc --noextattr "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TrackpadStudio</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>local.macwriting.trackpadstudio</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSArchitecturePriority</key><array><string>arm64</string></array>
<key>LSRequiresNativeExecution</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Based on Trackpad Studio (MIT)</string>
</dict></plist>
EOF
codesign --force -s - "$APP"
codesign --verify --deep --strict "$APP"

cp "$ROOT/docs/使用说明.txt" "$STAGE/使用说明.txt"
cp "$SRC/LICENSE" "$STAGE/LICENSE.txt"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$ROOT/dist"
rm -f "$OUT"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs APFS -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
hdiutil verify "$OUT" >/dev/null
echo "Built: $OUT ($(du -h "$OUT" | cut -f1))"
