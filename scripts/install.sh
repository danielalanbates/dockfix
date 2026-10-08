#!/bin/bash
# Installs the built DockFix.app into /Applications, archiving the copy it replaces, re-registers the
# launchd jobs that are switched on, and restarts the menu bar app if it was running.
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
# PIDs of the running menu bar app, found by bundle ID through LaunchServices, however it was started
# (also a copy run from the build folder). The background check and command-line runs are not apps
# and never match.
gui_pids() {
  local asn
  for asn in $(lsappinfo find bundleid=org.batesai.dockfix 2>/dev/null); do
    lsappinfo info "$asn" 2>/dev/null | sed -nE 's/^ *pid = ([0-9]+) .*type="(UIElement|Foreground)".*/\1/p'
  done
}
gui_running() { [ -n "$(gui_pids)" ]; }

[ -d "$APP" ] || { echo "Build first: scripts/build.sh"; exit 1; }

was_running=0
if gui_running; then
  was_running=1
  osascript -e 'tell application id "org.batesai.dockfix" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do gui_running || break; sleep 0.25; done
  pids=$(gui_pids)
  [ -n "$pids" ] && kill -TERM $pids 2>/dev/null || true   # our own app only
  for _ in $(seq 1 20); do gui_running || break; sleep 0.25; done
  if gui_running; then
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

DOCKFIX="$DEST/Contents/MacOS/DockFix"
job_loaded() { launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1; }
agent_on=0; login_on=0
job_loaded org.batesai.dockfix.agent && agent_on=1
job_loaded org.batesai.dockfix.menubar && login_on=1
if [ "${1:-}" = "--enable" ]; then
  agent_on=1; login_on=1; was_running=1
fi

# launchd keeps a registered job's old definition until the job is registered again, so register
# the switched-on jobs afresh to load the updated bundle's plists. The menu bar app is quit at this
# point, so unregistering can't kill it. Keep going if either fails (e.g. switched off in Login Items).
if [ "$agent_on" = 1 ]; then
  "$DOCKFIX" --disable >/dev/null 2>&1 || true
  "$DOCKFIX" --enable || echo "Warning: background check not turned on (see System Settings › General › Login Items)."
fi
if [ "$login_on" = 1 ]; then
  "$DOCKFIX" --login-item off >/dev/null 2>&1 || true
  "$DOCKFIX" --login-item on || echo "Warning: Open at Login not turned on."   # also starts the menu bar app
fi

if [ "$was_running" = 1 ] || [ "$login_on" = 1 ]; then
  for _ in $(seq 1 20); do gui_running && break; sleep 0.25; done
  # -g: start in the background without taking focus. A second copy would exit at once anyway.
  gui_running || open -g -a "$DEST" --args --menubar
  echo "Menu bar app running."
fi
