// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import Foundation
import os

/// The background check. launchd runs it at login and every time any filesystem mounts
/// (RunAtLoad + StartOnMount); it decides in a moment and exits. Nothing stays running.
///
/// The Dock resolves its items once, when it starts. An item on a drive that was not mounted yet
/// becomes "?" and stays that way after the drive appears. So: if a drive that holds Dock items
/// mounted after the current Dock started, restart the Dock once.
enum Agent {
    static let log = Logger(subsystem: "org.batesai.dockfix", category: "agent")

    /// Mounts this close before the Dock started may still have raced it (on 2026-10-07 x10's
    /// mount point and the Dock appeared in the same second), so they count as "after".
    static let raceWindow: TimeInterval = 3
    /// Wait until the newest mount is this old before restarting. The new Dock then starts well
    /// after the mount, outside `raceWindow`, so the next check cannot pick the same mount again.
    static let settleDelay: TimeInterval = 5
    /// Belt and braces against a restart loop.
    static let maxRestarts = 4
    static let maxRestartsWindow: TimeInterval = 600

    struct VolumeCheck {
        let path: String
        let itemCount: Int
        let mounted: Bool
        let mountedAt: Date?
        let mountedAfterDock: Bool

        var name: String { (path as NSString).lastPathComponent }
    }

    struct Evaluation {
        let dock: DockInstance?
        let volumes: [VolumeCheck]

        var stale: [VolumeCheck] { volumes.filter(\.mountedAfterDock) }
    }

    static func evaluate() -> Evaluation {
        var counts: [String: Int] = [:]
        for tile in DockPrefs.tiles() {
            if let path = tile.path, let volume = Volumes.volumeRoot(of: path) {
                counts[volume, default: 0] += 1
            }
        }
        let dock = DockProcess.current()
        let mountPoints = counts.isEmpty ? [:] : Volumes.mountPoints()
        let checks = counts.keys.sorted().map { volume -> VolumeCheck in
            let mounted = Volumes.isMounted(volume)
            let point = mountPoints[volume]
            let mountedAt = mounted && point?.isMountPoint == true ? point?.created : nil
            var after = false
            if let dock, let mountedAt {
                after = mountedAt > dock.started.addingTimeInterval(-raceWindow)
            }
            return VolumeCheck(path: volume, itemCount: counts[volume] ?? 0, mounted: mounted,
                               mountedAt: mountedAt, mountedAfterDock: after)
        }
        return Evaluation(dock: dock, volumes: checks)
    }

    static func run() -> Int32 {
        log.info("check started")

        // Right after login the Dock may not be up yet.
        var waited = 0
        while DockProcess.current() == nil && waited < 60 {
            sleep(1)
            waited += 1
        }

        for _ in 0..<4 {
            let evaluation = evaluate()
            guard evaluation.dock != nil else {
                log.error("no Dock process found")
                return 0
            }
            let stale = evaluation.stale
            guard let newest = stale.compactMap(\.mountedAt).max() else {
                log.info("nothing to do")
                return 0
            }

            let wait = newest.addingTimeInterval(settleDelay).timeIntervalSinceNow
            if wait > 0 {
                // Re-check afterwards: the Dock may have been restarted by someone else meanwhile.
                Thread.sleep(forTimeInterval: min(wait, 30))
                continue
            }

            let names = stale.map { "“\($0.name)”" }.joined(separator: ", ")
            guard History.recentRestarts(within: maxRestartsWindow) < maxRestarts else {
                History.add("Skipped a Dock restart for \(names): already restarted \(maxRestarts) times in 10 minutes")
                log.error("restart cap reached")
                return 0
            }
            History.recordRestart()
            let restarted = DockProcess.restart() != nil
            History.add(restarted
                ? "Restarted the Dock because \(names) connected after the Dock started"
                : "Tried to restart the Dock for \(names), but no new Dock appeared within 15 seconds")
            log.info("restart for \(names, privacy: .public): \(restarted ? "ok" : "no new Dock", privacy: .public)")
            return 0
        }
        return 0
    }
}
