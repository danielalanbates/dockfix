# DockFix — developer notes, decisions, and pathways

For the next person or AI picking this up. Read with the README.

## Origin (2026-10-08)

The author's Dock kept showing "?" for apps. Diagnosis (macOS 27.0.1, MacBook, a USB drive "x10" holding seven Dock apps):

- **GarageBand and Final Cut Pro** were "?" although x10 was mounted and their bookmarks resolved. The Dock had started at 18:54:41; x10's mount-point folder was created at 18:54:41.579, the same second. A plain `killall Dock` fixed them, so the Dock had simply resolved its tiles before the mount finished, and it never re-checks.
- **Zygor and XIV on Mac** had been moved from /Applications to x10. Repointing the URL and bookmark and running `lsregister -f` were **not** enough. They only came back after also zeroing the tile's `file-mod-date`/`parent-mod-date` (Zygor/XIV had a garbage `parent-mod-date` of 35265554710049) **and** deleting the Dock icon cache. `DockPrefs.repoint` does all of that.

## Layout

| Path | What |
|---|---|
| `Sources/DockFix/main.swift` | Entry: GUI, `--menubar`, `--agent`, or CLI |
| `Sources/DockFix/Agent.swift` | The background check (decision + restart) |
| `Sources/DockFix/Volumes.swift` | Mount detection and mount times (`getattrlistbulk` on /Volumes) |
| `Sources/DockFix/DockProcess.swift` | Find this user's Dock, its start time, restart it |
| `Sources/DockFix/DockPrefs.swift` | Read/repoint Dock items, repair backup/undo, icon cache |
| `Sources/DockFix/TileStatus.swift` | Per-item status + `AppFinder` (finds moved copies) |
| `Sources/DockFix/AgentService.swift` | SMAppService wrapper + activity history |
| `Sources/DockFix/App.swift`, `Model.swift`, `MenuPanel.swift`, `MainWindowView.swift` | Menu bar app and window |
| `Sources/DockFix/CLI.swift` | Command-line interface |
| `Resources/` | Info.plist (LSUIElement), launchd job plist, AppIcon.icns |
| `scripts/` | build, install, release, icon, offscreen UI renderer |
| `tests/RenderPreviews/` | Offscreen renderer of the panel and window (and a scripted Repair press) |
| `archive/` | Code that was tried and did not work (empty so far) |

Build output never goes in the repo: `~/Downloads/dockfix-build/` (app, archive of replaced installs, previews). Source of truth: Google Drive `My Drive/Code/dockfix` with origin `github.com/danielalanbates/dockfix`.

## Decisions

- **Short-lived launchd job, not a resident daemon.** The goal is an idle machine. `StartOnMount` gives the exact trigger with zero polling. The menu bar app is separate and optional; the fix works with it quit.
- **SMAppService-bundled job** instead of a plist in `~/Library/LaunchAgents`: nothing written outside the app, shows in Login Items, removed with the app.
- **Mount time from the mount-point folder's creation time.** DiskArbitration's `DAAppearanceTime` was tried first: it reported 18:54:35 for *every* disk, including the internal one (when diskarbitrationd started), so it is useless. The folder's crtime via `getattrlistbulk` matched the real mount.
- **Stateless decision** (compare two timestamps) instead of remembering what was mounted before: survives reboots, Dock restarts by other tools, and multiple drives without bookkeeping, and cannot loop.
- **Race window 3 s, settle delay 5 s.** Must satisfy settle > window so a restart can't re-trigger itself. Side effect seen in testing: if something else restarts the Dock within 3 s after a mount, the agent restarts it once more. Harmless.
- **Repair is manual.** The agent never edits Dock preferences. An offline drive must not be "repaired" to a different copy (x10 had duplicate copies of XIV on Mac and FFXI-on-Mac), so `TileStatus` reports `driveNotConnected` for paths on unmounted `/Volumes/<name>` and offers no repair.
- **Undo** keeps one backup (the whole Dock section before the last repair) in DockFix's own preferences. Restoring it drops anything added to that section afterwards; the UI says so.

## Verified (2026-10-08, macOS 27.0.1)

| Check | Result |
|---|---|
| Build: universal arm64 + x86_64, Developer ID signed, hardened runtime | pass |
| SMAppService registration from CLI; launchd job `start on fs mount`, RunAtLoad ran, exit 0 | pass |
| Disk image with an app added to the Dock; icon cache cleared while detached → "?" | reproduced |
| Re-attach → agent restarted the Dock 5.4 s after mount → icon back; next check "do nothing" | pass |
| Unrelated disk image mount + manual `launchctl kickstart` → no Dock restart | pass |
| `--repair` on a moved app (no bookmark) → found on the test volume, repointed, icon back | pass |
| `--undo-repair` → broken state restored; second undo refuses | pass |
| Window/panel Repair action through `Model.repair` (tests/RenderPreviews `repair`) | pass |
| Panel and window rendered offscreen in light and dark | pass |
| Real Dock order/labels identical before and after the test run | pass |

Not verified by machine: real mouse clicks in the panel/window (the same model calls were exercised), and that a launch **at login** suppresses the window (`keyAELaunchedAsLogInItem`; needs a real login). If the window does open at every login, start the login item with `--menubar` instead: switch Open at Login from `SMAppService.mainApp` to a second bundled LaunchAgent whose `ProgramArguments` include `--menubar`.

## Known limits

- If a stale empty folder `/Volumes/<name>` is left over and the drive mounts as `/Volumes/<name> 1`, the Dock path no longer matches; restarting won't help. Rare; would need tile-path rewriting.
- If diskarbitrationd ever reuses an existing mount-point folder, its crtime would predate the mount and a late mount could be missed.
- A Dock started by another tool between a mount and DockFix's check is handled by timestamps, but a drive that mounted *more than 3 s before* a Dock that still failed to load it would not be caught (not observed).
- Network shares mount under /Volumes too and are handled the same way.

## Pathways not taken (yet)

| Idea | Why not now |
|---|---|
| Long-running DiskArbitration listener (`DARegisterDiskDescriptionChangedCallback`) | Needs a resident process; `StartOnMount` gives the same trigger for free |
| Detect "?" tiles directly via Accessibility (Dock `AXDockItem`) | Needs Accessibility permission (an extra prompt, and a TCC grant to keep healthy) |
| Auto-remount a drive that is attached but unmounted (`diskutil mount` / `DADiskMount`) | Asked for 2026-10-08; can't tell a user eject from a drop-off. Would be opt-in, and only for disks still present on the bus |
| Auto-repair moved apps | Risk of pointing at the wrong copy (duplicates exist); keep it one click |
| Use dockutil for edits | Extra dependency; the three keys it would write are simple |
| Notarized release | Apple developer agreement was expired as of 2026-10-02; release.sh tries the configured notary profile and falls back to signed-only |

## Release process

1. Bump `CFBundleShortVersionString`/`CFBundleVersion` in `Resources/Info.plist`, add `docs/releases/<version>.md` and a CHANGELOG entry.
2. `scripts/build.sh` → run docs/TESTING.md → `scripts/install.sh` (local .app = beta).
3. `scripts/release.sh` (GitHub release = public, only after tests pass).
