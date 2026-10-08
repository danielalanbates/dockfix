// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import AppKit
import SwiftUI

/// DockFix lives in the menu bar (LSUIElement: no Dock icon). The full window opens from the menu,
/// when the app is opened by hand, or when it is opened again while already running.
struct DockFixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = Model.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(model)
        } label: {
            Image(systemName: model.problemCount > 0 ? "questionmark.app.dashed" : "dock.rectangle")
                .accessibilityLabel(model.problemCount > 0 ? "DockFix: \(model.problemCount) broken Dock items" : "DockFix")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !launchedQuietly { MainWindow.shared.show(activate: false) }  // a normal launch already comes forward
    }

    /// Stay in the menu bar only when started at login or by `open … --args --menubar`.
    private var launchedQuietly: Bool {
        if CommandLine.arguments.contains("--menubar") { return true }
        // The 'oapp' event is only available here, inside applicationDidFinishLaunching.
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.eventID == kAEOpenApplication,
           event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        // Fallback in case the login flag is missing: started within two minutes of this user logging in.
        if let login = DockProcess.startTime(ofProcessNamed: "loginwindow"), let me = DockProcess.ownStartTime() {
            return me.timeIntervalSince(login) < 120
        }
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.shared.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor
final class MainWindow {
    static let shared = MainWindow()
    private var window: NSWindow?

    func show(activate: Bool = true) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "DockFix"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 640, height: 560)
            window.contentView = NSHostingView(rootView: ContentView().environmentObject(Model.shared))
            window.center()
            window.setFrameAutosaveName("DockFixMain")
            self.window = window
        }
        Model.shared.refresh()
        if activate { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
    }
}
