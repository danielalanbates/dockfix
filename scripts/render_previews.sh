#!/bin/bash
# Renders the menu bar panel and window (light and dark) to PNGs in the build folder, offscreen.
#   scripts/render_previews.sh          render only
#   scripts/render_previews.sh repair   also press the first Repair button (edits the real Dock)
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO/config.local.sh" ] && source "$REPO/config.local.sh"
BUILD="${DOCKFIX_BUILD_DIR:-$HOME/Downloads/dockfix-build}"
mkdir -p "$BUILD/obj" "$BUILD/previews"
SOURCES=()
for f in "$REPO"/Sources/DockFix/*.swift; do [ "$(basename "$f")" = main.swift ] || SOURCES+=("$f"); done
xcrun swiftc -swift-version 5 -module-name DockFix -o "$BUILD/obj/render-previews" "${SOURCES[@]}" "$REPO/tests/RenderPreviews/main.swift"
"$BUILD/obj/render-previews" "$BUILD/previews" "$@"
