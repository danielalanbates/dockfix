// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import AppKit
import Foundation
import ServiceManagement

/// State shared by the menu bar panel and the window. Refreshes when the panel or window opens and
/// when a drive mounts or unmounts or the Mac wakes. No timers.
@MainActor
final class Model: ObservableObject {
    static let shared = Model()

    struct Row: Identifiable {
        let tile: DockTile
        let status: TileStatus
        var candidates: [String] = []
        var id: String { tile.id }
    }

    @Published var rows: [Row] = []
    @Published var drives: [Agent.VolumeCheck] = []
    @Published var agentState: AgentService.State = .off
    @Published var openAtLogin = false
    @Published var history: [History.Entry] = []
    @Published var canUndo = false
    @Published var searching = false
    @Published var working = false
    @Published var note: String?

    private var observers: [NSObjectProtocol] = []
    private var generation = 0

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                    // The background check restarts the Dock about 5 s after a mount; pick up its log entry.
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    self?.refresh()
                }
            })
        }
        refresh()
    }

    var problemCount: Int { rows.filter { $0.status.needsRepair }.count }
    var brokenRows: [Row] { rows.filter { $0.status.needsRepair } }
    /// Broken items first, then items on disconnected drives, then the rest, each in Dock order.
    var rowsProblemsFirst: [Row] {
        func rank(_ row: Row) -> Int {
            if row.status.needsRepair { return 0 }
            if case .driveNotConnected = row.status { return 1 }
            return 2
        }
        return rows.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
    /// Drives that connected after the Dock started — their items show "?" until the Dock restarts.
    var staleDrives: [Agent.VolumeCheck] { drives.filter(\.mountedAfterDock) }

    func refresh() {
        agentState = AgentService.state
        openAtLogin = SMAppService.mainApp.status == .enabled
        history = History.load()
        canUndo = Backup.exists
        drives = Agent.evaluate().volumes
        // Keep earlier search results on screen while the new search runs, so Repair buttons don't flicker.
        let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rows = DockPrefs.tiles(in: DockPrefs.editableSections)
            .map { tile in
                var row = Row(tile: tile, status: TileStatus.of(tile))
                if let old = previous[tile.id], old.tile.path == tile.path { row.candidates = old.candidates }
                return row
            }
            .filter { $0.status != .notAFile }

        generation += 1
        let current = generation
        let missing = rows.filter { $0.status == .missing }.map(\.tile)
        guard !missing.isEmpty else {
            searching = false
            return
        }
        searching = true
        Task.detached(priority: .userInitiated) {
            var search: [String: [String]] = [:]
            for tile in missing { search[tile.id] = AppFinder.candidates(for: tile) }
            let found = search
            await MainActor.run {
                guard current == self.generation else { return }  // a newer refresh is under way
                for index in self.rows.indices {
                    if let candidates = found[self.rows[index].id] { self.rows[index].candidates = candidates }
                }
                self.searching = false
            }
        }
    }

    func setAgent(_ enabled: Bool) {
        do {
            try AgentService.setEnabled(enabled)
            note = nil
        } catch {
            note = "Could not turn the automatic fix \(enabled ? "on" : "off"): \(error.localizedDescription)"
        }
        agentState = AgentService.state
        if agentState == .needsApproval { AgentService.openLoginItemsSettings() }
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            note = nil
        } catch {
            note = "Could not change Open at Login: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func repair(_ row: Row, to path: String) {
        do {
            try DockPrefs.repoint(row.tile, to: path)
        } catch {
            note = "Repair failed: \(error.localizedDescription)"
            return
        }
        History.add("Repointed “\(row.tile.name)” to \(path)")
        restartDock(clearingIconCache: true, message: "Pointed “\(row.tile.name)” at \(path).")
    }

    func undo() {
        do {
            try Backup.restore()
        } catch {
            note = error.localizedDescription
            return
        }
        restartDock(clearingIconCache: false, message: "Put the Dock back the way it was before the last repair.")
    }

    func restartDock(clearingIconCache: Bool, message: String? = nil) {
        guard !working else { return }
        working = true
        Task.detached(priority: .userInitiated) {
            if clearingIconCache { IconCache.clear() }
            let restarted = DockProcess.restart() != nil
            try? await Task.sleep(nanoseconds: 1_500_000_000)  // let the new Dock settle before re-reading
            await MainActor.run {
                self.working = false
                self.note = restarted ? (message ?? "Dock restarted.") : "The Dock did not restart."
                self.refresh()
            }
        }
    }
}
