// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import AppKit
import Darwin

/// One menu bar app per user: an flock held for the app's lifetime. The kernel drops it when the
/// process exits, however it exits, so it can't go stale, and two copies starting in the same
/// instant can't both lose (unlike checking the list of running apps).
enum InstanceLock {
    private static var held: Int32 = -1

    private static var path: String {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.batesai.dockfix", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("menubar.lock").path
    }

    /// True if this process now holds the lock. Also true if the lock can't be used at all:
    /// two copies are better than none.
    static func acquire() -> Bool {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            held = fd
            return true
        }
        let error = errno
        close(fd)
        return error != EWOULDBLOCK
    }

    /// True while another process (the running menu bar app) holds the lock.
    static var isHeldElsewhere: Bool {
        guard acquire() else { return true }
        if held >= 0 {
            close(held)  // closing the only descriptor releases the lock
            held = -1
        }
        return false
    }
}

/// What the "Open at login" job runs (`--launch-menubar`). It starts the menu bar app through
/// LaunchServices and exits, so the app never runs as the job's own process. That matters because
/// turning Open at Login off unregisters the job, and launchd kills a job's running process.
enum LoginLauncher {
    static func run() -> Int32 {
        // Already running: leave it alone. Opening a running app sends it a reopen event, which
        // would open its window.
        if InstanceLock.isHeldElsewhere { return 0 }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = ["--menubar"]
        var finished = false
        var failure: Error?
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            failure = error
            finished = true
        }
        let deadline = Date().addingTimeInterval(60)
        while !finished && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if let failure {
            print("Could not start DockFix: \(failure.localizedDescription)")
            return 1
        }
        if !finished {
            print("DockFix did not start within 60 seconds.")
            return 1
        }
        return 0
    }
}
