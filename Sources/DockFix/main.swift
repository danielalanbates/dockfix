// DockFix — keeps macOS Dock icons from turning into "?".
// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// PolyForm Noncommercial 1.0.0 + commercial rider (see LICENSE). help@batesai.org · https://batesai.org

import Foundation

// One executable serves three roles:
//   DockFix              → the menu bar app; also opens its window unless started at login
//   DockFix --menubar    → the menu bar app without opening the window
//   DockFix --agent      → the background check launchd runs at login and whenever a drive mounts
//   DockFix --<command>  → command-line tools, see CLI.usage
let arguments = Array(CommandLine.arguments.dropFirst())

if let first = arguments.first, first.hasPrefix("--"), first != "--menubar" {
    exit(CLI.run(arguments))
} else {
    DockFixApp.main()
}
