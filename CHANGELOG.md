# Changelog

## 1.0.0 — 2026-10-08

First release.

- Background check (bundled launchd job, runs at login and on every mount, then exits): restarts the Dock once when a drive holding Dock apps mounted after the Dock started.
- Menu bar app: status icon that changes when an item is broken; panel with Repair buttons, drive list, switches, Restart Dock, Clear Icon Cache.
- Window listing every Dock item (broken first) with repair choices and an Undo for the last repaired item.
- Repair for moved apps: finds copies by bundle ID across /Applications, ~/Applications and connected drives; repoints URL + bookmark, clears stale dates and the icon cache.
- Command line: `--status`, `--enable/--disable`, `--login-item`, `--restart-dock`, `--clear-icon-cache`, `--repair`, `--undo-repair`.
- Safety: each mount is acted on once; repairs wait for a settled Dock and verify they stuck; undo restores only the repaired item; items on disconnected or unreadable drives, or in the Trash, are never repointed automatically; drive checks run off the main thread.
