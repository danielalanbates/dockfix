#!/bin/bash
# Builds DockFix.app (universal arm64 + x86_64) outside any cloud-synced folder and signs it.
#   scripts/build.sh
# Settings come from the environment or the gitignored config.local.sh (see config.local.sh.example):
#   DOCKFIX_BUILD_DIR  where to build          (default ~/Downloads/dockfix-build)
#   DOCKFIX_SIGN_ID    codesign identity/hash  (default "-" = ad-hoc)
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO/config.local.sh" ] && source "$REPO/config.local.sh"
BUILD="${DOCKFIX_BUILD_DIR:-$HOME/Downloads/dockfix-build}"
SIGN_ID="${DOCKFIX_SIGN_ID:--}"

# Compile from a local copy: cloud folders can evict files mid-build.
mkdir -p "$BUILD"
rsync -a --delete --exclude .git --exclude archive "$REPO/" "$BUILD/src/"
SRC="$BUILD/src"
APP="$BUILD/DockFix.app"
OBJ="$BUILD/obj"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Resources/Info.plist")

if [ ! -f "$SRC/Resources/AppIcon.icns" ]; then
  rm -rf "$OBJ/AppIcon.iconset"
  swift "$SRC/scripts/make_icon.swift" "$OBJ/AppIcon.iconset"
  iconutil -c icns -o "$SRC/Resources/AppIcon.icns" "$OBJ/AppIcon.iconset"
  cp "$SRC/Resources/AppIcon.icns" "$REPO/Resources/AppIcon.icns"
fi

rm -rf "$APP" "$OBJ/bin"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents" "$OBJ/bin"
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" -module-name DockFix \
    -o "$OBJ/bin/DockFix-$arch" "$SRC"/Sources/DockFix/*.swift
done
lipo -create -output "$APP/Contents/MacOS/DockFix" "$OBJ"/bin/DockFix-*

cp "$SRC/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$SRC/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$SRC/Resources/org.batesai.dockfix.agent.plist" "$SRC/Resources/org.batesai.dockfix.menubar.plist" \
  "$APP/Contents/Library/LaunchAgents/"
cp "$SRC/LICENSE" "$APP/Contents/Resources/LICENSE"
plutil -lint -s "$APP/Contents/Info.plist" "$APP"/Contents/Library/LaunchAgents/*.plist

if [ "$SIGN_ID" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"
echo "Built DockFix $VERSION → $APP"
