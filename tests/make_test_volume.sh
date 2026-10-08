#!/bin/bash
# Builds the test kit for docs/TESTING.md in ~/Downloads/dockfix-build/test:
#   DockFix Test Tile.app on a disk image (test.dmg) and the dock-test-tile helper.
#   tests/make_test_volume.sh
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO/config.local.sh" ] && source "$REPO/config.local.sh"
BUILD="${DOCKFIX_BUILD_DIR:-$HOME/Downloads/dockfix-build}"
T="$BUILD/test"
rm -rf "$T/src"; mkdir -p "$T/src"
A="$T/src/DockFix Test Tile.app"
mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cat > "$A/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>tile</string>
<key>CFBundleIdentifier</key><string>org.batesai.dockfix.testtile</string>
<key>CFBundleName</key><string>DockFix Test Tile</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
printf '#!/bin/sh\nexit 0\n' > "$A/Contents/MacOS/tile"
chmod +x "$A/Contents/MacOS/tile"
cp "$REPO/Resources/AppIcon.icns" "$A/Contents/Resources/"
hdiutil create -quiet -volname DockFixTest -srcfolder "$T/src" -format UDRW -ov "$T/test.dmg"
xcrun swiftc -O -o "$T/dock-test-tile" "$REPO/tests/DockTestTile/main.swift"
echo "Test kit ready in $T:"
echo "  hdiutil attach -nobrowse \"$T/test.dmg\""
echo "  \"$T/dock-test-tile\" add \"/Volumes/DockFixTest/DockFix Test Tile.app\" && killall Dock"
