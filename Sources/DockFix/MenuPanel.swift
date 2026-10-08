// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import AppKit
import SwiftUI

/// The panel that drops down from the menu bar icon.
struct MenuPanel: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DockFix").font(.headline)
                Spacer()
                if model.searching || model.working { ProgressView().controlSize(.small) }
            }

            summary

            ForEach(model.brokenRows) { row in
                BrokenItemRow(row: row, searching: model.searching) { model.repair(row, to: $0) }
            }

            if !model.drives.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.drives, id: \.path) { drive in
                        Label(driveText(drive), systemImage: drive.mounted ? "externaldrive.fill" : "externaldrive")
                            .font(.caption)
                            .foregroundStyle(drive.mountedAfterDock ? Color.orange : Color.secondary)
                    }
                }
            }

            Divider()

            SwitchRow("Fix automatically when a drive connects", isOn: Binding(
                get: { model.agentState != .off },
                set: { model.setAgent($0) }))
            if model.agentState == .needsApproval {
                Button("Allow in Login Items…") { AgentService.openLoginItemsSettings() }
                    .buttonStyle(.link).font(.caption)
            }
            SwitchRow("Open DockFix at login", isOn: Binding(
                get: { model.openAtLogin },
                set: { model.setOpenAtLogin($0) }))

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                PanelButton("Restart Dock") { model.restartDock(clearingIconCache: false) }
                PanelButton("Clear Icon Cache and Restart Dock") { model.restartDock(clearingIconCache: true) }
                PanelButton("Open DockFix…") { MainWindow.shared.show() }
            }
            .disabled(model.working)

            if let note = model.note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            PanelButton("Quit DockFix") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 330)
        .onAppear { model.refresh() }
    }

    @ViewBuilder private var summary: some View {
        if model.problemCount > 0 {
            Label("\(model.problemCount) Dock item\(model.problemCount == 1 ? "" : "s") need\(model.problemCount == 1 ? "s" : "") repair",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if !model.staleDrives.isEmpty {
            Label("Restart the Dock to show apps on \(model.staleDrives.map(\.name).joined(separator: ", "))",
                  systemImage: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
        } else {
            Label("All Dock icons OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func driveText(_ drive: Agent.VolumeCheck) -> String {
        let items = "\(drive.itemCount) Dock item\(drive.itemCount == 1 ? "" : "s")"
        if !drive.mounted { return "\(drive.name): not connected · \(items)" }
        if drive.mountedAfterDock { return "\(drive.name): connected after the Dock started · \(items)" }
        return "\(drive.name): connected · \(items)"
    }
}

private struct BrokenItemRow: View {
    let row: Model.Row
    let searching: Bool
    let repair: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.app.dashed").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.tile.name)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            Spacer()
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

    private var detail: String {
        switch row.status {
        case .moved(let path): return "Moved to \(path)"
        case .missing where !row.candidates.isEmpty: return "Found at \(row.candidates[0])"
        case .missing: return searching ? "Looking for it…" : "Not found on this Mac or connected drives"
        default: return ""
        }
    }
}

/// A label with its switch lined up on the right edge.
private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}

/// A full-width, left-aligned menu-style button.
private struct PanelButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.accentColor.opacity(0.2) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
