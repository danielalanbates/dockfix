// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import Foundation

/// One item in the Dock, read from com.apple.dock.
struct DockTile: Identifiable, Hashable {
    let section: String
    let index: Int
    let guid: Int?
    let label: String
    let bundleID: String?
    /// Where the Dock expects the item, nil for spacers and other non-file tiles.
    let path: String?
    let bookmark: Data?

    var id: String { "\(section)#\(guid.map(String.init) ?? "i\(index)")" }
    var name: String { label.isEmpty ? ((path ?? "") as NSString).lastPathComponent : label }
}

enum DockPrefsError: LocalizedError {
    case tileNotFound(String)
    case writeFailed
    case noBackup

    var errorDescription: String? {
        switch self {
        case .tileNotFound(let name): return "“\(name)” is no longer in the Dock."
        case .writeFailed: return "macOS did not accept the change to the Dock settings."
        case .noBackup: return "There is no earlier repair to undo."
        }
    }
}

enum DockPrefs {
    static let domain = "com.apple.dock" as CFString
    static let allSections = ["persistent-apps", "persistent-others", "recent-apps"]
    /// The two sections people arrange themselves; recent-apps is managed by the Dock.
    static let editableSections = ["persistent-apps", "persistent-others"]

    static func sync() {
        CFPreferencesAppSynchronize(domain)
    }

    static func items(in section: String) -> [[String: Any]] {
        (CFPreferencesCopyAppValue(section as CFString, domain) as? [[String: Any]]) ?? []
    }

    static func tiles(in sections: [String] = allSections) -> [DockTile] {
        sync()
        var tiles: [DockTile] = []
        for section in sections {
            for (index, item) in items(in: section).enumerated() {
                let data = item["tile-data"] as? [String: Any] ?? [:]
                tiles.append(DockTile(section: section,
                                      index: index,
                                      guid: (item["GUID"] as? NSNumber)?.intValue,
                                      label: data["file-label"] as? String ?? "",
                                      bundleID: data["bundle-identifier"] as? String,
                                      path: filePath(of: data),
                                      bookmark: data["book"] as? Data))
            }
        }
        return tiles
    }

    /// Points a Dock item at `newPath`: new URL, fresh bookmark, and cleared modification dates.
    /// The dates matter — with stale ones left in, the Dock kept showing "?" even after the URL and
    /// bookmark were correct (seen 2026-10-08 with Zygor and XIV on Mac moved to an external drive).
    static func repoint(_ tile: DockTile, to newPath: String, saveBackup: Bool = true) throws {
        sync()
        var list = items(in: tile.section)
        guard let index = locate(tile, in: list) else { throw DockPrefsError.tileNotFound(tile.name) }
        let original = list[index]

        let url = URL(fileURLWithPath: newPath, isDirectory: true)
        var item = original
        var data = item["tile-data"] as? [String: Any] ?? [:]
        data["book"] = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        var fileData = data["file-data"] as? [String: Any] ?? [:]
        fileData["_CFURLString"] = url.absoluteString
        fileData["_CFURLStringType"] = 15
        data["file-data"] = fileData
        data["file-mod-date"] = 0
        data["parent-mod-date"] = 0
        item["tile-data"] = data
        list[index] = item

        // Only a repair that was actually written replaces the undo backup.
        try write(list, to: tile.section)
        if saveBackup { try Backup.save(tile: tile, original: original) }
    }

    /// Where the Dock's preferences currently point `tile` (found again by GUID), or nil if it's gone.
    static func currentPath(of tile: DockTile) -> String? {
        sync()
        let list = items(in: tile.section)
        guard let index = locate(tile, in: list) else { return nil }
        return filePath(of: list[index]["tile-data"] as? [String: Any] ?? [:])
    }

    /// Puts one item back as it was before the last repair, leaving the rest of the Dock alone.
    static func restore(_ backup: Backup.Saved) throws {
        sync()
        var list = items(in: backup.section)
        let probe = DockTile(section: backup.section, index: backup.index, guid: backup.guid, label: backup.label,
                             bundleID: nil, path: nil, bookmark: nil)
        guard let index = locate(probe, in: list) else { throw DockPrefsError.tileNotFound(backup.label) }
        list[index] = backup.item
        try write(list, to: backup.section)
    }

    static func write(_ list: [[String: Any]], to section: String) throws {
        CFPreferencesSetAppValue(section as CFString, list as CFArray, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw DockPrefsError.writeFailed }
    }

    /// Finds the same item again after the list may have changed: by GUID, else by position and label.
    static func locate(_ tile: DockTile, in list: [[String: Any]]) -> Int? {
        if let guid = tile.guid,
           let index = list.firstIndex(where: { ($0["GUID"] as? NSNumber)?.intValue == guid }) {
            return index
        }
        guard tile.index < list.count else { return nil }
        let data = list[tile.index]["tile-data"] as? [String: Any] ?? [:]
        return (data["file-label"] as? String ?? "") == tile.label ? tile.index : nil
    }

    static func filePath(of tileData: [String: Any]) -> String? {
        guard let fileData = tileData["file-data"] as? [String: Any],
              let string = fileData["_CFURLString"] as? String, !string.isEmpty else { return nil }
        if (fileData["_CFURLStringType"] as? NSNumber)?.intValue == 0 {
            return string  // a plain POSIX path
        }
        guard let url = URL(string: string), url.isFileURL else { return nil }
        return url.path
    }
}

/// The repaired Dock item as it was before the most recent repair, kept in DockFix's own preferences.
/// Undo puts back that one item only, so later changes to the rest of the Dock are kept.
enum Backup {
    struct Saved {
        let date: Date
        let section: String
        let index: Int
        let guid: Int?
        let label: String
        let item: [String: Any]
    }

    private static let key = "lastRepair"

    static var saved: Saved? {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        guard let raw = UserDefaults.standard.dictionary(forKey: key),
              let date = raw["date"] as? Date,
              let section = raw["section"] as? String,
              let index = raw["index"] as? Int,
              let label = raw["label"] as? String,
              let data = raw["item"] as? Data,
              let item = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return Saved(date: date, section: section, index: index, guid: raw["guid"] as? Int, label: label, item: item)
    }

    static func save(tile: DockTile, original: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
        var raw: [String: Any] = ["date": Date(), "section": tile.section, "index": tile.index,
                                  "label": tile.name, "item": data]
        if let guid = tile.guid { raw["guid"] = guid }
        UserDefaults.standard.set(raw, forKey: key)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }
}

enum IconCache {
    /// The Dock's cache of tile images. A "?" can stay cached here after the item itself is fixed.
    static var url: URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).appendingPathComponent("com.apple.dock.iconcache")
    }

    /// Deletes the cache; the Dock rebuilds it when it restarts.
    @discardableResult
    static func clear() -> Bool {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}
