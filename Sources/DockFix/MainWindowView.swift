// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import AppKit
import SwiftUI

/// The full DockFix window: settings, every Dock item with its status, and repair actions.
struct ContentView: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            automaticFix
            dockItems
            actions
            if let note = model.note {
                Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(18)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("DockFix").font(.title2.bold())
                Text("Repairs Dock icons that turn into a question mark.").foregroundStyle(.secondary)
            }
        }
    }

    private var automaticFix: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Restart the Dock when a drive with Dock apps connects", isOn: Binding(
                    get: { model.agentState != .off },
                    set: { model.setAgent($0) }))
                Group {
                    switch model.agentState {
                    case .on:
                        Text("On. A quick check runs at login and whenever a drive mounts, then exits. It works even when DockFix is quit.")
                    case .off:
                        Text("Off. Apps on external drives can show “?” if the Dock starts before the drive.")
                    case .needsApproval:
                        HStack {
                            Text("Allow DockFix in Login Items to finish turning this on.")
                            Button("Open Login Items") { AgentService.openLoginItemsSettings() }
                        }
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                Toggle("Open DockFix at login (menu bar icon)", isOn: Binding(
                    get: { model.openAtLogin },
                    set: { model.setOpenAtLogin($0) }))
                if let last = model.history.first {
                    Text("Last: \(last.date.formatted(date: .abbreviated, time: .shortened)) — \(last.message)")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("Settings").font(.headline)
        }
    }

    private var dockItems: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                List(model.rowsProblemsFirst) { row in
                    RowView(row: row, searching: model.searching) { path in model.repair(row, to: path) }
                }
                .listStyle(.inset)
                HStack {
                    if model.searching {
                        ProgressView().controlSize(.small)
                        Text("Looking for moved apps…").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(model.problemCount == 0 ? "No broken items." : model.problemCount == 1 ? "1 broken item." : "\(model.problemCount) broken items.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Rescan") { model.refresh() }
                }
            }
            .padding(4)
        } label: {
            Text("Dock items").font(.headline)
        }
    }

    private var actions: some View {
        HStack {
            Button("Restart Dock") { model.restartDock(clearingIconCache: false) }
            Button("Clear Icon Cache and Restart Dock") { model.restartDock(clearingIconCache: true) }
                .help("Use this when an item exists but its icon still shows “?”.")
            Spacer()
            Button("Undo Last Repair") { model.undo() }
                .disabled(!model.canUndo)
                .help("Restores the Dock section as it was before the last repair.")
        }
        .disabled(model.working)
    }
}

struct RowView: View {
    let row: Model.Row
    let searching: Bool
    let repair: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.tile.name)
                Text(row.tile.path ?? "").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer()
            Text(row.status.label).font(.callout).foregroundStyle(color)
            repairControl
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var icon: some View {
        if row.status == .ok, let path = row.tile.path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        } else {
            Image(systemName: "questionmark.app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    private var detail: String? {
        switch row.status {
        case .moved(let path): return "Now at \(path)"
        case .missing where !row.candidates.isEmpty: return "Found at \(row.candidates[0])"
        case .missing where !searching: return "No other copy found on this Mac or connected drives"
        default: return nil
        }
    }

    private var color: Color {
        switch row.status {
        case .ok: return .green
        case .driveNotConnected: return .secondary
        case .moved: return .orange
        case .missing: return .red
        case .notAFile: return .secondary
        }
    }

    @ViewBuilder private var repairControl: some View {
        switch row.status {
        case .moved(let path):
            Button("Repair") { repair(path) }
        case .missing where row.candidates.count == 1:
            Button("Repair") { repair(row.candidates[0]) }
        case .missing where row.candidates.count > 1:
            Menu("Repair") {
                ForEach(row.candidates, id: \.self) { path in Button(path) { repair(path) } }
            }
            .fixedSize()
        default:
            EmptyView()
        }
    }
}
