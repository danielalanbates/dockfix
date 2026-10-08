// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import Foundation
import ServiceManagement

/// Turns the background check on and off. The launchd job is defined inside the app bundle
/// (Contents/Library/LaunchAgents) and registered with SMAppService, so nothing is written to
/// ~/Library/LaunchAgents and it shows up under System Settings › General › Login Items.
enum AgentService {
    static let plistName = "org.batesai.dockfix.agent.plist"

    enum State: Equatable {
        case on, off, needsApproval

        var description: String {
            switch self {
            case .on: return "on"
            case .off: return "off"
            case .needsApproval: return "waiting for approval in System Settings › General › Login Items"
            }
        }
    }

    static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    static var state: State {
        switch service.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off  // .notRegistered, and .notFound, which macOS also reports for a job never registered
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Open at login

    /// A second bundled job that starts the menu bar app with --menubar, so no window opens at login.
    /// (SMAppService.mainApp can't pass arguments, and its "launched at login" flag isn't dependable.)
    /// The job runs `DockFix --launch-menubar`, which starts the app and exits (see LoginLauncher).
    static let loginPlistName = "org.batesai.dockfix.menubar.plist"
    static var loginItem: SMAppService { SMAppService.agent(plistName: loginPlistName) }
    /// On while the job is registered, or while a login item from an older build still opens the app.
    static var opensAtLogin: Bool { loginItem.status == .enabled || SMAppService.mainApp.status == .enabled }
    static var openAtLoginNeedsApproval: Bool { loginItem.status == .requiresApproval }

    static var openAtLoginDescription: String {
        opensAtLogin ? "on" : openAtLoginNeedsApproval ? State.needsApproval.description : "off"
    }

    static func setOpenAtLogin(_ enabled: Bool) throws {
        if enabled {
            if loginItem.status != .enabled { try loginItem.register() }
            // Retire the old login item only once the job is sure to start the app instead.
            if loginItem.status == .enabled { retireMainAppLoginItem() }
        } else {
            retireMainAppLoginItem()
            if loginItem.status == .enabled || loginItem.status == .requiresApproval { try loginItem.unregister() }
        }
    }

    /// Builds before 2026-10-08 evening registered the app itself as the login item; move to the job above.
    static func migrateLoginItem() {
        guard SMAppService.mainApp.status == .enabled else { return }
        try? setOpenAtLogin(true)
    }

    private static func retireMainAppLoginItem() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
    }
}

/// Recent background activity, shown in the window and by --status. Kept in DockFix's preferences.
enum History {
    struct Entry: Identifiable {
        let date: Date
        let message: String
        var id: String { "\(date.timeIntervalSince1970)-\(message)" }
    }

    private static let entriesKey = "history"
    private static let restartsKey = "restartTimes"
    private static let keep = 30

    static func load() -> [Entry] {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        let raw = UserDefaults.standard.array(forKey: entriesKey) as? [[String: Any]] ?? []
        return raw.compactMap { item in
            guard let date = item["date"] as? Date, let message = item["message"] as? String else { return nil }
            return Entry(date: date, message: message)
        }
    }

    static func add(_ message: String) {
        var raw = UserDefaults.standard.array(forKey: entriesKey) as? [[String: Any]] ?? []
        raw.insert(["date": Date(), "message": message], at: 0)
        UserDefaults.standard.set(Array(raw.prefix(keep)), forKey: entriesKey)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    static func recordRestart() {
        let cutoff = Date().addingTimeInterval(-3600)
        var times = (UserDefaults.standard.array(forKey: restartsKey) as? [Date] ?? []).filter { $0 > cutoff }
        times.append(Date())
        UserDefaults.standard.set(times, forKey: restartsKey)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    static func recentRestarts(within seconds: TimeInterval) -> Int {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        let cutoff = Date().addingTimeInterval(-seconds)
        return (UserDefaults.standard.array(forKey: restartsKey) as? [Date] ?? []).filter { $0 > cutoff }.count
    }
}
