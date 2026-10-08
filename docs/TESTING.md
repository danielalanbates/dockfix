# Testing DockFix

Run before every GitHub release. Everything here works without clicking: Dock restarts are expected, nothing takes focus. Back up the Dock first: `defaults export com.apple.dock ~/Downloads/dock-before-test.plist`.

## 1. Build and status

```bash
scripts/build.sh && scripts/install.sh
D=/Applications/DockFix.app/Contents/MacOS/DockFix
$D --status          # every real Dock item OK or OFFLINE; "Background check would: do nothing"
launchctl print gui/$(id -u)/org.batesai.dockfix.agent | grep -E 'properties|last exit'   # start on fs mount, exit 0
```

## 2. Test volume and test tile

`tests/make_test_volume.sh` builds `~/Downloads/dockfix-build/test/test.dmg` (holding `DockFix Test Tile.app`, bundle ID `org.batesai.dockfix.testtile`) and the `dock-test-tile` helper (`add PATH` / `break FAKEPATH` / `remove` / `show`). Attach the image with `hdiutil attach -nobrowse`, run `dock-test-tile add "/Volumes/DockFixTest/DockFix Test Tile.app"`, `killall Dock`, and check that the tile shows its icon at the end of the apps section.

## 3. Late mount (the main fix)

| Step | Expect |
|---|---|
| `hdiutil detach /Volumes/DockFixTest` then `$D --clear-icon-cache` | test tile shows "?" (restarting alone keeps the cached icon) |
| `hdiutil attach -nobrowse test.dmg`, wait 2 s, screenshot | still "?" (the Dock does not re-check by itself) |
| wait ~10 s more | Dock pid changed; tile shows its icon; `--status` history: "Restarted the Dock because “DockFixTest” connected after the Dock started"; "would: do nothing" |

## 4. No false restarts

Attach an unrelated image (`hdiutil create -size 2m -fs HFS+ -volname Other …`) and `launchctl kickstart gui/$(id -u)/org.batesai.dockfix.agent`. The Dock pid must not change.

## 4b. A handled mount never fires twice

Detach the test image, remove the test tile and `killall Dock`, then attach the image again (no Dock item on it, so the check records it as seen: `defaults read org.batesai.dockfix seenMounts`). Add the tile to the preferences **without** restarting the Dock: `--status` must say "connected after the Dock started, already handled". Attach an unrelated image: the Dock pid must not change.

## 5. Repair and undo

| Step | Expect |
|---|---|
| `dock-test-tile break "/Applications/DockFix Test Tile.app"` (no bookmark) + `$D --clear-icon-cache` | "?"; `--status`: MISSING, `found: /Volumes/DockFixTest/…` |
| `$D --repair "DockFix Test Tile"` | icon back; `--status` OK |
| `$D --repair "DockFix Test Tile"` on an OK item, and on `GarageBand` | refused: "is not broken" |
| `killall Dock` then at once `$D --repair …` on the broken tile | waits for the Dock to settle (~16 s), then OK and still OK 8 s later |
| export the Dock prefs, `$D --undo-repair`, export again | only the test item differs; MISSING again; a second undo prints "There is no earlier repair to undo." |
| copy the app to `/Volumes/DockFixTest/Moved/`, add the tile there, move the copy into `/Volumes/DockFixTest/.Trashes/501/` | MISSING (not MOVED), offering the real copy |
| tile inside a folder with `chmod 000` | NO ACCESS; `--repair` refuses |
| tile on the test image, image detached | OFFLINE; `--repair` refuses |
| `scripts/render_previews.sh repair` | renders the panel/window with a Repair button, then repairs through the model: "after repair: broken = 0" |

## 5b. Login launch and single instance

Quit DockFix from its menu (`osascript -e 'tell application id "org.batesai.dockfix" to quit'`), then `launchctl kickstart gui/$(id -u)/org.batesai.dockfix.menubar`. Expect exactly one `DockFix --menubar` process, no DockFix windows on screen, and the menu bar icon. Kickstart again while it runs: still one process (the second copy exits).

## 6. UI

`scripts/render_previews.sh` writes `~/Downloads/dockfix-build/previews/{menu-panel,window}-{light,dark}.png`. Check: broken items listed first with Repair, switches right-aligned, drives line, no clipped text.

## 7. Clean up

Remove the test tile (`dock-test-tile remove`), `killall Dock`, detach and delete the images, and clear test activity:
`for k in history restartTimes lastRepair seenMounts; do defaults delete org.batesai.dockfix $k; done; defaults delete render-previews`.
Compare the Dock's labels and order with the backup.
