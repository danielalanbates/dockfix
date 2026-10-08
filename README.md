# DockFix

Repairs macOS Dock icons that turn into a question mark — and stops it happening again for apps that live on external drives.

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. · [batesai.org](https://batesai.org) · help@batesai.org

## Why Dock icons turn into "?"

| Cause | What you see | What DockFix does |
|---|---|---|
| The app is on an external drive that mounted **after** the Dock started (common at login: the Dock and the drive come up in the same second) | "?" for every Dock app on that drive, even though the drive is connected | Restarts the Dock once, ~5 s after the drive mounts, automatically |
| The app was **moved** (for example from /Applications to an external drive) | "?" that never goes away | Finds the app by bundle ID and repoints the Dock item (one click) |
| The item exists but the Dock's **icon cache** still holds the "?" | "?" even though the path is right | "Clear Icon Cache and Restart Dock" |
| The drive is **not connected** | "?" or the last cached icon | Nothing to fix — it comes back when the drive does |

DockFix does not mount or reconnect drives. When a drive comes back (plugged in, or remounted by macOS), DockFix makes the Dock pick its apps up again.

Repairs are careful by design: an item on a disconnected drive, on a drive DockFix isn't allowed to read, or whose app went to the Trash is never pointed at some other copy automatically. Each repair waits until the Dock has settled (a newly started Dock rewrites its item list about 5 seconds after launch, which would undo an edit made in that window), then checks that the change stuck.

## Using it

- **Menu bar:** the Dock icon (▭ with a shelf) in the menu bar. It turns into a dashed "?" when an item needs repair. The panel shows broken items with a **Repair** button, the drives that hold Dock apps, the two switches, and Restart Dock / Clear Icon Cache.
- **Window:** *Open DockFix…* lists every Dock item (broken ones first) with its status, repair choices, and **Undo Repair of “…”**, which puts back only the item last repaired.
- **Switches:**
  - *Fix automatically when a drive connects* — the background check (below).
  - *Open DockFix at login* — keeps the menu bar icon after a restart (starts in the menu bar only, no window).

Quitting the menu bar app does not stop the automatic fix; turn the switch off for that.

## How the automatic fix works

A launchd job bundled inside the app (`Contents/Library/LaunchAgents/org.batesai.dockfix.agent.plist`, registered with `SMAppService`, visible in System Settings › General › Login Items) runs `DockFix --agent` **at login and each time any filesystem mounts** (`RunAtLoad` + `StartOnMount`). It decides in a moment and exits; nothing polls.

1. Read the Dock's items (`com.apple.dock`: persistent-apps, persistent-others, recent-apps) and collect the external volumes they live on (`/Volumes/<name>/…`).
2. For each of those volumes that is mounted, get **when it was mounted**: the creation time of its mount-point folder in `/Volumes`. `stat()` can't see that (it crosses into the mounted volume and reports the volume's own root), so DockFix lists `/Volumes` with `getattrlistbulk()`, which returns the covered mount-point directory. diskarbitrationd creates that folder right before mounting and deletes it on unmount.
3. Get **when the current Dock started** (`sysctl KERN_PROC_PID`, this user's Dock only).
4. If a volume mounted later than 3 s before the Dock started, and no earlier check has handled that mount, the Dock may have missed it: wait until the mount is 5 s old, then restart the Dock (SIGTERM, same as `killall Dock`; launchd relaunches it).
5. Remember every mount it looked at, so each mount is acted on at most once.

The restarted Dock always starts more than 3 s after the mount, and handled mounts are remembered, so the same mount can never trigger a second restart. A hard cap of 4 restarts per 10 minutes backs this up. Mounts of volumes without Dock apps (disk images, SD cards) never restart the Dock.

## Install

From a release: unzip, drag **DockFix.app** to /Applications, open it, and turn on both switches.

From source (needs Xcode command-line tools):

```bash
cp config.local.sh.example config.local.sh   # optional: signing identity, build folder
scripts/build.sh                              # → ~/Downloads/dockfix-build/DockFix.app
scripts/install.sh --enable                   # → /Applications, switches on, menu bar app started
```

`install.sh` archives the copy it replaces into `~/Downloads/dockfix-build/archive/` and replaces the bundle in place, so Login Items registrations survive updates.

## Command line

```text
/Applications/DockFix.app/Contents/MacOS/DockFix --status
  --status              Dock items, the drives they live on, what the background check would do, recent activity
  --enable / --disable  background check on/off
  --login-item on|off   open the menu bar app at login
  --restart-dock        restart the Dock
  --clear-icon-cache    delete the Dock icon cache and restart the Dock
  --repair NAME [PATH]  repoint a broken Dock item (default: the copy its bookmark or bundle ID finds)
  --undo-repair         put the last repaired item back as it was (other items untouched)
  --menubar             start the menu bar app without opening the window
```

## Uninstall

Turn off both switches (or `DockFix --disable` and `DockFix --login-item off`), quit DockFix from its menu, and move DockFix.app to the Trash.

## Privacy

DockFix makes no network connections and collects nothing. It reads the Dock's preferences and the list of mounted volumes, and writes only the Dock preferences (on Repair/Undo) and its own preferences (`org.batesai.dockfix`: recent activity, the mounts it has handled, and the item saved before the last repair).

## Requirements

macOS 13 or later, Apple silicon or Intel (universal binary).

## Related projects

- [dockutil](https://github.com/kcrawford/dockutil) (Apache-2.0) and [docklib](https://github.com/homebysix/docklib) edit Dock items from scripts. DockFix doesn't depend on them; it edits the same `com.apple.dock` keys directly. No existing project was found that restarts the Dock when a drive mounts late.

## Licence

PolyForm Noncommercial 1.0.0 with a commercial-use rider (10% of gross revenue) — see [LICENSE](LICENSE). Commercial licences: help@batesai.org.

Developer notes, design decisions and alternative approaches: [docs/PLAN.md](docs/PLAN.md). Test procedure: [docs/TESTING.md](docs/TESTING.md).
