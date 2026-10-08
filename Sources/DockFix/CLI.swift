// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import Foundation
import ServiceManagement

enum CLI {
    static let usage = """
    DockFix \(version) — keeps Dock icons from turning into "?"

    Usage: DockFix [command]
      (no command)        start the menu bar app and open the DockFix window
      --menubar           start the menu bar app without the window
      --status            show the Dock items, the drives they live on, and what the background check would do
      --enable            turn on the background check (runs at login and whenever a drive mounts)
      --disable           turn it off
      --login-item on|off open the menu bar app at login, or stop doing so
      --restart-dock      restart the Dock now
      --clear-icon-cache  delete the Dock's icon cache and restart the Dock
      --repair NAME [PATH]
                          point the Dock item NAME at PATH (default: the best copy found), clear the
                          icon cache and restart the Dock
      --undo-repair       put back the Dock section as it was before the last repair
      --agent             the background check itself (launchd runs this)
      --version, --help
    """

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static func run(_ arguments: [String]) -> Int32 {
        switch arguments[0] {
        case "--agent":
            return Agent.run()
        case "--status":
            printStatus()
            return 0
        case "--enable", "--disable":
            return setAgent(arguments[0] == "--enable")
        case "--login-item":
            guard arguments.count >= 2, ["on", "off"].contains(arguments[1]) else { print(usage); return 64 }
            return setLoginItem(arguments[1] == "on")
        case "--restart-dock":
            return report(DockProcess.restart() != nil, "Dock restarted.", "The Dock did not restart.")
        case "--clear-icon-cache":
            IconCache.clear()
            return report(DockProcess.restart() != nil, "Icon cache cleared and Dock restarted.", "The Dock did not restart.")
        case "--repair":
            guard arguments.count >= 2 else { print(usage); return 64 }
            return repair(name: arguments[1], to: arguments.count >= 3 ? arguments[2] : nil)
        case "--undo-repair":
            do {
                try Backup.restore()
                DockProcess.restart()
                print("Restored the Dock section saved before the last repair.")
                return 0
            } catch {
                print(error.localizedDescription)
                return 1
            }
        case "--version":
            print(version)
            return 0
        case "--help", "-h":
            print(usage)
            return 0
        default:
            print(usage)
            return 64
        }
    }

    private static func report(_ ok: Bool, _ success: String, _ failure: String) -> Int32 {
        print(ok ? success : failure)
        return ok ? 0 : 1
    }

    private static func setAgent(_ enabled: Bool) -> Int32 {
        do {
            try AgentService.setEnabled(enabled)
        } catch {
            print("Could not turn the background check \(enabled ? "on" : "off"): \(error.localizedDescription)")
            print("Background check: \(AgentService.state.description)")
            return 1
        }
        print("Background check: \(AgentService.state.description)")
        return 0
    }

    private static func setLoginItem(_ enabled: Bool) -> Int32 {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Could not change Open at Login: \(error.localizedDescription)")
            return 1
        }
        print("Open at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
        return 0
    }

        private static func repair(name: String, to explicitPath: String?) -> Int32 {
        let matches = DockPrefs.tiles(in: DockPrefs.editableSections)
            .filter { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        guard let tile = matches.first else {
            print("No Dock item named “\(name)”.")
            return 1
        }
        let target: String
        if let explicitPath {
            target = (explicitPath as NSString).standardizingPath
        } else if case .moved(let path) = TileStatus.of(tile) {
            target = path
        } else if let best = AppFinder.candidates(for: tile).first {
            target = best
        } else {
            print("No other copy of “\(tile.name)” found on this Mac or connected drives.")
            return 1
        }
        guard FileManager.default.fileExists(atPath: target) else {
            print("Nothing at \(target).")
            return 1
        }
        do {
            try DockPrefs.repoint(tile, to: target)
        } catch {
            print("Repair failed: \(error.localizedDescription)")
            return 1
        }
        IconCache.clear()
        DockProcess.restart()
        History.add("Repointed “\(tile.name)” to \(target)")
        print("Repointed “\(tile.name)” to \(target) and restarted the Dock. Undo with --undo-repair.")
        return 0
    }

    private static func printStatus() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let evaluation = Agent.evaluate()

        print("DockFix \(version)")
        print("Background check: \(AgentService.state.description)")
        print("Open at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
        if let dock = evaluation.dock {
            print("Dock: pid \(dock.pid), started \(formatter.string(from: dock.started))")
        } else {
            print("Dock: not running")
        }

        print("\nDrives holding Dock items:")
        if evaluation.volumes.isEmpty { print("  none") }
        for volume in evaluation.volumes {
            let mounted = volume.mountedAt.map { "mounted \(formatter.string(from: $0))" }
                ?? (volume.mounted ? "mounted (time unknown)" : "not connected")
            let verdict = volume.mountedAfterDock ? "connected after the Dock started → restart needed" : "ok"
            print("  \(volume.path)  \(volume.itemCount) item(s)  \(mounted)  \(verdict)")
        }
        print("Background check would: \(evaluation.stale.isEmpty ? "do nothing" : "restart the Dock")")

        print("\nDock items:")
        for tile in DockPrefs.tiles(in: DockPrefs.editableSections) {
            let status = TileStatus.of(tile)
            guard status != .notAFile else { continue }
            var line = "  \(status.code.padding(toLength: 9, withPad: " ", startingAt: 0)) \(tile.name)  \(tile.path ?? "")"
            if case .moved(let path) = status { line += "  → bookmark finds it at \(path)" }
            if case .driveNotConnected(let drive) = status { line += "  (drive “\(drive)” not connected)" }
            print(line)
            if status == .missing {
                let candidates = AppFinder.candidates(for: tile)
                print(candidates.isEmpty ? "            no other copy found"
                                         : candidates.map { "            found: \($0)" }.joined(separator: "\n"))
            }
        }

        let history = History.load()
        if !history.isEmpty {
            print("\nRecent activity:")
            for entry in history.prefix(10) {
                print("  \(formatter.string(from: entry.date))  \(entry.message)")
            }
        }
    }
}
