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
| `Sources/DockFix/DockPrefs.swift` | Read/repoint Dock items, per-item repair backup, icon cache |
| `Sources/DockFix/DockEditor.swift` | Repair/undo that wait for a settled Dock, verify, and retry once |
| `Sources/DockFix/TileStatus.swift` | Per-item status + `AppFinder` (finds moved copies) |
| `Sources/DockFix/AgentService.swift` | SMAppService wrapper + activity history |
| `Sources/DockFix/App.swift`, `Model.swift`, `MenuPanel.swift`, `MainWindowView.swift` | Menu bar app and window |
| `Sources/DockFix/CLI.swift` | Command-line interface |
| `Resources/` | Info.plist (LSUIElement), the two launchd job plists (background check; Open at Login with `--menubar`), AppIcon.icns |
| `scripts/` | build, install, release, icon, offscreen UI renderer |
| `tests/RenderPreviews/` | Offscreen renderer of the panel and window (and a scripted Repair press) |
| `archive/` | Code that was tried and did not work (empty so far) |

Build output never goes in the repo: `~/Downloads/dockfix-build/` (app, archive of replaced installs, previews). Source of truth: Google Drive `My Drive/Code/dockfix` with origin `github.com/danielalanbates/dockfix`.

## Decisions

- **Short-lived launchd job, not a resident daemon.** The goal is an idle machine. `StartOnMount` gives the exact trigger with zero polling. The menu bar app is separate and optional; the fix works with it quit.
- **SMAppService-bundled job** instead of a plist in `~/Library/LaunchAgents`: nothing written outside the app, shows in Login Items, removed with the app.
- **Mount time from the mount-point folder's creation time.** DiskArbitration's `DAAppearanceTime` was tried first: it reported 18:54:35 for *every* disk, including the internal one (when diskarbitrationd started), so it is useless. The folder's crtime via `getattrlistbulk` matched the real mount.
- **Timestamps plus a "seen mounts" list.** The core test compares two timestamps (survives reboots and Dock restarts by other tools). Review found that timestamps alone misfire when a drive mounts with no Dock items and gets one later (the Dock shows that fine): the next unrelated mount would restart the Dock. So each run records the mounts it evaluated (`SeenMounts`, path → mount time) and a mount is acted on at most once. Only mounts present at evaluation time are recorded, so a drive that mounts mid-check is still evaluated by the next run.
- **Race window 3 s, settle delay 5 s.** Must satisfy settle > window so a restart can't re-trigger itself. Side effect seen in testing: if something else restarts the Dock within 3 s after a mount, the agent restarts it once more. Harmless.
- **Repair is manual.** The agent never edits Dock preferences. An offline drive must not be "repaired" to a different copy (x10 had duplicate copies of XIV on Mac and FFXI-on-Mac), so `TileStatus` reports `driveNotConnected` for paths on unmounted `/Volumes/<name>` and offers no repair.
- **Undo** keeps one backup: the repaired item's original dictionary (found again by GUID). Undo replaces only that item, so later Dock changes survive. The first version restored the whole section; review caught that it would wipe later changes.
- **The Dock rewrites its item list ~5 s after it starts** (measured: it adds file-mod-date, parent-mod-date, dock-extra, is-beta). An edit made in that window is silently lost; the first test run hit it. `DockEditor` waits until the Dock is 8 s old before writing, restarts it, waits again, checks the item points where intended, and writes once more if not.
- **Status distinguishes "absent" from "not allowed"** (`FileCheck`, errno EACCES/EPERM → `noAccess`), so a drive DockFix can't read is never treated as missing and "repaired" to another copy. Bookmarks resolving into a Trash don't count as "moved".

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
| Review fixes (second round): seen mount + item added later + unrelated mount → no restart | pass |
| Repair started 0.5 s after a Dock restart (inside the rewrite window) → waited, stuck | pass |
| Undo changes only the repaired item (full persistent-apps diff) | pass |
| `--repair` refuses OK items, items on a disconnected drive, and unreadable (chmod 000) folders | pass |
| Bookmark resolving into `.Trashes` → MISSING with the real copy offered, not "moved to Trash" | pass |

Not verified by machine: real mouse clicks in the panel/window (the same model calls were exercised), and a real logout/login. A login launch was simulated with `launchctl kickstart gui/$UID/org.batesai.dockfix.menubar`: one instance, `--menubar`, no window, menu bar icon present.

- **Open at Login is a second bundled LaunchAgent** (`org.batesai.dockfix.menubar`, `ProgramArguments` = `DockFix --menubar`), not `SMAppService.mainApp`: mainApp can't pass arguments and its "launched as login item" Apple-event flag isn't dependable, so the window could open at every login. Registering the job runs it at once (RunAtLoad); a second copy finds the first via `NSRunningApplication` and exits. A copy opened by hand while one runs posts a distributed notification so the running one shows its window. Builds that registered mainApp are migrated on launch (`AgentService.migrateLoginItem`).
- **Mount checks use the kernel's cached mount table** (`getfsstat(MNT_NOWAIT)`), never `statfs()` per volume, so a dead network share can't stall the check.

## Review (2026-10-08)

Three Claude reviewers (agent safety; Dock prefs and repair; app, UI and scripts) reported 17 findings; the verifier agent failed on a network error, so each finding was checked by hand against the code. All 17 held up (14 distinct); all were fixed and retested, see the table above. The free-model reviews (Gemini Pro: HTTP 429 on the free tier; OpenRouter free models: 403/timeouts/DNS errors) did not complete.

Round 2 reviewed the fix commit (one reviewer + one skeptic; all 8 findings confirmed and fixed):

| Finding | Fix |
|---|---|
| release.sh Developer ID gate always failed (`codesign | grep -q` under pipefail → SIGPIPE) | capture output first, `|| true`, then grep |
| Undo deleted its backup before verifying | backup cleared only after a verified undo (or when the item is gone) |
| Restart-cap path marked skipped mounts as handled | cap path records only non-stale mounts |
| loginwindow-age heuristic hid the window on a manual launch right after login | removed; login uses the `--menubar` job |
| EIO/ETIMEDOUT etc. counted as "absent" → repair offered | only ENOENT/ENOTDIR are absent; everything else is "can't read" |
| `statfs` on every /Volumes entry could block on dead shares | cached mount table (`getfsstat MNT_NOWAIT`) |
| Settle wait unbounded if the clock moved back | capped at 8 s |
| Preview harness could snapshot before rows loaded | `Model.loading` flag |

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
