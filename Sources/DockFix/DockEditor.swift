// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import Foundation

/// Edits to Dock items that survive the Dock's own saving.
///
/// A freshly started Dock rewrites its whole item list about 5 seconds after launch (measured
/// 2026-10-08: it fills in file-mod-date, parent-mod-date, dock-extra, is-beta). Anything written to
/// com.apple.dock in that window is lost — e.g. a second repair right after the first one's restart.
/// So every edit waits for a settled Dock, and is checked after the next restart and written again once
/// if the Dock overwrote it. These calls block for several seconds; keep them off the main thread.
enum DockEditor {
    /// How old the Dock must be before its item list can be edited safely.
    static let settledAge: TimeInterval = 8

    static func waitForSettledDock() {
        guard let dock = DockProcess.current() else { return }
        let age = Date().timeIntervalSince(dock.started)
        if age < settledAge { Thread.sleep(forTimeInterval: settledAge - age) }
    }

    /// Repoints `tile`, clears the icon cache and restarts the Dock. Returns false if the Dock still
    /// doesn't point at `path` afterwards.
    static func repair(_ tile: DockTile, to path: String) throws -> Bool {
        waitForSettledDock()
        try DockPrefs.repoint(tile, to: path)
        for attempt in 0..<2 {
            IconCache.clear()
            DockProcess.restart()
            waitForSettledDock()
            if DockPrefs.currentPath(of: tile) == path { return true }
            if attempt == 0 { try DockPrefs.repoint(tile, to: path, saveBackup: false) }
        }
        return false
    }

    /// Undoes the last repair and restarts the Dock. Returns the item's name and whether it stuck.
    static func undo() throws -> (name: String, ok: Bool) {
        waitForSettledDock()
        guard let saved = Backup.saved else { throw DockPrefsError.noBackup }
        let wanted = (saved.item["tile-data"] as? [String: Any]).flatMap(DockPrefs.filePath(of:))
        let probe = DockTile(section: saved.section, index: saved.index, guid: saved.guid, label: saved.label,
                             bundleID: nil, path: nil, bookmark: nil)
        let name = try Backup.restore()
        for attempt in 0..<2 {
            IconCache.clear()
            DockProcess.restart()
            waitForSettledDock()
            if DockPrefs.currentPath(of: probe) == wanted { return (name, true) }
            if attempt == 0 { try DockPrefs.restore(saved) }
        }
        return (name, false)
    }
}
