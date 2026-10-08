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
    static func repoint(_ tile: DockTile, to newPath: String) throws {
        sync()
        var list = items(in: tile.section)
        guard let index = locate(tile, in: list) else { throw DockPrefsError.tileNotFound(tile.name) }
        try Backup.save(section: tile.section, items: list)

        let url = URL(fileURLWithPath: newPath, isDirectory: true)
        var item = list[index]
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
        try write(list, to: tile.section)
    }

    static func write(_ list: [[String: Any]], to section: String) throws {
        CFPreferencesSetAppValue(section as CFString, list as CFArray, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw DockPrefsError.writeFailed }
    }

    /// Finds the same item again after the list may have changed: by GUID, else by position and label.
    private static func locate(_ tile: DockTile, in list: [[String: Any]]) -> Int? {
        if let guid = tile.guid,
           let index = list.firstIndex(where: { ($0["GUID"] as? NSNumber)?.intValue == guid }) {
            return index
        }
        guard tile.index < list.count else { return nil }
        let data = list[tile.index]["tile-data"] as? [String: Any] ?? [:]
        return (data["file-label"] as? String ?? "") == tile.label ? tile.index : nil
    }

    private static func filePath(of tileData: [String: Any]) -> String? {
        guard let fileData = tileData["file-data"] as? [String: Any],
              let string = fileData["_CFURLString"] as? String, !string.isEmpty else { return nil }
        if (fileData["_CFURLStringType"] as? NSNumber)?.intValue == 0 {
            return string  // a plain POSIX path
        }
        guard let url = URL(string: string), url.isFileURL else { return nil }
        return url.path
    }
}

/// The Dock section as it was before the most recent repair, kept in DockFix's own preferences.
enum Backup {
    private static let key = "lastRepairBackup"

    static var exists: Bool {
        UserDefaults.standard.dictionary(forKey: key) != nil
    }

    static var date: Date? {
        UserDefaults.standard.dictionary(forKey: key)?["date"] as? Date
    }

    static func save(section: String, items: [[String: Any]]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0)
        UserDefaults.standard.set(["date": Date(), "section": section, "items": data], forKey: key)
    }

    /// Puts the backed-up Dock section back. Anything added to that section after the repair is lost.
    static func restore() throws {
        guard let saved = UserDefaults.standard.dictionary(forKey: key),
              let section = saved["section"] as? String,
              let data = saved["items"] as? Data,
              let items = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { throw DockPrefsError.noBackup }
        try DockPrefs.write(items, to: section)
        UserDefaults.standard.removeObject(forKey: key)
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
