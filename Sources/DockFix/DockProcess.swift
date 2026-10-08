// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import Darwin
import Foundation

/// The current user's running Dock.
struct DockInstance: Equatable {
    let pid: pid_t
    let started: Date
}

enum DockProcess {
    static let executableSuffix = "/Dock.app/Contents/MacOS/Dock"

    /// The Dock belonging to this user. Other logged-in users (fast user switching) have their own Docks,
    /// so processes are filtered by uid as well as by name and path.
    static func current() -> DockInstance? {
        let uid = getuid()
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 256)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return nil }

        var newest: DockInstance?
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let info = kinfo(pid), info.kp_eproc.e_ucred.cr_uid == uid else { continue }
            let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard name == "Dock", executablePath(pid)?.hasSuffix(executableSuffix) == true else { continue }
            let tv = info.kp_proc.p_starttime
            let started = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
            if newest == nil || started > newest!.started {
                newest = DockInstance(pid: pid, started: started)
            }
        }
        return newest
    }

    /// Quits the Dock the same way `killall Dock` does; launchd relaunches it at once and the new Dock
    /// re-reads every tile. Returns the new Dock, or nil if none appeared within `timeout`.
    @discardableResult
    static func restart(timeout: TimeInterval = 15) -> DockInstance? {
        guard let old = current() else { return nil }
        kill(old.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(250_000)
            if let new = current(), new.pid != old.pid { return new }
        }
        return nil
    }

    private static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
