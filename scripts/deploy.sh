#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT"
swift build --package-path "$SRC" -c release
BIN="$(swift build --package-path "$SRC" -c release --show-bin-path)/TrackpadStudio"
STAGE="$(mktemp -d /tmp/mac-writing-build.XXXXXX)"
APP="$STAGE/TrackpadStudio-Handwriting.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto --norsrc --noextattr "$BIN" "$APP/Contents/MacOS/TrackpadStudio"
ditto --norsrc --noextattr "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TrackpadStudio</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>local.macwriting.trackpadstudio</string>
<key>CFBundleName</key><string>Trackpad Studio 手写</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0-handwriting</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF
codesign --force -s - "$APP"
mkdir -p "$HOME/Applications"
ditto --norsrc --noextattr "$APP" "$HOME/Applications/TrackpadStudio-Handwriting.app"
codesign --verify --deep --strict "$HOME/Applications/TrackpadStudio-Handwriting.app"
echo "Installed: $HOME/Applications/TrackpadStudio-Handwriting.app"
