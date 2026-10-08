// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import AppKit
import Foundation

/// State shared by the menu bar panel and the window. Refreshes when the panel or window opens and
/// when a drive mounts or unmounts or the Mac wakes. No timers.
///
/// Anything that touches drives (status of each item, mount times, the search for moved apps) runs off
/// the main thread: a slow or unreachable drive must not freeze the menu bar.
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
    @Published var undoable: Backup.Saved?
    /// True from refresh() until the first results are on screen.
    @Published var loading = false
    @Published var searching = false
    @Published var searchIncomplete = false
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
    /// Drives that connected after the Dock started and no check has handled yet — their items show "?"
    /// until the Dock restarts.
    var staleDrives: [Agent.VolumeCheck] { drives.filter(\.needsRestart) }
    var offlineDrives: [Agent.VolumeCheck] { drives.filter { !$0.mounted } }

    /// Broken items first, then items on disconnected or unreadable drives, then the rest, each in Dock order.
    var rowsProblemsFirst: [Row] {
        func rank(_ row: Row) -> Int {
            if row.status.needsRepair { return 0 }
            switch row.status {
            case .driveNotConnected, .noAccess: return 1
            default: return 2
            }
        }
        return rows.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    func refresh() {
        agentState = AgentService.state
        openAtLogin = AgentService.opensAtLogin
        history = History.load()
        undoable = Backup.saved

        generation += 1
        let current = generation
        loading = true
        // Keep earlier search results on screen while the new check runs, so Repair buttons don't flicker.
        let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        Task.detached(priority: .userInitiated) {
            let drives = Agent.evaluate().volumes
            let fresh = DockPrefs.tiles(in: DockPrefs.editableSections)
                .map { tile in
                    var row = Row(tile: tile, status: TileStatus.of(tile))
                    if let old = previous[tile.id], old.tile.path == tile.path { row.candidates = old.candidates }
                    return row
                }
                .filter { $0.status != .notAFile }
            let missing = fresh.filter { $0.status == .missing }.map(\.tile)

            let stillCurrent = await MainActor.run { () -> Bool in
                guard current == self.generation else { return false }  // a newer refresh is under way
                self.drives = drives
                self.rows = fresh
                self.loading = false
                self.searching = !missing.isEmpty
                return true
            }
            guard stillCurrent, !missing.isEmpty else { return }

            let search = AppFinder.candidates(for: missing)
            await MainActor.run {
                guard current == self.generation else { return }
                for index in self.rows.indices {
                    if let candidates = search.candidates[self.rows[index].id] { self.rows[index].candidates = candidates }
                }
                self.searchIncomplete = search.incomplete
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
            try AgentService.setOpenAtLogin(enabled)
            note = nil
        } catch {
            note = "Could not change Open at Login: \(error.localizedDescription)"
        }
        openAtLogin = AgentService.opensAtLogin
    }

    func repair(_ row: Row, to path: String) {
        guard !working else { return }
        guard FileCheck.check(path) == .exists else {
            note = "Can't repair “\(row.tile.name)”: nothing at \(path) any more."
            refresh()
            return
        }
        let tile = row.tile
        working = true
        note = "Repairing “\(tile.name)”…"
        Task.detached(priority: .userInitiated) {
            let outcome: String
            do {
                if try DockEditor.repair(tile, to: path) {
                    History.add("Repointed “\(tile.name)” to \(path)")
                    outcome = "Pointed “\(tile.name)” at \(path)."
                } else {
                    History.add("Tried to repoint “\(tile.name)” to \(path), but the Dock kept its old setting")
                    outcome = "The Dock kept its old setting for “\(tile.name)”. Try Repair again."
                }
            } catch {
                outcome = "Repair failed: \(error.localizedDescription)"
            }
            await MainActor.run {
                self.working = false
                self.note = outcome
                self.refresh()
            }
        }
    }

    func undo() {
        guard !working else { return }
        working = true
        note = "Undoing the last repair…"
        Task.detached(priority: .userInitiated) {
            let outcome: String
            do {
                let result = try DockEditor.undo()
                History.add("Undid the repair of “\(result.name)”")
                outcome = result.ok ? "Put “\(result.name)” back the way it was before the repair."
                                    : "Undid the repair of “\(result.name)”, but the Dock kept the repaired setting."
            } catch {
                outcome = error.localizedDescription
            }
            await MainActor.run {
                self.working = false
                self.note = outcome
                self.refresh()
            }
        }
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
