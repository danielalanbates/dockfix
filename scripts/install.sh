#!/bin/bash
# Installs the built DockFix.app into /Applications, archiving the copy it replaces, and restarts
# the menu bar app if it was running.
#   scripts/install.sh            install / update
#   scripts/install.sh --enable   also turn on the background check and Open at Login, and start
#                                 the menu bar app
# The bundle is replaced in place (same folder), so existing Login Items registrations keep
# pointing at /Applications/DockFix.app.
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO/config.local.sh" ] && source "$REPO/config.local.sh"
BUILD="${DOCKFIX_BUILD_DIR:-$HOME/Downloads/dockfix-build}"
APP="$BUILD/DockFix.app"
DEST="/Applications/DockFix.app"
GUI_PATTERN="^$DEST/Contents/MacOS/DockFix( --menubar)?\$"

[ -d "$APP" ] || { echo "Build first: scripts/build.sh"; exit 1; }

was_running=0
if pgrep -f "$GUI_PATTERN" >/dev/null; then
  was_running=1
  osascript -e 'tell application id "org.batesai.dockfix" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -f "$GUI_PATTERN" >/dev/null || break; sleep 0.25; done
  if pgrep -f "$GUI_PATTERN" >/dev/null; then
    echo "DockFix is still running; quit it from its menu bar icon and run this again."
    exit 1
  fi
fi

if [ -d "$DEST" ]; then
  OLD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo unknown)
  mkdir -p "$BUILD/archive"
  ditto "$DEST" "$BUILD/archive/DockFix-$OLD-$(date +%Y%m%d-%H%M%S).app"
fi

mkdir -p "$DEST"
rsync -a --delete "$APP/" "$DEST/"
codesign --verify --strict "$DEST"
echo "Installed $("$DEST/Contents/MacOS/DockFix" --version) → $DEST"

if [ "${1:-}" = "--enable" ]; then
  # Keep going if either fails (e.g. switched off in Login Items): the app is relaunched below either way.
  "$DEST/Contents/MacOS/DockFix" --enable || echo "Warning: background check not turned on (see System Settings › General › Login Items)."
  "$DEST/Contents/MacOS/DockFix" --login-item on || echo "Warning: Open at Login not turned on."
  was_running=1
fi

if [ "$was_running" = 1 ]; then
  # -g: start in the background without taking focus. One instance only.
  pgrep -f "$GUI_PATTERN" >/dev/null || open -g -a "$DEST" --args --menubar
  echo "Menu bar app running."
fi
