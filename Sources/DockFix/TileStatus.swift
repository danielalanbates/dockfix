// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import AppKit
import Darwin
import Foundation

enum TileStatus: Equatable {
    case ok
    /// The item lives on a drive that is not connected. Nothing to repair; it comes back with the drive.
    case driveNotConnected(String)
    /// DockFix can't read the item's drive or folder (permissions, privacy settings, or a failing or
    /// unreachable drive). The Dock itself may be fine, and DockFix must not "repair" it to another copy.
    case noAccess(String)
    /// The saved path is gone but the Dock's bookmark still finds this exact item at a new path.
    case moved(String)
    /// Gone from where the Dock expects it.
    case missing
    /// Spacers and other tiles that are not files.
    case notAFile

    var needsRepair: Bool {
        switch self {
        case .moved, .missing: return true
        default: return false
        }
    }

    /// Fixed-width word for the --status listing.
    var code: String {
        switch self {
        case .ok: return "OK"
        case .driveNotConnected: return "OFFLINE"
        case .noAccess: return "NO ACCESS"
        case .moved: return "MOVED"
        case .missing: return "MISSING"
        case .notAFile: return ""
        }
    }

    var label: String {
        switch self {
        case .ok: return "OK"
        case .driveNotConnected(let drive): return "Drive “\(drive)” not connected"
        case .noAccess(let place): return "DockFix can't read “\(place)”"
        case .moved: return "Moved"
        case .missing: return "Missing"
        case .notAFile: return ""
        }
    }

    static func of(_ tile: DockTile) -> TileStatus {
        guard let path = tile.path else { return .notAFile }
        switch FileCheck.check(path) {
        case .exists:
            return .ok
        case .unreadable:
            return .noAccess(Volumes.volumeRoot(of: path).map { ($0 as NSString).lastPathComponent }
                             ?? ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent)
        case .absent:
            break
        }
        // The bookmark names this exact file (volume UUID + file ID), so following it can't land on a
        // different copy. It also finds items on a drive that now mounts under another name ("x10 1").
        if let resolved = resolve(tile.bookmark), resolved != path, !AppFinder.isInTrash(resolved),
           FileCheck.check(resolved) == .exists {
            return .moved(resolved)
        }
        if let volume = Volumes.volumeRoot(of: path), !Volumes.isMounted(volume) {
            return .driveNotConnected((volume as NSString).lastPathComponent)
        }
        return .missing
    }

    private static func resolve(_ bookmark: Data?) -> String? {
        guard let bookmark else { return nil }
        var stale = false
        let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        return url?.path
    }
}

/// Tells "not there" apart from "can't look" — FileManager.fileExists reports both as false.
enum FileCheck {
    /// `unreadable`: permissions, privacy settings, or a failing/unreachable drive (EIO, ETIMEDOUT, …).
    case exists, absent, unreadable

    static func check(_ path: String) -> FileCheck {
        var info = stat()
        let result = stat(path, &info)
        let error = errno
        if result == 0 { return .exists }
        // Only "no such file" means absent; anything else must never lead to a repair.
        return error == ENOENT || error == ENOTDIR ? .absent : .unreadable
    }
}

/// Copies of apps that broken Dock items could point at instead.
enum AppFinder {
    struct Result {
        /// Tile id → candidate paths, best first.
        var candidates: [String: [String]] = [:]
        /// True when a folder was too big to search completely, so "not found" is not certain.
        var incomplete = false
    }

    /// Folders that hold system or backup copies, never something to point the Dock at.
    private static let skippedNames: Set<String> = [
        "Backups.backupdb", "System", "Library", "Users", "private", "usr", "bin", "sbin", "cores", "dev", "opt",
    ]
    /// Entries in /Volumes that are not real drives.
    private static let skippedVolumes: Set<String> = [
        "Recovery", "com.apple.TimeMachine.localsnapshots", ".timemachine", ".PEVolumes",
    ]
    /// Entries examined per search root, so one huge drive can't use up the search for the others.
    private static let visitsPerRoot = 20_000

    static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/") || path.hasSuffix("/.Trash") || path.hasSuffix("/.Trashes")
    }

    static func candidates(for tile: DockTile) -> [String] {
        candidates(for: [tile]).candidates[tile.id] ?? []
    }

    /// One pass over the disks for all broken tiles at once.
    static func candidates(for tiles: [DockTile]) -> Result {
        struct Wanted { let id: String; let bundleID: String?; let name: String; let brokenPath: String }
        let wanted = tiles.compactMap { tile -> Wanted? in
            guard let path = tile.path else { return nil }
            return Wanted(id: tile.id, bundleID: tile.bundleID, name: (path as NSString).lastPathComponent, brokenPath: path)
        }
        var result = Result()
        guard !wanted.isEmpty else { return result }

        var found: [String: Set<String>] = [:]
        var bundleIDs: [String: String?] = [:]
        func consider(_ appPath: String) {
            guard !isInTrash(appPath), !appPath.contains("/Backups.backupdb/"), FileCheck.check(appPath) == .exists else { return }
            let bundleID: String?
            if let cached = bundleIDs[appPath] {
                bundleID = cached
            } else {
                bundleID = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String
                bundleIDs[appPath] = bundleID
            }
            for item in wanted where appPath != item.brokenPath {
                let matches = item.bundleID.map { $0 == bundleID } ?? ((appPath as NSString).lastPathComponent == item.name)
                if matches { found[item.id, default: []].insert(appPath) }
            }
        }

        for bundleID in Set(wanted.compactMap(\.bundleID)) {
            for url in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID) { consider(url.path) }
        }
        for (root, depth) in searchRoots(preferring: wanted.compactMap { Volumes.volumeRoot(of: $0.brokenPath) }) {
            var visits = 0
            scan(root, depth: depth, visits: &visits, onApp: consider)
            if visits >= visitsPerRoot { result.incomplete = true }
        }

        for item in wanted {
            result.candidates[item.id] = (found[item.id] ?? []).sorted { lhs, rhs in
                let l = rank(lhs, name: item.name), r = rank(rhs, name: item.name)
                return l != r ? l < r : (lhs.count != rhs.count ? lhs.count < rhs.count : lhs < rhs)
            }
        }
        return result
    }

    /// App folders first, then the drives that broken items lived on, then every other connected drive.
    private static func searchRoots(preferring volumes: [String]) -> [(String, Int)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var roots: [(String, Int)] = [("/Applications", 2), (home + "/Applications", 2), ("/System/Applications", 2)]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Volumes.root)) ?? []
        let mounted = names.sorted()
            .filter { !skippedVolumes.contains($0) && !$0.hasPrefix(".") }
            .map { Volumes.root + "/" + $0 }
            .filter { Volumes.isMounted($0) }
        let preferred = Set(volumes)
        roots += mounted.filter { preferred.contains($0) }.map { ($0, 3) }
        roots += mounted.filter { !preferred.contains($0) }.map { ($0, 3) }
        return roots
    }

    private static func scan(_ directory: String, depth: Int, visits: inout Int, onApp: (String) -> Void) {
        guard depth > 0, visits < visitsPerRoot,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names where !name.hasPrefix(".") && !skippedNames.contains(name) {
            visits += 1
            if visits >= visitsPerRoot { return }
            let path = directory + "/" + name
            if name.hasSuffix(".app") {
                onApp(path)
                continue
            }
            guard depth > 1 else { continue }
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
                  values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else { continue }
            scan(path, depth: depth - 1, visits: &visits, onApp: onApp)
        }
    }

    /// Lower is better: same file name first, then anything in an Applications folder.
    private static func rank(_ path: String, name: String) -> Int {
        var score = 0
        if (path as NSString).lastPathComponent != name { score += 2 }
        if !path.contains("/Applications/") { score += 1 }
        return score
    }
}
