// SPDX-License-Identifier: MIT
// Which app does Launch Services pick for a bundle id, and which copies does it know about?
// Read-only. Build: swiftc -O lsresolve.swift -o lsresolve   Usage: lsresolve com.alexparkin.adpmonitor
import AppKit

let id = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.alexparkin.adpmonitor"
print("preferred: \(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path ?? "none")")
for url in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id) {
    let version = Bundle(url: url)?.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    print("known: \(url.path) (CFBundleVersion \(version))")
}
