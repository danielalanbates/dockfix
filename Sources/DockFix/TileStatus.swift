// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import AppKit
import Foundation

enum TileStatus: Equatable {
    case ok
    /// The item lives on a drive that is not connected. Nothing to repair; it comes back with the drive.
    case driveNotConnected(String)
    /// The saved path is gone but the Dock's bookmark still finds the item at this new path.
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
        case .moved: return "MOVED"
        case .missing: return "MISSING"
        case .notAFile: return ""
        }
    }

    var label: String {
        switch self {
        case .ok: return "OK"
        case .driveNotConnected(let drive): return "Drive “\(drive)” not connected"
        case .moved: return "Moved"
        case .missing: return "Missing"
        case .notAFile: return ""
        }
    }

    static func of(_ tile: DockTile) -> TileStatus {
        guard let path = tile.path else { return .notAFile }
        if FileManager.default.fileExists(atPath: path) { return .ok }
        if let volume = Volumes.volumeRoot(of: path), !Volumes.isMounted(volume) {
            return .driveNotConnected((volume as NSString).lastPathComponent)
        }
        if let bookmark = tile.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               url.path != path, FileManager.default.fileExists(atPath: url.path) {
                return .moved(url.path)
            }
        }
        return .missing
    }
}

/// Copies of an app that a broken Dock item could point at instead.
enum AppFinder {
    /// Folders that hold system or backup copies, never something to point the Dock at.
    private static let skippedNames: Set<String> = [
        "Backups.backupdb", "System", "Library", "Users", "private", "usr", "bin", "sbin", "cores", "dev", "opt",
    ]
    /// Entries in /Volumes that are not real drives.
    private static let skippedVolumes: Set<String> = [
        "Recovery", "com.apple.TimeMachine.localsnapshots", ".timemachine", ".PEVolumes",
    ]
    private static let visitLimit = 40_000

    static func candidates(for tile: DockTile) -> [String] {
        guard let brokenPath = tile.path else { return [] }
        let wantedName = (brokenPath as NSString).lastPathComponent
        var seen = Set<String>()
        var found: [String] = []

        func consider(_ path: String) {
            guard path != brokenPath, seen.insert(path).inserted, !isExcluded(path) else { return }
            if let bundleID = tile.bundleID {
                guard Self.bundleID(at: path) == bundleID else { return }
            } else {
                guard (path as NSString).lastPathComponent == wantedName else { return }
            }
            found.append(path)
        }

        if let bundleID = tile.bundleID {
            for url in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID) {
                consider(url.path)
            }
        }

        var visits = 0
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var roots: [(String, Int)] = [("/Applications", 2), (home + "/Applications", 2), ("/System/Applications", 2)]
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: Volumes.root)) ?? []
        for name in volumes.sorted() where !skippedVolumes.contains(name) && !name.hasPrefix(".") {
            let path = Volumes.root + "/" + name
            if Volumes.isMounted(path) { roots.append((path, 3)) }
        }
        for (root, depth) in roots {
            scan(root, depth: depth, visits: &visits) { consider($0) }
        }

        return found.sorted { lhs, rhs in
            let lhsKey = rank(lhs, wantedName: wantedName), rhsKey = rank(rhs, wantedName: wantedName)
            return lhsKey != rhsKey ? lhsKey < rhsKey : lhs.count < rhs.count
        }
    }

    private static func scan(_ directory: String, depth: Int, visits: inout Int, onApp: (String) -> Void) {
        guard depth > 0, visits < visitLimit,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names where !name.hasPrefix(".") && !skippedNames.contains(name) {
            visits += 1
            if visits >= visitLimit { return }
            let path = directory + "/" + name
            if name.hasSuffix(".app") {
                onApp(path)
                continue
            }
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
                  values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else { continue }
            scan(path, depth: depth - 1, visits: &visits, onApp: onApp)
        }
    }

    private static func bundleID(at path: String) -> String? {
        let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        return info?["CFBundleIdentifier"] as? String
    }

    private static func isExcluded(_ path: String) -> Bool {
        path.contains("/.Trash") || path.contains("/Backups.backupdb/") || !FileManager.default.fileExists(atPath: path)
    }

    /// Lower is better: same file name first, then anything in an Applications folder.
    private static func rank(_ path: String, wantedName: String) -> Int {
        var score = 0
        if (path as NSString).lastPathComponent != wantedName { score += 2 }
        if !path.contains("/Applications/") { score += 1 }
        return score
    }
}
