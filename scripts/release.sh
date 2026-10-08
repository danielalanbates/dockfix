#!/bin/bash
# Packages the built DockFix.app as a zip, notarizes it when a notarytool profile is set, and
# publishes a GitHub release. Only release builds that passed docs/TESTING.md.
#   scripts/release.sh
# Uses DOCKFIX_NOTARY_PROFILE (a `xcrun notarytool store-credentials` profile name) and
# DOCKFIX_REPO (default danielalanbates/dockfix) from the environment or config.local.sh.
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO/config.local.sh" ] && source "$REPO/config.local.sh"
BUILD="${DOCKFIX_BUILD_DIR:-$HOME/Downloads/dockfix-build}"
GH_REPO="${DOCKFIX_REPO:-danielalanbates/dockfix}"
APP="$BUILD/DockFix.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ZIP="$BUILD/DockFix-$VERSION.zip"
NOTES="$REPO/docs/releases/$VERSION.md"

[ -f "$NOTES" ] || { echo "Write release notes first: $NOTES"; exit 1; }
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${DOCKFIX_NOTARY_PROFILE:-}" ]; then
  if xcrun notarytool submit "$ZIP" --keychain-profile "$DOCKFIX_NOTARY_PROFILE" --wait; then
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
  else
    echo "Notarization failed; releasing the signed but un-notarized zip." >&2
  fi
fi

gh release create "v$VERSION" "$ZIP" --repo "$GH_REPO" --title "DockFix $VERSION" --notes-file "$NOTES"
