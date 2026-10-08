// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import Foundation
import os

/// The background check. launchd runs it at login and every time any filesystem mounts
/// (RunAtLoad + StartOnMount); it decides in a moment and exits. Nothing stays running.
///
/// The Dock resolves its items once, when it starts. An item on a drive that was not mounted yet
/// becomes "?" and stays that way after the drive appears. So: if a drive that holds Dock items
/// mounted after the current Dock started, restart the Dock once.
///
/// Each mount is acted on at most once: every run records the mounts it has looked at
/// (`SeenMounts`). Without that, a drive that mounted while it held no Dock items, and got one
/// later (the Dock shows those fine), would make the next unrelated mount restart the Dock.
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
        /// An earlier check already handled this mount.
        let alreadyHandled: Bool

        var name: String { (path as NSString).lastPathComponent }
        var needsRestart: Bool { mountedAfterDock && !alreadyHandled }
    }

    struct Evaluation {
        let dock: DockInstance?
        let volumes: [VolumeCheck]
        /// Every volume mounted when this evaluation ran (path → mount time). Only these get marked as
        /// seen, so a drive that mounts while a check is in progress is still evaluated by the next one.
        let mounted: [String: Double]

        var stale: [VolumeCheck] { volumes.filter(\.needsRestart) }
    }

    static func evaluate() -> Evaluation {
        var counts: [String: Int] = [:]
        for tile in DockPrefs.tiles() {
            if let path = tile.path, let volume = Volumes.volumeRoot(of: path) {
                counts[volume, default: 0] += 1
            }
        }
        let dock = DockProcess.current()
        let mountPoints = Volumes.mountPoints()
        var mountedNow: [String: Double] = [:]
        for (path, point) in mountPoints where point.isMountPoint && Volumes.isMounted(path) {
            mountedNow[path] = point.created.timeIntervalSince1970
        }
        let seen = SeenMounts.load()
        let checks = counts.keys.sorted().map { volume -> VolumeCheck in
            let mounted = Volumes.isMounted(volume)
            let mountedAt = mountedNow[volume].map { Date(timeIntervalSince1970: $0) }
            var after = false
            if let dock, let mountedAt {
                after = mountedAt > dock.started.addingTimeInterval(-raceWindow)
            }
            let handled = mountedAt.map { SeenMounts.matches(seen[volume], $0) } ?? false
            return VolumeCheck(path: volume, itemCount: counts[volume] ?? 0, mounted: mounted,
                               mountedAt: mountedAt, mountedAfterDock: after, alreadyHandled: handled)
        }
        return Evaluation(dock: dock, volumes: checks, mounted: mountedNow)
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
                SeenMounts.record(evaluation.mounted)
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
                SeenMounts.record(evaluation.mounted)
                log.error("restart cap reached")
                return 0
            }
            History.recordRestart()
            let restarted = DockProcess.restart() != nil
            SeenMounts.record(evaluation.mounted)
            History.add(restarted
                ? "Restarted the Dock because \(names) connected after the Dock started"
                : "Tried to restart the Dock for \(names), but no new Dock appeared within 15 seconds")
            log.info("restart for \(names, privacy: .public): \(restarted ? "ok" : "no new Dock", privacy: .public)")
            return 0
        }
        return 0
    }
}

/// Mounts the background check has already looked at: mount-point path → mount time.
enum SeenMounts {
    private static let key = "seenMounts"

    static func load() -> [String: Double] {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        return UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    static func matches(_ seen: Double?, _ mountedAt: Date) -> Bool {
        guard let seen else { return false }
        return abs(seen - mountedAt.timeIntervalSince1970) < 0.001
    }

    /// Remembers the volumes a check evaluated (including ones without Dock items), replacing the old list
    /// so unmounted drives drop out.
    static func record(_ mounted: [String: Double]) {
        UserDefaults.standard.set(mounted, forKey: key)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }
}
