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
