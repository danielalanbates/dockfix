// Renders the menu bar panel and the main window to PNGs without showing anything on screen or
// taking focus, so the UI can be checked from a script. Built by scripts/render_previews.sh.
// With a second argument "repair" it then presses the first Repair button through the model (the same
// call the button makes) and reports the result — this edits the real Dock, so use it with the test tile.
// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import AppKit
import SwiftUI

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
NSApplication.shared.setActivationPolicy(.prohibited)

@MainActor
func render<V: View>(_ view: V, width: CGFloat, height: CGFloat?, appearance: NSAppearance.Name, name: String) {
    let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = NSAppearance(named: appearance)
    let size = NSSize(width: width, height: height ?? host.fittingSize.height)
    host.frame = NSRect(origin: .zero, size: size)
    // Never ordered on screen.
    let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    // Opening the view starts a refresh (onAppear); wait for it like a person looking at the panel would.
    waitForSearch()
    host.layoutSubtreeIfNeeded()
    if height == nil { host.frame.size.height = host.fittingSize.height }
    host.display()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
    print("wrote", name)
}

@MainActor
func waitForSearch() {
    let deadline = Date().addingTimeInterval(20)
    repeat {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    } while Model.shared.searching && Date() < deadline
}

MainActor.assumeIsolated {
    let model = Model.shared
    waitForSearch()
    print("search finished:", !model.searching, "broken:", model.problemCount,
          "candidates:", model.brokenRows.map { $0.candidates.count })
    for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
        render(MenuPanel().environmentObject(model), width: 330, height: nil, appearance: appearance, name: "menu-panel-\(suffix).png")
        render(ContentView().environmentObject(model), width: 660, height: 600, appearance: appearance, name: "window-\(suffix).png")
    }

    if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "repair",
       let row = model.brokenRows.first, let target = row.candidates.first {
        print("repairing", row.tile.name, "→", target)
        model.repair(row, to: target)
        let deadline = Date().addingTimeInterval(60)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        } while (model.working || model.searching) && Date() < deadline
        // The refresh after a repair runs in the background; give it a moment, then wait for it.
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        waitForSearch()
        print("after repair: broken =", model.problemCount, "note =", model.note ?? "-")
    }
}
