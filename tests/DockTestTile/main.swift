// Test helper: adds, breaks, or removes a throwaway Dock item (bundle ID org.batesai.dockfix.testtile).
//   dock-test-tile add PATH | break FAKEPATH | remove | show
// Edits the real Dock preferences; restart the Dock afterwards. Used by tests/make_test_volume.sh and docs/TESTING.md.
// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.
import Foundation
let domain = "com.apple.dock" as CFString
let bid = "org.batesai.dockfix.testtile"
CFPreferencesAppSynchronize(domain)
var apps = (CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) as? [[String: Any]]) ?? []
let cmd = CommandLine.arguments[1]
func isTest(_ i: [String: Any]) -> Bool { ((i["tile-data"] as? [String: Any])?["bundle-identifier"] as? String) == bid }
switch cmd {
case "add":
  let url = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
  apps.removeAll(where: isTest)
  apps.append(["GUID": 990011, "tile-type": "file-tile", "tile-data": [
    "file-label": "DockFix Test Tile", "bundle-identifier": bid, "file-type": 41,
    "book": try! url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
    "file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15]]])
case "break":
  let fake = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
  for i in apps.indices where isTest(apps[i]) {
    var td = apps[i]["tile-data"] as! [String: Any]
    td.removeValue(forKey: "book")
    td["file-data"] = ["_CFURLString": fake.absoluteString, "_CFURLStringType": 15]
    apps[i]["tile-data"] = td
  }
case "remove":
  apps.removeAll(where: isTest)
case "show":
  for i in apps where isTest(i) { print(i) }
default: fatalError("usage")
}
if cmd != "show" {
  CFPreferencesSetAppValue("persistent-apps" as CFString, apps as CFArray, domain)
  print("synced:", CFPreferencesAppSynchronize(domain), "count:", apps.count)
}
