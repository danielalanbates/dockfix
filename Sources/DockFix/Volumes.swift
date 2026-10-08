// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import Darwin
import Foundation

/// A directory entry in /Volumes and when it was created.
struct MountPoint {
    let path: String
    /// When diskarbitrationd created the mount-point directory, which it does just before mounting
    /// (after any disk check). It is removed again on unmount, so this is the time of the latest mount.
    let created: Date
    let isMountPoint: Bool
}

enum Volumes {
    static let root = "/Volumes"

    /// "/Volumes/x10" for any path on that volume, nil for paths on the startup disk.
    static func volumeRoot(of path: String) -> String? {
        let parts = (path as NSString).pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        return root + "/" + parts[2]
    }

    /// True when a filesystem is mounted exactly at `path` (an empty leftover folder does not count).
    static func isMounted(_ path: String) -> Bool {
        mountedPaths().contains(path)
    }

    /// Mount points from the kernel's cached mount table. MNT_NOWAIT never asks the filesystems
    /// themselves, so a dead network share can't stall the check (statfs() on it can block).
    /// (getfsstat with our own buffer rather than getmntinfo, whose static buffer isn't thread-safe.)
    static func mountedPaths() -> Set<String> {
        let estimate = getfsstat(nil, 0, MNT_NOWAIT)
        guard estimate > 0 else { return [] }
        let capacity = Int(estimate) + 8
        let bytes = capacity * MemoryLayout<statfs>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<statfs>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        let table = raw.bindMemory(to: statfs.self, capacity: capacity)
        let count = getfsstat(table, Int32(bytes), MNT_NOWAIT)
        guard count > 0 else { return [] }
        var paths = Set<String>()
        for index in 0..<Int(count) {
            paths.insert(withUnsafeBytes(of: table[index].f_mntonname) { name in
                String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)
            })
        }
        return paths
    }

    /// Every entry in /Volumes with the creation time of the mount-point directory itself.
    ///
    /// stat() on "/Volumes/x10" crosses into the mounted volume and reports the volume's own root folder,
    /// whose dates say nothing about when it was mounted. getattrlistbulk() lists the entries of /Volumes
    /// from the startup disk's side, so for a mount point it returns the covered directory, whose creation
    /// time is the mount time.
    static func mountPoints() -> [String: MountPoint] {
        var result: [String: MountPoint] = [:]
        let fd = open(root, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return result }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_CRTIME)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)

        let capacity = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            let count = getattrlistbulk(fd, &request, buffer, capacity, 0)
            if count <= 0 { break }
            var entry = buffer
            for _ in 0..<count {
                let length = entry.loadUnaligned(as: UInt32.self)
                var field = entry + MemoryLayout<UInt32>.size
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                let nameRef = field.loadUnaligned(as: attrreference_t.self)
                let name = String(cString: (field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                field += MemoryLayout<attrreference_t>.size

                var created = Date.distantPast
                if returned.commonattr & attrgroup_t(ATTR_CMN_CRTIME) != 0 {
                    let ts = field.loadUnaligned(as: timespec.self)
                    created = Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
                    field += MemoryLayout<timespec>.size
                }
                var status: UInt32 = 0
                if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
                    status = field.loadUnaligned(as: UInt32.self)
                }
                let path = root + "/" + name
                result[path] = MountPoint(path: path, created: created,
                                          isMountPoint: status & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0)
                entry += Int(length)
            }
        }
        return result
    }
}
