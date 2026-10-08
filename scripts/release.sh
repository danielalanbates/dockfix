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
# Capture first: piping codesign into grep -q under pipefail fails with SIGPIPE even on a match.
signature=$(codesign -dv --verbose=2 "$APP" 2>&1 || true)
if ! grep -q '^Authority=Developer ID Application' <<<"$signature"; then
  echo "Not Developer ID signed (set DOCKFIX_SIGN_ID and rebuild). Refusing to publish." >&2
  exit 1
fi
codesign --verify --strict "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

FINAL_NOTES="$BUILD/release-notes-$VERSION.md"
cp "$NOTES" "$FINAL_NOTES"
rm -f "$BUILD/notary.log"
notarized=0
if [ -n "${DOCKFIX_NOTARY_PROFILE:-}" ]; then
  # Log to a file first: grep -q on a pipe can SIGPIPE notarytool/tee and, with pipefail, hide a success.
  xcrun notarytool submit "$ZIP" --keychain-profile "$DOCKFIX_NOTARY_PROFILE" --wait > "$BUILD/notary.log" 2>&1 || true
  cat "$BUILD/notary.log"
fi
if grep -q 'status: Accepted' "$BUILD/notary.log" 2>/dev/null; then
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarized=1
fi
if [ "$notarized" = 0 ]; then
  echo "Not notarized; adding first-open instructions to the release notes." >&2
  cat >> "$FINAL_NOTES" <<'EOF'

**First open:** this build is signed but not notarized by Apple, so macOS blocks the first launch. Open DockFix once, then go to System Settings › Privacy & Security and click **Open Anyway** next to the DockFix message.
EOF
fi

gh release create "v$VERSION" "$ZIP" --repo "$GH_REPO" --title "DockFix $VERSION" --notes-file "$FINAL_NOTES"
